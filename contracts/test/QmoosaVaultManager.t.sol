// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Test.sol";
import "../src/interfaces/IERC20.sol";
import "../src/QmoosaStablecoin.sol";
import "../src/QmoosaVaultManager.sol";
import "../src/test/MockERC20.sol";

contract QmoosaVaultManagerTest is Test {
    QmoosaStablecoin public stablecoin;
    QmoosaVaultManager public manager;
    MockERC20 public weth;
    MockERC20 public wbtc;
    MockERC20 public usdc;

    address public owner = address(this);
    address public alice = address(0xAA11);
    address public bobLiquidator = address(0xBB22);

    uint256 public constant WAD = 1e18;
    uint256 public constant INITIAL_ETH_PRICE = 3000 * 1e18; // $3000
    uint256 public constant INITIAL_BTC_PRICE = 60000 * 1e18; // $60,000
    uint256 public constant INITIAL_USDC_PRICE = 1 * 1e18; // $1.00

    function setUp() public {
        stablecoin = new QmoosaStablecoin();
        manager = new QmoosaVaultManager(address(stablecoin));
        stablecoin.addMinter(address(manager));

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Configure WETH collateral: 150% min ratio (15000 bps), 10% penalty (1000 bps), 2% fee (200 bps), 1M ceiling
        manager.setCollateralConfig(
            address(weth),
            18,
            15000,
            1000,
            200,
            1_000_000 * 1e18
        );
        manager.setOraclePrice(address(weth), INITIAL_ETH_PRICE);

        // Configure WBTC collateral: 8 decimals, 150% min ratio, 10% penalty, 2% fee, 1M ceiling
        manager.setCollateralConfig(
            address(wbtc),
            8,
            15000,
            1000,
            200,
            1_000_000 * 1e18
        );
        manager.setOraclePrice(address(wbtc), INITIAL_BTC_PRICE);

        // Configure USDC collateral: 6 decimals, 110% min ratio, 5% penalty, 1% fee, 2M ceiling
        manager.setCollateralConfig(
            address(usdc),
            6,
            11000,
            500,
            100,
            2_000_000 * 1e18
        );
        manager.setOraclePrice(address(usdc), INITIAL_USDC_PRICE);

        // Fund Alice and Bob
        weth.mint(alice, 100 * 1e18);
        wbtc.mint(alice, 10 * 1e8);
        usdc.mint(alice, 100_000 * 1e6);

        weth.mint(bobLiquidator, 100 * 1e18);

        vm.prank(alice);
        weth.approve(address(manager), type(uint256).max);

        vm.prank(alice);
        wbtc.approve(address(manager), type(uint256).max);

        vm.prank(alice);
        usdc.approve(address(manager), type(uint256).max);

        vm.prank(bobLiquidator);
        weth.approve(address(manager), type(uint256).max);
    }

    function testOpenVaultAndDeposit() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));
        assertEq(vaultId, 1);

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);

        (address vaultOwner, address token, uint256 collAmount, uint256 debt, ) = manager.vaults(vaultId);
        assertEq(vaultOwner, alice);
        assertEq(token, address(weth));
        assertEq(collAmount, 10 * 1e18);
        assertEq(debt, 0);
    }

    function testDecimalNormalizationWBTC() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(wbtc));

        // Deposit 1 WBTC (10^8 units) at $60,000 -> Value must be 60,000 WAD
        vm.prank(alice);
        manager.depositCollateral(vaultId, 1 * 1e8);

        uint256 value = manager.getCollateralValue(address(wbtc), 1 * 1e8);
        assertEq(value, 60_000 * 1e18);

        // Can mint up to 60,000 / 1.5 = 40,000 QUSD
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 30_000 * 1e18);
        assertEq(stablecoin.balanceOf(alice), 30_000 * 1e18);
        assertTrue(manager.isVaultSolvent(vaultId));
    }

    function testDecimalNormalizationUSDC() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(usdc));

        // Deposit 10,000 USDC (10,000 * 10^6) at $1.00 -> Value must be 10,000 WAD
        vm.prank(alice);
        manager.depositCollateral(vaultId, 10_000 * 1e6);

        uint256 value = manager.getCollateralValue(address(usdc), 10_000 * 1e6);
        assertEq(value, 10_000 * 1e18);

        // At 110% ratio, mint 8,000 QUSD (8000 * 1.1 = 8800 <= 10000)
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 8_000 * 1e18);
        assertEq(stablecoin.balanceOf(alice), 8_000 * 1e18);
        assertTrue(manager.isVaultSolvent(vaultId));
    }

    function testOracleStalenessReverts() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));
        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);

        // Warp time forward past maxOracleStaleness (3600 seconds)
        vm.warp(block.timestamp + 3601);

        // Calling mintStablecoin checks solvency which checks getCollateralValue, reverting on stale oracle
        vm.prank(alice);
        vm.expectRevert("VAULT_MANAGER: ORACLE_PRICE_STALE");
        manager.mintStablecoin(vaultId, 5_000 * 1e18);

        // Refresh oracle price restores solvency evaluation
        manager.setOraclePrice(address(weth), INITIAL_ETH_PRICE);
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 5_000 * 1e18);
        assertEq(stablecoin.balanceOf(alice), 5_000 * 1e18);
    }

    function testOracleDeviationBoundsAndOverride() public {
        // Current ETH price is $3000. Max deviation is 50% (5000 bps)
        // Trying to set price to $5000 (66% increase) without override reverts
        vm.expectRevert("VAULT_MANAGER: PRICE_DEVIATION_EXCEEDED");
        manager.setOraclePrice(address(weth), 5000 * 1e18);

        // Price within 50% (e.g. $4000 = 33% increase) succeeds
        manager.setOraclePrice(address(weth), 4000 * 1e18);
        assertEq(manager.getOraclePrice(address(weth)), 4000 * 1e18);

        // Emergency override allows arbitrary price update
        manager.overrideOraclePrice(address(weth), 10000 * 1e18);
        assertEq(manager.getOraclePrice(address(weth)), 10000 * 1e18);
    }

    function testCompoundingStabilityFeeAccrual() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));
        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 10_000 * 1e18);

        // Warp 1 year (31536000 seconds)
        vm.warp(block.timestamp + 31536000);
        manager.setOraclePrice(address(weth), INITIAL_ETH_PRICE); // refresh oracle

        // Refresh vault via zero-repay or state inspection
        vm.prank(alice);
        manager.repayDebt(vaultId, 1);

        (, , , uint256 debtAfter, ) = manager.vaults(vaultId);
        // At 2% fee over 1 year:
        // Linear interest = 10000 * 0.02 = 200 QUSD
        // Compounding term = (200 * 0.02) / 2 = 2 QUSD
        // Total interest ~ 202 QUSD -> Total debt should be > 10200
        assertGe(debtAfter, 10_200 * 1e18);
    }

    function testDebtCeilingAllowsAccrualBlocksNewMint() public {
        // Set ceiling to 10,000 QUSD
        manager.setCollateralConfig(address(weth), 18, 15000, 1000, 200, 10_000 * 1e18);

        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));
        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 10_000 * 1e18);

        // Accrue interest over 1 year
        vm.warp(block.timestamp + 31536000);
        manager.setOraclePrice(address(weth), INITIAL_ETH_PRICE);

        // Repaying 1 wei triggers interest accrual which pushes total debt beyond 10,000
        vm.prank(alice);
        manager.repayDebt(vaultId, 1);

        (address token, uint8 dec, uint256 minR, uint256 pen, uint256 fee, uint256 ceil, uint256 totalDebtIssued, bool isAllowed) = manager.collateralConfigs(address(weth));
        assertGt(totalDebtIssued, 10_000 * 1e18);

        // New minting is strictly blocked
        vm.prank(alice);
        vm.expectRevert("VAULT_MANAGER: DEBT_CEILING_BREACHED");
        manager.mintStablecoin(vaultId, 100 * 1e18);
    }

    function testBadDebtAccountingOnShortfallLiquidation() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));
        vm.prank(alice);
        manager.depositCollateral(vaultId, 1 * 1e18); // 1 ETH at $3000
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 1_500 * 1e18); // $1500 debt

        // Flash crash: ETH drops to $500 -> 1 ETH is worth only $500, but debt is $1500!
        manager.overrideOraclePrice(address(weth), 500 * 1e18);

        // Alice funds Bob
        vm.prank(alice);
        stablecoin.transfer(bobLiquidator, 1_500 * 1e18);

        vm.prank(bobLiquidator);
        stablecoin.approve(address(manager), type(uint256).max);

        // Bob liquidates 1500 QUSD. Vault only has 1 ETH worth $500.
        // Shortfall occurs!
        vm.prank(bobLiquidator);
        manager.liquidateVault(vaultId, 1_500 * 1e18);

        assertGt(manager.protocolBadDebt(), 0);
        assertEq(weth.balanceOf(bobLiquidator), 101 * 1e18); // Bob received the 1 ETH
    }
}
