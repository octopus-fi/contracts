module octopus_finance::liquidation;

use octopus_finance::math;
use octopus_finance::octusd::{Self, OCTUSD};
use octopus_finance::oracle_adapter::{Self, Oracle};
use octopus_finance::vault_manager::{Self, Vault, Bank};
use std::string::{Self, String};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// Errors
const E_VAULT_HEALTHY: u64 = 0;
const E_INSUFFICIENT_REPAYMENT: u64 = 1;
const E_INSUFFICIENT_COLLATERAL: u64 = 2;

// Constants
const LIQUIDATION_THRESHOLD_BPS: u64 = 8000; // 80% - vault is liquidatable when LTV > 80%
const LIQUIDATION_BONUS_BPS: u64 = 500; // 5% bonus for liquidator
const SCALING_FACTOR: u64 = 1_000_000_000; // 1e9

/// Event emitted when a liquidation occurs
public struct LiquidationEvent has copy, drop {
    vault_id: ID,
    liquidator: address,
    debt_before: u64,
    amount_repaid: u64,
    collateral_seized: u64,
    walrus_proof_id: String,
}

/// Check if a vault is liquidatable
/// Returns true if the vault's LTV exceeds the liquidation threshold
public fun is_liquidatable<T>(vault: &Vault<T>, oracle: &Oracle): bool {
    let debt = vault_manager::get_debt(vault);
    if (debt == 0) {
        return false
    };
    
    let collateral = vault_manager::get_collateral(vault);
    let price = oracle_adapter::get_price<T>(oracle);
    let collateral_value = math::calculate_collateral_value(collateral, price);
    
    if (collateral_value == 0) {
        return true // No collateral but has debt = liquidatable
    };
    
    // Calculate current LTV in basis points
    // LTV = (debt / collateral_value) * 10000
    let ltv_bps = ((debt as u128) * 10000 / (collateral_value as u128) as u64);
    
    // Liquidatable if LTV > 80%
    ltv_bps > LIQUIDATION_THRESHOLD_BPS
}

/// Get the health factor of a vault (scaled by 1e9)
/// Health < 1e9 means liquidatable
public fun get_health_factor<T>(vault: &Vault<T>, oracle: &Oracle): u64 {
    let debt = vault_manager::get_debt(vault);
    if (debt == 0) {
        return 18446744073709551615 // u64::MAX - infinite health
    };
    
    let collateral = vault_manager::get_collateral(vault);
    let price = oracle_adapter::get_price<T>(oracle);
    let collateral_value = math::calculate_collateral_value(collateral, price);
    
    // Health = (collateral_value * liquidation_threshold) / debt
    // Scaled by 1e9 for precision
    math::calculate_health_factor(collateral_value, debt, LIQUIDATION_THRESHOLD_BPS)
}

/// Get liquidation parameters (for frontend display)
/// Returns: (liquidation_threshold_bps, liquidation_bonus_bps)
public fun get_liquidation_params(): (u64, u64) {
    (LIQUIDATION_THRESHOLD_BPS, LIQUIDATION_BONUS_BPS)
}

/// Calculate potential liquidation profit for liquidators
/// Given a vault and repay amount, returns collateral they would receive
public fun calculate_liquidation_reward<T>(
    vault: &Vault<T>,
    oracle: &Oracle,
    repay_amount: u64,
): (u64, u64) {
    let price = oracle_adapter::get_price<T>(oracle);
    if (price == 0) {
        return (0, 0)
    };
    
    // collateral_to_seize = (repay_amount * 10500 / 10000) / price * SCALING_FACTOR
    let repay_with_bonus = (((repay_amount as u128) * 10500 / 10000) as u64);
    let collateral_to_seize = ((((repay_with_bonus as u128) * (SCALING_FACTOR as u128)) / (price as u128)) as u64);
    
    // Bonus = collateral_to_seize - (repay_amount / price * SCALING_FACTOR)
    let collateral_without_bonus = ((((repay_amount as u128) * (SCALING_FACTOR as u128)) / (price as u128)) as u64);
    let bonus_amount = collateral_to_seize - collateral_without_bonus;
    
    (collateral_to_seize, bonus_amount)
}

