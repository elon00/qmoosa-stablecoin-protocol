// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IQmoosaVaultManager {
    struct CollateralType {
        address token;
        uint256 minCollateralRatioBps;
        uint256 liquidationPenaltyBps;
        uint256 stabilityFeeBps;
        uint256 debtCeiling;
        uint256 totalDebtIssued;
        bool isAllowed;
    }

    struct Vault {
        address owner;
        address collateralToken;
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastAccrualTimestamp;
    }

    event VaultOpened(uint256 indexed vaultId, address indexed owner, address indexed collateralToken);
    event CollateralDeposited(uint256 indexed vaultId, uint256 amount);
    event CollateralWithdrawn(uint256 indexed vaultId, address indexed recipient, uint256 amount);
    event StablecoinMinted(uint256 indexed vaultId, address indexed recipient, uint256 amount);
    event DebtRepaid(uint256 indexed vaultId, address indexed repayer, uint256 amount);
    event VaultLiquidated(uint256 indexed vaultId, address indexed liquidator, uint256 debtCovered, uint256 collateralSeized);

    function openVault(address collateralToken) external returns (uint256 vaultId);
    function depositCollateral(uint256 vaultId, uint256 amount) external;
    function withdrawCollateral(uint256 vaultId, uint256 amount) external;
    function mintStablecoin(uint256 vaultId, uint256 amount) external;
    function repayDebt(uint256 vaultId, uint256 amount) external;
    function liquidateVault(uint256 vaultId, uint256 debtToCover) external;
}
