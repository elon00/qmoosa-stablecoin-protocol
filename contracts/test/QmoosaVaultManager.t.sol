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

    address public owner = address(this);
    address public alice = address(0xAA11);
    address public bobLiquidator = address(0xBB22);

    uint256 public constant WAD = 1e18;
    uint256 public constant INITIAL_ETH_PRICE = 3000 * 1e18; // $3000

    function setUp() public {
        stablecoin = new QmoosaStablecoin();
        manager = new QmoosaVaultManager(address(stablecoin));
        stablecoin.addMinter(address(manager));

        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Configure WETH collateral: 150% min ratio (15000 bps), 10% penalty (1000 bps), 2% fee (200 bps), 1M ceiling
        manager.setCollateralConfig(
            address(weth),
            15000,
            1000,
            200,
            1_000_000 * 1e18
        );
        manager.setOraclePrice(address(weth), INITIAL_ETH_PRICE);

        // Fund Alice and Bob
        weth.mint(alice, 100 * 1e18);
        weth.mint(bobLiquidator, 100 * 1e18);

        vm.prank(alice);
        weth.approve(address(manager), type(uint256).max);

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

    function testMintStablecoinSolvent() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18); // $30,000 value

        // Max mint at 150% = 30,000 / 1.5 = 20,000 QUSD. Mint 10,000 QUSD (300% ratio)
        vm.prank(alice);
        manager.mintStablecoin(vaultId, 10_000 * 1e18);

        assertEq(stablecoin.balanceOf(alice), 10_000 * 1e18);
        assertTrue(manager.isVaultSolvent(vaultId));
    }

    function testMintUndercollateralizedReverts() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18); // $30,000 value

        // Minting 21,000 QUSD requires > 1.5 * 21000 = $31,500 collateral -> Reverts
        vm.prank(alice);
        vm.expectRevert("VAULT_MANAGER: MINT_BREAKS_SOLVENCY");
        manager.mintStablecoin(vaultId, 21_000 * 1e18);
    }

    function testRepayDebtAndWithdraw() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);

        vm.prank(alice);
        manager.mintStablecoin(vaultId, 5_000 * 1e18);

        // Repay full 5000 QUSD
        vm.prank(alice);
        stablecoin.approve(address(manager), 5_000 * 1e18);

        vm.prank(alice);
        manager.repayDebt(vaultId, 5_000 * 1e18);

        assertEq(stablecoin.balanceOf(alice), 0);

        // Withdraw all 10 ETH
        vm.prank(alice);
        manager.withdrawCollateral(vaultId, 10 * 1e18);

        assertEq(weth.balanceOf(alice), 100 * 1e18);
    }

    function testLiquidationUndercollateralizedVault() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18); // 10 ETH

        vm.prank(alice);
        manager.mintStablecoin(vaultId, 18_000 * 1e18); // $18k debt (166% ratio at $3000)

        // Price drops to $2000 -> 10 ETH = $20,000 -> Ratio = 20000 / 18000 = 111% (< 150% threshold)
        manager.setOraclePrice(address(weth), 2000 * 1e18);
        assertFalse(manager.isVaultSolvent(vaultId));

        // Fund Bob with QUSD to liquidate
        vm.prank(alice);
        stablecoin.transfer(bobLiquidator, 10_000 * 1e18);

        vm.prank(bobLiquidator);
        stablecoin.approve(address(manager), type(uint256).max);

        uint256 bobWethBefore = weth.balanceOf(bobLiquidator);

        // Bob liquidates 10,000 QUSD
        vm.prank(bobLiquidator);
        manager.liquidateVault(vaultId, 10_000 * 1e18);

        // Debt covered: 10,000. With 10% penalty = $11,000 worth of ETH. At $2000/ETH = 5.5 ETH seized
        uint256 bobWethAfter = weth.balanceOf(bobLiquidator);
        assertEq(bobWethAfter - bobWethBefore, 55 * 1e17); // 5.5 ETH
    }

    function testLiquidatingSolventVaultReverts() public {
        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);

        vm.prank(alice);
        manager.mintStablecoin(vaultId, 5_000 * 1e18); // 600% ratio (super solvent)

        // Fund Bob
        vm.prank(alice);
        stablecoin.transfer(bobLiquidator, 5_000 * 1e18);

        vm.prank(bobLiquidator);
        stablecoin.approve(address(manager), type(uint256).max);

        vm.prank(bobLiquidator);
        vm.expectRevert("VAULT_MANAGER: VAULT_IS_SOLVENT");
        manager.liquidateVault(vaultId, 2_000 * 1e18);
    }

    function testDebtCeilingBreachedReverts() public {
        // Lower debt ceiling to 5,000 QUSD
        manager.setCollateralConfig(
            address(weth),
            15000,
            1000,
            200,
            5_000 * 1e18
        );

        vm.prank(alice);
        uint256 vaultId = manager.openVault(address(weth));

        vm.prank(alice);
        manager.depositCollateral(vaultId, 10 * 1e18);

        vm.prank(alice);
        vm.expectRevert("VAULT_MANAGER: DEBT_CEILING_BREACHED");
        manager.mintStablecoin(vaultId, 6_000 * 1e18);
    }
}
