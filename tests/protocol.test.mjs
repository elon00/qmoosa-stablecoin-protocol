import { test } from "node:test";
import assert from "node:assert/strict";
import {
  calculateCollateralValue,
  calculateCollateralRatio,
  calculateMaxMintableDebt,
  calculateStabilityFeeAccrual,
  calculateLiquidationSeizure,
  calculateBadDebtShortfall,
  isVaultSolvent,
  BPS_DIVISOR,
  WAD,
  SECONDS_PER_YEAR
} from "../dist/index.js";

test("1. Collateral valuation across decimal precisions (18-dec WETH, 8-dec WBTC, 6-dec USDC)", () => {
  // 2 WETH at $3000/ETH
  const ethValue = calculateCollateralValue(2n * 10n ** 18n, 3000n * WAD, 18);
  assert.equal(ethValue, 6000n * WAD);

  // 1 WBTC (8 decimals) at $60,000/BTC
  const btcValue = calculateCollateralValue(1n * 10n ** 8n, 60000n * WAD, 8);
  assert.equal(btcValue, 60000n * WAD);

  // 10,000 USDC (6 decimals) at $1/USDC
  const usdcValue = calculateCollateralValue(10000n * 10n ** 6n, 1n * WAD, 6);
  assert.equal(usdcValue, 10000n * WAD);
});

test("2. Collateral ratio calculation & zero-debt safety", () => {
  const collateralValue = 6000n * WAD;
  const debt = 3000n * WAD;

  // 6000 / 3000 = 200% = 20000 bps
  const ratio = calculateCollateralRatio(collateralValue, debt);
  assert.equal(ratio, 20000n);

  // Zero debt should not throw and return high ratio
  const zeroDebtRatio = calculateCollateralRatio(collateralValue, 0n);
  assert.ok(zeroDebtRatio >= 100000000n);
});

test("3. Maximum mintable debt under 150% minimum collateral ratio", () => {
  const collateralValue = 15000n * WAD;
  const minRatioBps = 15000n; // 150%

  // Max total debt = 15000 / 1.5 = 10000 QUSD
  const maxMint = calculateMaxMintableDebt(collateralValue, minRatioBps, 0n);
  assert.equal(maxMint, 10000n * WAD);

  // If already borrowed 4000 QUSD, max additional is 6000 QUSD
  const additionalMint = calculateMaxMintableDebt(collateralValue, minRatioBps, 4000n * WAD);
  assert.equal(additionalMint, 6000n * WAD);

  // If already borrowed 10000 QUSD, max additional is 0
  const zeroAdditional = calculateMaxMintableDebt(collateralValue, minRatioBps, 10000n * WAD);
  assert.equal(zeroAdditional, 0n);
});

test("4. Continuous compounding stability fee accrual over time", () => {
  const debt = 100000n * WAD;
  const stabilityFeeBps = 200n; // 2.00% APR

  // Linear interest = 2000 QUSD, Compound term = (2000 * 200) / 20000 = 20 QUSD -> 2020 QUSD
  const oneYearAccrual = calculateStabilityFeeAccrual(debt, stabilityFeeBps, SECONDS_PER_YEAR);
  assert.equal(oneYearAccrual, 2020n * WAD);

  // Accrual over 180 days: linear = 1000 QUSD, compound term = (1000 * 100) / 20000 = 5 QUSD -> 1005 QUSD
  const halfYearAccrual = calculateStabilityFeeAccrual(debt, stabilityFeeBps, SECONDS_PER_YEAR / 2n);
  assert.equal(halfYearAccrual, 1005n * WAD);
});

test("5. Liquidation seizure math with 10% liquidator penalty", () => {
  // Debt to cover: 3000 QUSD
  // Collateral price: $3000/ETH
  // Base collateral needed: 1 ETH
  // 10% penalty bonus: 0.1 ETH -> Total seized: 1.1 ETH
  const { collateralToSeize, penaltyCollateral } = calculateLiquidationSeizure(
    3000n * WAD,
    3000n * WAD,
    18,
    1000n // 10%
  );

  assert.equal(collateralToSeize, (11n * 10n ** 18n) / 10n); // 1.1 ETH
  assert.equal(penaltyCollateral, 10n ** 17n); // 0.1 ETH
});

test("6. Bad debt deficit calculation on underwater shortfall", () => {
  // Debt to cover: 3000 QUSD. Price: $1000/ETH. Theoretical seizure at 10% penalty = 3.3 ETH.
  // Vault only has 1.0 ETH collateral available.
  const { collateralToSeize, badDebtShortfall } = calculateBadDebtShortfall(
    3000n * WAD,
    1n * 10n ** 18n,
    1000n * WAD,
    18,
    1000n
  );

  assert.equal(collateralToSeize, 1n * 10n ** 18n); // capped at available collateral
  // 1 ETH at $1000 covers 1000 / 1.1 = ~909.09 QUSD of debt. Shortfall = ~2090.9 QUSD
  assert.ok(badDebtShortfall > 2000n * WAD);
});

test("7. Fail-closed error handling on invalid negative inputs", () => {
  assert.throws(() => calculateCollateralValue(-1n, 1000n * WAD), /NEGATIVE_VALUE/);
  assert.throws(() => calculateCollateralRatio(-100n, 100n), /NEGATIVE_VALUE/);
  assert.throws(() => calculateMaxMintableDebt(1000n, 5000n), /INVALID_MIN_RATIO/);
  assert.throws(() => calculateLiquidationSeizure(0n, 1000n * WAD), /INSUFFICIENT_DEBT_TO_REPAY/);
  assert.throws(() => calculateLiquidationSeizure(100n, 0n), /INVALID_PRICE/);
});