/// Get vault liquidation status with full details for frontend
/// Returns: (is_liquidatable, health_factor, current_ltv_bps, debt, collateral, collateral_value)
public fun get_liquidation_status<T>(
    vault: &Vault<T>,
    oracle: &Oracle,
): (bool, u64, u64, u64, u64, u64) {
    let debt = vault_manager::get_debt(vault);
    let collateral = vault_manager::get_collateral(vault);
    let price = oracle_adapter::get_price<T>(oracle);
    let collateral_value = math::calculate_collateral_value(collateral, price);
    
    let health = if (debt > 0 && collateral_value > 0) {
        math::calculate_health_factor(collateral_value, debt, LIQUIDATION_THRESHOLD_BPS)
    } else if (debt == 0) {
        18446744073709551615 // u64::MAX
    } else {
        0 // No collateral but has debt
    };
    
    let ltv_bps = if (collateral_value > 0) {
        (((debt as u128) * 10000 / (collateral_value as u128)) as u64)
    } else if (debt > 0) {
        10000 // 100%
    } else {
        0
    };
    
    let is_liq = ltv_bps > LIQUIDATION_THRESHOLD_BPS;
    
    (is_liq, health, ltv_bps, debt, collateral, collateral_value)
}

/// Calculate max repayable amount for a liquidation
/// Returns the maximum octUSD that can be used to liquidate this vault
public fun get_max_liquidation_amount<T>(vault: &Vault<T>): u64 {
    // Can repay up to 100% of debt in one liquidation
    vault_manager::get_debt(vault)
}

/// Liquidate an unhealthy vault
/// Liquidator provides octUSD to repay debt and receives collateral at a discount
public entry fun liquidate<T>(
    bank: &mut Bank,
    vault: &mut Vault<T>,
    oracle: &Oracle,
    repayment: Coin<OCTUSD>,
    walrus_proof_id: vector<u8>,
    ctx: &mut TxContext,
) {
    // 1. Verify vault is liquidatable
    assert!(is_liquidatable(vault, oracle), E_VAULT_HEALTHY);
    
    let debt_before = vault_manager::get_debt(vault);
    let repay_amount = coin::value(&repayment);
    
    // 2. Calculate collateral to seize
    // Liquidator gets: (repay_amount * (1 + bonus)) worth of collateral
    // Bonus = 5%, so multiplier = 10500 / 10000
    let price = oracle_adapter::get_price<T>(oracle);
    assert!(price > 0, E_INSUFFICIENT_COLLATERAL);
    
    // collateral_to_seize = (repay_amount * 10500 / 10000) / price * SCALING_FACTOR
    let repay_with_bonus = ((repay_amount as u128) * 10500 / 10000 as u64);
    let collateral_to_seize = (((repay_with_bonus as u128) * (SCALING_FACTOR as u128) / (price as u128)) as u64);
    
    // 3. Verify vault has enough collateral
    let vault_collateral = vault_manager::get_collateral(vault);
    assert!(vault_collateral >= collateral_to_seize, E_INSUFFICIENT_COLLATERAL);
    
    // 4. Repay the debt (burns octUSD)
    vault_manager::repay(bank, vault, repayment);
    
    // 5. Seize collateral and send to liquidator
    let seized_collateral = vault_manager::seize_collateral(vault, collateral_to_seize, ctx);
    transfer::public_transfer(seized_collateral, tx_context::sender(ctx));
    
    // 6. Emit event with Walrus proof reference
    let proof_str = string::utf8(walrus_proof_id);
    
    event::emit(LiquidationEvent {
        vault_id: object::id(vault),
        liquidator: tx_context::sender(ctx),
        debt_before,
        amount_repaid: repay_amount,
        collateral_seized: collateral_to_seize,
        walrus_proof_id: proof_str,
    });
}
