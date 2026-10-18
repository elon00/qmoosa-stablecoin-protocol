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
    mapping(address => uint256) public oraclePrices; // Price in WAD ($18 decimals) per 1 token

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
        uint256 minCollateralRatioBps,
        uint256 liquidationPenaltyBps,
        uint256 stabilityFeeBps,
        uint256 debtCeiling
    ) external onlyOwner {
        require(token != address(0), "VAULT_MANAGER: ZERO_TOKEN");
        require(minCollateralRatioBps >= 10000, "VAULT_MANAGER: MIN_RATIO_BELOW_100");
        require(liquidationPenaltyBps <= 5000, "VAULT_MANAGER: PENALTY_TOO_HIGH");

        collateralConfigs[token] = CollateralType({
            token: token,
            minCollateralRatioBps: minCollateralRatioBps,
            liquidationPenaltyBps: liquidationPenaltyBps,
            stabilityFeeBps: stabilityFeeBps,
            debtCeiling: debtCeiling,
            totalDebtIssued: collateralConfigs[token].totalDebtIssued,
            isAllowed: true
        });
    }

    function setOraclePrice(address token, uint256 priceWad) external onlyOwner {
        require(token != address(0), "VAULT_MANAGER: ZERO_TOKEN");
        require(priceWad > 0, "VAULT_MANAGER: ZERO_PRICE");
        oraclePrices[token] = priceWad;
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
        uint256 price = oraclePrices[v.collateralToken];
        require(price > 0, "VAULT_MANAGER: ORACLE_PRICE_NOT_SET");

        // Value to cover with liquidation penalty
        uint256 repayValueWithPenalty = (actualCover * (BPS_DIVISOR + config.liquidationPenaltyBps)) / BPS_DIVISOR;
        uint256 collateralToSeize = (repayValueWithPenalty * WAD) / price;

        if (collateralToSeize > v.collateralAmount) {
            collateralToSeize = v.collateralAmount;
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
        uint256 price = oraclePrices[collateralToken];
        return (amount * price) / WAD;
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
            uint256 interest = (v.debtAmount * config.stabilityFeeBps * elapsed) / (BPS_DIVISOR * SECONDS_PER_YEAR);
            v.debtAmount += interest;
            config.totalDebtIssued += interest;
            v.lastAccrualTimestamp = block.timestamp;
        }
    }
}
