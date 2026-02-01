module octopus_finance::vault_manager;

use octopus_finance::math;
use octopus_finance::octusd::{Self, OCTUSD};
use octopus_finance::oracle_adapter::{Self, Oracle};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::table::{Self, Table};
use sui::transfer;

const E_BORROW_TOO_HIGH: u64 = 1;
const E_VAULT_ALREADY_EXISTS: u64 = 2;
const E_NOT_OWNER: u64 = 3;

/// Global Bank object that holds the stablecoin treasury cap
public struct Bank has key, store {
    id: UID,
    treasury_cap: TreasuryCap<OCTUSD>,
}

/// Registry to track user vaults for a specific collateral type T
public struct VaultRegistry<phantom T> has key {
    id: UID,
    vaults: Table<address, ID>,
}

/// User Vault for generic Collateral T
public struct Vault<phantom T> has key, store {
    id: UID,
    owner: address,
    collateral: Balance<T>,
    debt: u64,
    /// Reserve balance that AI can use for auto-rebalancing
    /// This comes from staking rewards or user-deposited safety margin
    reward_reserve: Balance<T>,
}

/// Initialize the Bank (Admin must call this with the octUSD treasury cap)
public entry fun initialize_bank(treasury_cap: TreasuryCap<OCTUSD>, ctx: &mut TxContext) {
    let bank = Bank {
        id: object::new(ctx),
        treasury_cap,
    };
    transfer::share_object(bank);
}

/// Create a shared Registry for collateral type T
public entry fun create_registry<T>(ctx: &mut TxContext) {
    let registry = VaultRegistry<T> {
        id: object::new(ctx),
        vaults: table::new(ctx),
    };
    transfer::share_object(registry);
}

/// Create a new empty vault for Collateral T and register it
public entry fun create_vault<T>(registry: &mut VaultRegistry<T>, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    assert!(!table::contains(&registry.vaults, sender), E_VAULT_ALREADY_EXISTS);

    let vault = Vault<T> {
        id: object::new(ctx),
        owner: sender,
        collateral: balance::zero(),
        debt: 0,
        reward_reserve: balance::zero(),
    };

    // Register the vault
    table::add(&mut registry.vaults, sender, object::id(&vault));

    // Share the vault so AI agent can interact with it
    // Owner validation is done in sensitive functions (borrow, withdraw)
    transfer::public_share_object(vault);
}

/// Get the Vault ID for a specific user
public fun get_user_vault<T>(registry: &VaultRegistry<T>, user: address): Option<ID> {
    if (table::contains(&registry.vaults, user)) {
        option::some(*table::borrow(&registry.vaults, user))
    } else {
        option::none()
    }
}

/// Get the debt of a vault
public fun get_debt<T>(vault: &Vault<T>): u64 {
    vault.debt
}

/// Get the collateral amount of a vault
public fun get_collateral<T>(vault: &Vault<T>): u64 {
    balance::value(&vault.collateral)
}

/// Deposit Generic Collateral
public entry fun deposit_collateral<T>(vault: &mut Vault<T>, collateral: Coin<T>) {
    let balance = coin::into_balance(collateral);
    balance::join(&mut vault.collateral, balance);
}

/// Borrow octUSD
public entry fun borrow<T>(
    bank: &mut Bank,
    vault: &mut Vault<T>,
    oracle: &Oracle,
    amount: u64,
    ctx: &mut TxContext,
) {
    // Only vault owner can borrow
    assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
    
    // 1. Calculate new debt
    vault.debt = vault.debt + amount;

    // 2. Check health
    let collateral_amount = balance::value(&vault.collateral);
    let price = oracle_adapter::get_price<T>(oracle); // Price of T
    let collateral_val = math::calculate_collateral_value(collateral_amount, price);

    // 70% LTV threshold (7000 bps)
    let max_borrow = math::calculate_max_borrow(collateral_val, 7000);

    assert!(vault.debt <= max_borrow, E_BORROW_TOO_HIGH);

    // 3. Mint octUSD
    octusd::mint(&mut bank.treasury_cap, amount, tx_context::sender(ctx), ctx);
}

/// Repay octUSD
public entry fun repay<T>(bank: &mut Bank, vault: &mut Vault<T>, payment: Coin<OCTUSD>) {
    let amount = coin::value(&payment);
    vault.debt = vault.debt - amount;
    octusd::burn(&mut bank.treasury_cap, payment);
}

/// Withdraw collateral from vault (user must maintain healthy LTV)
public entry fun withdraw_collateral<T>(
    vault: &mut Vault<T>,
    oracle: &Oracle,
    amount: u64,
    ctx: &mut TxContext,
) {
    // Only vault owner can withdraw
    assert!(vault.owner == tx_context::sender(ctx), E_NOT_OWNER);
    
    // 1. Check we have enough collateral
    let current_collateral = balance::value(&vault.collateral);
    assert!(current_collateral >= amount, E_BORROW_TOO_HIGH);
    
    // 2. Calculate remaining collateral value after withdrawal
    let remaining_collateral = current_collateral - amount;
    let price = oracle_adapter::get_price<T>(oracle);
    let remaining_value = math::calculate_collateral_value(remaining_collateral, price);
    
    // 3. Check that remaining collateral still supports the debt (70% LTV)
    let max_debt = math::calculate_max_borrow(remaining_value, 7000);
    assert!(vault.debt <= max_debt, E_BORROW_TOO_HIGH);
    
    // 4. Withdraw collateral
    let withdrawn = coin::take(&mut vault.collateral, amount, ctx);
    transfer::public_transfer(withdrawn, tx_context::sender(ctx));
}

