// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IERC20.sol";
import "./interfaces/IQmoosaStablecoin.sol";
import "./interfaces/IQmoosaVaultManager.sol";

contract QmoosaVaultManager is IQmoosaVaultManager {
    uint256 public constant BPS_DIVISOR = 10000;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 31536000;

    address public owner;
    IQmoosaStablecoin public immutable stablecoin;

    uint256 private _vaultCounter;
    mapping(uint256 => Vault) public vaults;
    mapping(address => CollateralType) public collateralConfigs;
    mapping(address => OraclePriceFeed) public oracleFeeds;

    uint256 public maxOracleStaleness = 3600; // 1 hour max staleness
    uint256 public maxPriceDeviationBps = 5000; // max 50% deviation per standard update
    uint256 public override protocolBadDebt; // Bad debt deficit accumulator

    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier nonReentrant() {
        require(_status != _ENTERED, "REENTRANCY_GUARD: REENTRANT_CALL");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "VAULT_MANAGER: ONLY_OWNER");
        _;
    }

    constructor(address _stablecoin) {
        require(_stablecoin != address(0), "VAULT_MANAGER: ZERO_ADDRESS");
        owner = msg.sender;
        stablecoin = IQmoosaStablecoin(_stablecoin);
        _status = _NOT_ENTERED;
    }

    function setCollateralConfig(
        address token,
        uint8 decimals,
        uint256 minCollateralRatioBps,
        uint256 liquidationPenaltyBps,
        uint256 stabilityFeeBps,
        uint256 debtCeiling
    ) external override onlyOwner {
        require(token != address(0), "VAULT_MANAGER: ZERO_TOKEN");
        require(decimals <= 36, "VAULT_MANAGER: INVALID_DECIMALS");
        require(minCollateralRatioBps >= 10000, "VAULT_MANAGER: MIN_RATIO_BELOW_100");
        require(liquidationPenaltyBps <= 5000, "VAULT_MANAGER: PENALTY_TOO_HIGH");

        collateralConfigs[token] = CollateralType({
            token: token,
            decimals: decimals,
            minCollateralRatioBps: minCollateralRatioBps,
            liquidationPenaltyBps: liquidationPenaltyBps,
            stabilityFeeBps: stabilityFeeBps,
            debtCeiling: debtCeiling,
            totalDebtIssued: collateralConfigs[token].totalDebtIssued,
            isAllowed: true
        });
    }

    function setMaxOracleStaleness(uint256 stalenessSeconds) external override onlyOwner {
        require(stalenessSeconds >= 60, "VAULT_MANAGER: STALENESS_TOO_LOW");
        maxOracleStaleness = stalenessSeconds;
    }

    function setMaxPriceDeviationBps(uint256 deviationBps) external override onlyOwner {
        require(deviationBps > 0 && deviationBps <= 10000, "VAULT_MANAGER: INVALID_DEVIATION_BPS");
        maxPriceDeviationBps = deviationBps;
    }

    function setOraclePrice(address token, uint256 priceWad) external override onlyOwner {
        _setOraclePriceInternal(token, priceWad, block.timestamp, false);
    }

    function setOraclePriceWithTimestamp(address token, uint256 priceWad, uint256 updatedAt) external override onlyOwner {
        _setOraclePriceInternal(token, priceWad, updatedAt, false);
    }

    function overrideOraclePrice(address token, uint256 priceWad) external override onlyOwner {
        _setOraclePriceInternal(token, priceWad, block.timestamp, true);
    }

    function _setOraclePriceInternal(
        address token,
        uint256 priceWad,
        uint256 updatedAt,
        bool bypassDeviationCheck
    ) internal {
        require(token != address(0), "VAULT_MANAGER: ZERO_TOKEN");
        require(priceWad > 0, "VAULT_MANAGER: ZERO_PRICE");
        require(updatedAt <= block.timestamp, "VAULT_MANAGER: FUTURE_TIMESTAMP");
        require(block.timestamp - updatedAt <= maxOracleStaleness, "VAULT_MANAGER: PRICE_ALREADY_STALE");

        OraclePriceFeed storage feed = oracleFeeds[token];
        if (!bypassDeviationCheck && feed.priceWad > 0) {
            uint256 prevPrice = feed.priceWad;
            uint256 diff = priceWad > prevPrice ? priceWad - prevPrice : prevPrice - priceWad;
            uint256 deviationBps = (diff * BPS_DIVISOR) / prevPrice;
            require(deviationBps <= maxPriceDeviationBps, "VAULT_MANAGER: PRICE_DEVIATION_EXCEEDED");
        }

        feed.priceWad = priceWad;
        feed.updatedAt = updatedAt;
        emit OraclePriceUpdated(token, priceWad, updatedAt);
    }

    function getOraclePrice(address token) public view returns (uint256) {
        return _getFreshOraclePrice(token);
    }

    function _getFreshOraclePrice(address token) internal view returns (uint256) {
        OraclePriceFeed storage feed = oracleFeeds[token];
        require(feed.priceWad > 0, "VAULT_MANAGER: ORACLE_PRICE_NOT_SET");
        require(block.timestamp - feed.updatedAt <= maxOracleStaleness, "VAULT_MANAGER: ORACLE_PRICE_STALE");
        return feed.priceWad;
    }

    function openVault(address collateralToken) external override nonReentrant returns (uint256 vaultId) {
        require(collateralConfigs[collateralToken].isAllowed, "VAULT_MANAGER: COLLATERAL_NOT_ALLOWED");

        _vaultCounter++;
        vaultId = _vaultCounter;

        vaults[vaultId] = Vault({
            owner: msg.sender,
            collateralToken: collateralToken,
            collateralAmount: 0,
            debtAmount: 0,
            lastAccrualTimestamp: block.timestamp
        });

        emit VaultOpened(vaultId, msg.sender, collateralToken);
    }

    function depositCollateral(uint256 vaultId, uint256 amount) external override nonReentrant {
        Vault storage v = vaults[vaultId];
        require(v.owner != address(0), "VAULT_MANAGER: VAULT_DOES_NOT_EXIST");
        require(amount > 0, "VAULT_MANAGER: ZERO_AMOUNT");

        bool success = IERC20(v.collateralToken).transferFrom(msg.sender, address(this), amount);
        require(success, "VAULT_MANAGER: TRANSFER_FAILED");

        v.collateralAmount += amount;
        emit CollateralDeposited(vaultId, amount);
    }

    function withdrawCollateral(uint256 vaultId, uint256 amount) external override nonReentrant {
        Vault storage v = vaults[vaultId];
        require(msg.sender == v.owner, "VAULT_MANAGER: NOT_VAULT_OWNER");
        require(amount > 0 && amount <= v.collateralAmount, "VAULT_MANAGER: INVALID_WITHDRAW_AMOUNT");

        _accrueInterest(v);

        v.collateralAmount -= amount;

        if (v.debtAmount > 0) {
            require(_isSolvent(v), "VAULT_MANAGER: WITHDRAWAL_BREAKS_SOLVENCY");
        }

        bool success = IERC20(v.collateralToken).transfer(msg.sender, amount);
        require(success, "VAULT_MANAGER: TRANSFER_FAILED");

        emit CollateralWithdrawn(vaultId, msg.sender, amount);
    }

    function mintStablecoin(uint256 vaultId, uint256 amount) external override nonReentrant {
        Vault storage v = vaults[vaultId];
        require(msg.sender == v.owner, "VAULT_MANAGER: NOT_VAULT_OWNER");
        require(amount > 0, "VAULT_MANAGER: ZERO_AMOUNT");

        _accrueInterest(v);

        CollateralType storage config = collateralConfigs[v.collateralToken];
        require(config.totalDebtIssued + amount <= config.debtCeiling, "VAULT_MANAGER: DEBT_CEILING_BREACHED");

        v.debtAmount += amount;
        config.totalDebtIssued += amount;

        require(_isSolvent(v), "VAULT_MANAGER: MINT_BREAKS_SOLVENCY");

        stablecoin.mint(msg.sender, amount);
        emit StablecoinMinted(vaultId, msg.sender, amount);
    }

    function repayDebt(uint256 vaultId, uint256 amount) external override nonReentrant {
        Vault storage v = vaults[vaultId];
        require(v.owner != address(0), "VAULT_MANAGER: VAULT_DOES_NOT_EXIST");
        require(amount > 0, "VAULT_MANAGER: ZERO_AMOUNT");

        _accrueInterest(v);

        uint256 repayAmount = amount > v.debtAmount ? v.debtAmount : amount;
        v.debtAmount -= repayAmount;

        CollateralType storage config = collateralConfigs[v.collateralToken];
        if (config.totalDebtIssued >= repayAmount) {
            config.totalDebtIssued -= repayAmount;
        } else {
            config.totalDebtIssued = 0;
        }

        stablecoin.burn(msg.sender, repayAmount);
        emit DebtRepaid(vaultId, msg.sender, repayAmount);
    }

    function liquidateVault(uint256 vaultId, uint256 debtToCover) external override nonReentrant {
        Vault storage v = vaults[vaultId];
        require(v.owner != address(0), "VAULT_MANAGER: VAULT_DOES_NOT_EXIST");
        require(v.debtAmount > 0, "VAULT_MANAGER: ZERO_DEBT");
        require(debtToCover > 0, "VAULT_MANAGER: ZERO_DEBT_TO_COVER");

        _accrueInterest(v);
        require(!_isSolvent(v), "VAULT_MANAGER: VAULT_IS_SOLVENT");

        uint256 actualCover = debtToCover > v.debtAmount ? v.debtAmount : debtToCover;
        CollateralType storage config = collateralConfigs[v.collateralToken];
        uint256 price = _getFreshOraclePrice(v.collateralToken);
        uint8 decimals = config.decimals;

        // Value to cover with liquidation penalty in WAD
        uint256 repayValueWithPenalty = (actualCover * (BPS_DIVISOR + config.liquidationPenaltyBps)) / BPS_DIVISOR;
        // Native token collateral units
        uint256 collateralToSeize = (repayValueWithPenalty * (10 ** decimals)) / price;

        if (collateralToSeize > v.collateralAmount) {
            // Shortfall handling & Bad-debt accounting
            uint256 actualSeized = v.collateralAmount;
            uint256 actualSeizedValueWad = (actualSeized * price) / (10 ** decimals);
            uint256 coveredDebt = (actualSeizedValueWad * BPS_DIVISOR) / (BPS_DIVISOR + config.liquidationPenaltyBps);
            if (actualCover > coveredDebt) {
                uint256 badDebtDeficit = actualCover - coveredDebt;
                protocolBadDebt += badDebtDeficit;
                emit BadDebtIncurred(vaultId, badDebtDeficit);
            }
            collateralToSeize = actualSeized;
        }

        v.debtAmount -= actualCover;
        v.collateralAmount -= collateralToSeize;

        if (config.totalDebtIssued >= actualCover) {
            config.totalDebtIssued -= actualCover;
        } else {
            config.totalDebtIssued = 0;
        }

        stablecoin.burn(msg.sender, actualCover);
        bool success = IERC20(v.collateralToken).transfer(msg.sender, collateralToSeize);
        require(success, "VAULT_MANAGER: SEIZURE_TRANSFER_FAILED");

        emit VaultLiquidated(vaultId, msg.sender, actualCover, collateralToSeize);
    }

    function getCollateralValue(address collateralToken, uint256 amount) public view returns (uint256) {
        if (amount == 0) return 0;
        uint256 price = _getFreshOraclePrice(collateralToken);
        uint8 decimals = collateralConfigs[collateralToken].decimals;
        return (amount * price) / (10 ** decimals);
    }

    function isVaultSolvent(uint256 vaultId) external view returns (bool) {
        Vault storage v = vaults[vaultId];
        return _isSolvent(v);
    }

    function _isSolvent(Vault storage v) internal view returns (bool) {
        if (v.debtAmount == 0) return true;
        uint256 collValue = getCollateralValue(v.collateralToken, v.collateralAmount);
        CollateralType storage config = collateralConfigs[v.collateralToken];
        uint256 ratio = (collValue * BPS_DIVISOR) / v.debtAmount;
        return ratio >= config.minCollateralRatioBps;
    }

    function _accrueInterest(Vault storage v) internal {
        if (v.debtAmount == 0) {
            v.lastAccrualTimestamp = block.timestamp;
            return;
        }
        uint256 elapsed = block.timestamp - v.lastAccrualTimestamp;
        if (elapsed > 0) {
            CollateralType storage config = collateralConfigs[v.collateralToken];
            if (config.stabilityFeeBps > 0) {
                // Compounding stability fee calculation:
                // Linear: (P * r * t) / (BPS_DIVISOR * SECONDS_PER_YEAR)
                // Second-order compounding term: (Linear * r * t) / (2 * BPS_DIVISOR * SECONDS_PER_YEAR)
                uint256 linearInterest = (v.debtAmount * config.stabilityFeeBps * elapsed) / (BPS_DIVISOR * SECONDS_PER_YEAR);
                uint256 compoundTerm = (linearInterest * config.stabilityFeeBps * elapsed) / (2 * BPS_DIVISOR * SECONDS_PER_YEAR);
                uint256 totalInterest = linearInterest + compoundTerm;

                v.debtAmount += totalInterest;
                // Formal debt ceiling policy: Accrued interest is allowed to accrue even if debt ceiling is reached,
                // but new minting is strictly blocked when totalDebtIssued >= debtCeiling.
                config.totalDebtIssued += totalInterest;
            }
            v.lastAccrualTimestamp = block.timestamp;
        }
    }
}
