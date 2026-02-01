module octopus_finance::math;

/// Fixed point number scaling (9 decimal places for tokens)
const SCALING_FACTOR: u128 = 1_000_000_000;
const PERCENTAGE_SCALING: u128 = 10_000; // 100% = 10000 (2 decimals)

/// Calculate Collateral Value in USD
/// collateral_amount: raw amount of token (e.g. 1 octSUI = 1e9)
/// price: price per token in USD (scaled by 1e9)
/// Returns value in USD (scaled by 1e9)
public fun calculate_collateral_value(collateral_amount: u64, price: u64): u64 {
    let val = (collateral_amount as u128) * (price as u128) / SCALING_FACTOR;
    (val as u64)
}

/// Calculate Max Borrow Amount based on LTV
/// collateral_value_usd: Collateral value in USD (scaled 1e9)
/// ltv_bps: LTV in basis points (e.g., 7000 = 70%)
public fun calculate_max_borrow(collateral_value_usd: u64, ltv_bps: u64): u64 {
    let max = (collateral_value_usd as u128) * (ltv_bps as u128) / PERCENTAGE_SCALING;
    (max as u64)
}

/// Calculate Health Factor
/// Health = (Collateral Value * Liquidation Threshold) / Debt
/// If Debt is 0, Health is effectively infinite (we return u64::MAX)
public fun calculate_health_factor(
    collateral_value_usd: u64,
    debt: u64,
    liquidation_threshold_bps: u64,
): u64 {
    if (debt == 0) {
        return 18446744073709551615 // u64::MAX
    };

    let weighted_collat =
        (collateral_value_usd as u128) * (liquidation_threshold_bps as u128) / PERCENTAGE_SCALING;
    let health = (weighted_collat * SCALING_FACTOR) / (debt as u128); // Rescale to standard precision
    (health as u64)
}