/// Seize collateral during liquidation (called by liquidation module)
public fun seize_collateral<T>(
    vault: &mut Vault<T>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    coin::take(&mut vault.collateral, amount, ctx)
}

/// Event emitted when a vault is auto-rebalanced
public struct RebalanceEvent has copy, drop {
    vault_id: ID,
    timestamp: u64,
    action: vector<u8>,
    amount_added: u64,
}

/// Deposit funds into the reward reserve (for AI to use)
/// This can be called by the user or by the liquid_staking module when rewards accrue
public entry fun deposit_to_reserve<T>(vault: &mut Vault<T>, funds: Coin<T>) {
    let bal = coin::into_balance(funds);
    balance::join(&mut vault.reward_reserve, bal);
}

/// Get the reward reserve balance
public fun get_reward_reserve<T>(vault: &Vault<T>): u64 {
    balance::value(&vault.reward_reserve)
}

/// Get the vault owner
public fun get_vault_owner<T>(vault: &Vault<T>): address {
    vault.owner
}

/// Get complete vault state for frontend display
/// Returns: (collateral, debt, reward_reserve)
public fun get_vault_state<T>(vault: &Vault<T>): (u64, u64, u64) {
    (
        balance::value(&vault.collateral),
        vault.debt,
        balance::value(&vault.reward_reserve)
    )
}

/// Calculate current LTV in basis points (e.g., 5000 = 50%)
public fun get_current_ltv<T>(vault: &Vault<T>, oracle: &Oracle): u64 {
    let debt = vault.debt;
    if (debt == 0) {
        return 0
    };
    
    let collateral = balance::value(&vault.collateral);
    let price = oracle_adapter::get_price<T>(oracle);
    let collateral_value = math::calculate_collateral_value(collateral, price);
    
    if (collateral_value == 0) {
        return 10000 // 100% if no collateral but has debt
    };
    
    (((debt as u128) * 10000 / (collateral_value as u128)) as u64)
}

/// Calculate available borrow amount (how much more user can borrow)
public fun get_available_borrow<T>(vault: &Vault<T>, oracle: &Oracle): u64 {
    let collateral = balance::value(&vault.collateral);
    let price = oracle_adapter::get_price<T>(oracle);
    let collateral_value = math::calculate_collateral_value(collateral, price);
    let max_borrow = math::calculate_max_borrow(collateral_value, 7000); // 70% LTV
    
    if (max_borrow > vault.debt) {
        max_borrow - vault.debt
    } else {
        0
    }
}

/// Calculate withdrawable collateral (max amount user can withdraw while staying healthy)
public fun get_withdrawable_collateral<T>(vault: &Vault<T>, oracle: &Oracle): u64 {
    if (vault.debt == 0) {
        return balance::value(&vault.collateral)
    };
    
    let price = oracle_adapter::get_price<T>(oracle);
    if (price == 0) {
        return 0
    };
    
    // min_collateral_value = debt / 0.7 = debt * 10000 / 7000
    let min_collateral_value = (((vault.debt as u128) * 10000 / 7000) as u64);
    // Convert value to token amount: amount = value * 1e9 / price
    let min_collateral = (((min_collateral_value as u128) * 1_000_000_000 / (price as u128)) as u64);
    
    let current_collateral = balance::value(&vault.collateral);
    if (current_collateral > min_collateral) {
        current_collateral - min_collateral
    } else {
        0
    }
}

/// Move funds from reward_reserve into collateral (AI calls this via ai_adapter)
/// This does NOT require user signature - AI has capability to call this
public fun add_collateral_from_reserve<T>(vault: &mut Vault<T>, amount: u64): u64 {
    let available = balance::value(&vault.reward_reserve);
    let to_add = if (amount > available) { available } else { amount };
    
    if (to_add > 0) {
        let reserve_portion = balance::split(&mut vault.reward_reserve, to_add);
        balance::join(&mut vault.collateral, reserve_portion);
    };
    
    to_add
}

/// Auto-rebalance a vault by moving reserve funds to collateral
/// Called by AI adapter when LTV is too high
public fun auto_rebalance<T>(vault: &mut Vault<T>, amount_needed: u64, ctx: &mut TxContext): u64 {
    let amount_added = add_collateral_from_reserve(vault, amount_needed);
    
    event::emit(RebalanceEvent {
        vault_id: object::id(vault),
        timestamp: tx_context::epoch_timestamp_ms(ctx),
        action: b"Rebalanced",
        amount_added,
    });
    
    amount_added
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {}
