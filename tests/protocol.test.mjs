import { test } from "node:test";
import assert from "node:assert/strict";
import {
  calculateCollateralValue,
  calculateCollateralRatio,
  calculateMaxMintableDebt,
  calculateStabilityFeeAccrual,
  calculateLiquidationSeizure,
  isVaultSolvent,
  BPS_DIVISOR,
  WAD,
  SECONDS_PER_YEAR
} from "../dist/index.js";

test("1. Collateral valuation across decimal precisions (18-dec WETH & 8-dec WBTC)", () => {
  // 2 WETH at $3000/ETH
  const ethValue = calculateCollateralValue(2n * 10n ** 18n, 3000n * WAD, 18);
  assert.equal(ethValue, 6000n * WAD);

  // 1 WBTC (8 decimals) at $60,000/BTC
  const btcValue = calculateCollateralValue(1n * 10n ** 8n, 60000n * WAD, 8);
  assert.equal(btcValue, 60000n * WAD);
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

test("4. Continuous stability fee accrual over time", () => {
  const debt = 100000n * WAD;
  const stabilityFeeBps = 200n; // 2.00% APR

  // Accrual over 1 full year = 2000 QUSD
  const oneYearAccrual = calculateStabilityFeeAccrual(debt, stabilityFeeBps, SECONDS_PER_YEAR);
  assert.equal(oneYearAccrual, 2000n * WAD);

  // Accrual over 180 days
  const halfYearAccrual = calculateStabilityFeeAccrual(debt, stabilityFeeBps, SECONDS_PER_YEAR / 2n);
  assert.equal(halfYearAccrual, 1000n * WAD);
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

test("6. Fail-closed error handling on invalid negative inputs", () => {
  assert.throws(() => calculateCollateralValue(-1n, 1000n * WAD), /NEGATIVE_VALUE/);
  assert.throws(() => calculateCollateralRatio(-100n, 100n), /NEGATIVE_VALUE/);
  assert.throws(() => calculateMaxMintableDebt(1000n, 5000n), /INVALID_MIN_RATIO/);
  assert.throws(() => calculateLiquidationSeizure(0n, 1000n * WAD), /INSUFFICIENT_DEBT_TO_REPAY/);
  assert.throws(() => calculateLiquidationSeizure(100n, 0n), /INVALID_PRICE/);
});
