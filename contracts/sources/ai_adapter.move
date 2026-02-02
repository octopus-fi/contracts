module octopus_finance::ai_adapter;

use octopus_finance::liquid_staking::{Self, StakingPool, StakePosition};
use octopus_finance::math;
use octopus_finance::octsui::OCTSUI;
use octopus_finance::oracle_adapter::{Self, Oracle};
use octopus_finance::vault_manager::{Self, Vault};
use sui::event;

// Errors
const E_UNAUTHORIZED: u64 = 0;
const E_NOT_AUTO_REBALANCE: u64 = 2;

/// Capability granting AI permission to manage a vault
public struct AICapability has key {
    id: UID,
    authorized_vault_id: ID,
    allowed_operations: vector<u8>, // simplistic permission string
}

/// Event for AI actions
public struct AIActionEvent has copy, drop {
    vault_id: ID,
    action: vector<u8>,
    reason: vector<u8>,
    rewards_claimed: u64,
    collateral_added: u64,
}

/// User grants permission to an AI agent
public entry fun authorize_ai<T>(vault: &Vault<T>, agent_address: address, ctx: &mut TxContext) {
    let cap = AICapability {
        id: object::new(ctx),
        authorized_vault_id: object::id(vault),
        allowed_operations: b"rebalance",
    };
    transfer::transfer(cap, agent_address);
}

/// AI Agent executes rebalance using ONLY the vault's existing reward_reserve
/// Use this when rewards have already been deposited to the vault
public entry fun ai_rebalance<T>(
    cap: &AICapability,
    vault: &mut Vault<T>,
    oracle: &Oracle,
    ctx: &mut TxContext,
) {
    assert!(cap.authorized_vault_id == object::id(vault), E_UNAUTHORIZED);

    let debt = vault_manager::get_debt(vault);
    let collateral = vault_manager::get_collateral(vault);
    let price = oracle_adapter::get_price<T>(oracle);

    let collateral_val = math::calculate_collateral_value(collateral, price);

    // Check LTV. If > 60%, take action
    // 60% = 6000 bps (warning threshold, below 70% borrow limit and 80% liquidation)
    let max_safe_debt = math::calculate_max_borrow(collateral_val, 6000);

    if (debt > max_safe_debt) {
        // Risk is high! Calculate how much extra collateral we need
        // To get back to 50% LTV (safe buffer)
        let target_collateral_val = debt * 2;
        let additional_value_needed = if (target_collateral_val > collateral_val) {
            target_collateral_val - collateral_val
        } else {
            0
        };
        
        // Convert value to token amount using u128 to avoid overflow
        let amount_needed = if (price > 0) {
            let val_128 = (additional_value_needed as u128);
            let scaling_128 = 1_000_000_000u128;
            let price_128 = (price as u128);
            ((val_128 * scaling_128 / price_128) as u64)
        } else {
            0
        };
        
        // Use reward reserve to add collateral
        let amount_added = vault_manager::auto_rebalance(vault, amount_needed, ctx);
        
        if (amount_added > 0) {
            event::emit(AIActionEvent {
                vault_id: object::id(vault),
                action: b"REBALANCED",
                reason: b"Added collateral from reserve",
                rewards_claimed: 0,
                collateral_added: amount_added,
            });
        } else {
            event::emit(AIActionEvent {
                vault_id: object::id(vault),
                action: b"WARNING",
                reason: b"LTV > 60%, no reserve funds",
                rewards_claimed: 0,
                collateral_added: 0,
            });
        }
    } else {
        event::emit(AIActionEvent {
            vault_id: object::id(vault),
            action: b"MONITOR",
            reason: b"Healthy",
            rewards_claimed: 0,
            collateral_added: 0,
        });
    }
}

/// AI Agent claims staking rewards and deposits them to vault reserve, then rebalances
/// This is the MAIN function - claims rewards from staking → deposits to vault → rebalances
/// User must have:
/// 1. Authorized AI with authorize_ai()
/// 2. Opted in with liquid_staking::enable_auto_rebalance()
/// 
/// T = the underlying staking asset (e.g., MOCKSUI)
/// The vault holds OCTSUI (the liquid staking token)
/// The pool is StakingPool<T> where T is the underlying
public entry fun ai_claim_and_rebalance<T>(
    cap: &AICapability,
    pool: &mut StakingPool<T>,
    position: &mut StakePosition,
    vault: &mut Vault<OCTSUI>,
    oracle: &Oracle,
    ctx: &mut TxContext,
) {
    // 1. Verify AI is authorized for this vault
    assert!(cap.authorized_vault_id == object::id(vault), E_UNAUTHORIZED);
    
    // 2. Verify user has opted-in to auto-rebalance
    assert!(liquid_staking::is_auto_rebalance_enabled(position), E_NOT_AUTO_REBALANCE);
    
    // 3. Verify the position is linked to this vault
    let linked_vault = liquid_staking::get_linked_vault_id(position);
    assert!(option::is_some(&linked_vault), E_NOT_AUTO_REBALANCE);
    assert!(*option::borrow(&linked_vault) == object::id(vault), E_NOT_AUTO_REBALANCE);
    
    // 4. Claim rewards from staking pool → returns octSUI Coin
    let rewards = liquid_staking::claim_rewards_to_vault(pool, position, ctx);
    let rewards_amount = coin::value(&rewards);
    
    // 5. Deposit rewards to vault's reserve
    if (rewards_amount > 0) {
        vault_manager::deposit_to_reserve(vault, rewards);
    } else {
        // No rewards to claim, destroy zero coin
        coin::destroy_zero(rewards);
    };
    
    // 6. Now check if rebalancing is needed
    let debt = vault_manager::get_debt(vault);
    let collateral = vault_manager::get_collateral(vault);
    let price = oracle_adapter::get_price<OCTSUI>(oracle);
    let collateral_val = math::calculate_collateral_value(collateral, price);
    
    let max_safe_debt = math::calculate_max_borrow(collateral_val, 6000); // 60%
    
    if (debt > max_safe_debt) {
        // Calculate how much extra collateral needed for 50% LTV
        let target_collateral_val = debt * 2;
        let additional_value_needed = if (target_collateral_val > collateral_val) {
            target_collateral_val - collateral_val
        } else {
            0
        };
        
        let amount_needed = if (price > 0) {
            let val_128 = (additional_value_needed as u128);
            let scaling_128 = 1_000_000_000u128;
            let price_128 = (price as u128);
            ((val_128 * scaling_128 / price_128) as u64)
        } else {
            0
        };
        
        // Move from reserve to collateral
        let amount_added = vault_manager::auto_rebalance(vault, amount_needed, ctx);
        
        event::emit(AIActionEvent {
            vault_id: object::id(vault),
            action: b"CLAIMED_AND_REBALANCED",
            reason: b"Used staking rewards to add collateral",
            rewards_claimed: rewards_amount,
            collateral_added: amount_added,
        });
    } else {
        // Vault is healthy, just deposited rewards to reserve for future
        event::emit(AIActionEvent {
            vault_id: object::id(vault),
            action: b"REWARDS_DEPOSITED",
            reason: b"Vault healthy, rewards added to reserve",
            rewards_claimed: rewards_amount,
            collateral_added: 0,
        });
    }
}

/// Get the vault ID authorized for this AI capability
public fun get_authorized_vault_id(cap: &AICapability): ID {
    cap.authorized_vault_id
}

/// Get allowed operations for this AI capability
public fun get_allowed_operations(cap: &AICapability): vector<u8> {
    cap.allowed_operations
}

/// Check if AI can rebalance a specific vault (helper for frontend)
/// Returns true if the capability authorizes the given vault
public fun can_rebalance_vault(cap: &AICapability, vault_id: ID): bool {
    cap.authorized_vault_id == vault_id
}

/// Calculate if vault needs rebalancing (for frontend display)
/// Returns: (needs_rebalance, current_ltv_bps, reserve_available)
public fun check_rebalance_needed<T>(
    vault: &Vault<T>,
    oracle: &Oracle,
): (bool, u64, u64) {
    let debt = vault_manager::get_debt(vault);
    let collateral = vault_manager::get_collateral(vault);
    let reserve = vault_manager::get_reward_reserve(vault);
    let price = oracle_adapter::get_price<T>(oracle);
    
    if (debt == 0 || collateral == 0) {
        return (false, 0, reserve)
    };
    
    let collateral_val = math::calculate_collateral_value(collateral, price);
    let current_ltv = if (collateral_val > 0) {
        (((debt as u128) * 10000 / (collateral_val as u128)) as u64)
    } else {
        10000
    };
    
    // Needs rebalance if LTV > 60% (6000 bps)
    let needs_rebalance = current_ltv > 6000;
    
    (needs_rebalance, current_ltv, reserve)
}

/// Calculate how much collateral would be added if AI rebalances now
public fun estimate_rebalance_effect<T>(
    vault: &Vault<T>,
    oracle: &Oracle,
): (u64, u64) {
    let debt = vault_manager::get_debt(vault);
    let collateral = vault_manager::get_collateral(vault);
    let reserve = vault_manager::get_reward_reserve(vault);
    let price = oracle_adapter::get_price<T>(oracle);
    
    let collateral_val = math::calculate_collateral_value(collateral, price);
    
    // Calculate amount needed to get to 50% LTV
    let target_collateral_val = debt * 2;
    let additional_value_needed = if (target_collateral_val > collateral_val) {
        target_collateral_val - collateral_val
    } else {
        0
    };
    
    let amount_needed = if (price > 0) {
        (((additional_value_needed as u128) * 1_000_000_000 / (price as u128)) as u64)
    } else {
        0
    };
    
    // Amount that would actually be added (min of needed and available)
    let would_add = if (amount_needed > reserve) { reserve } else { amount_needed };
    
    // Calculate new LTV after rebalance
    let new_collateral = collateral + would_add;
    let new_collateral_val = math::calculate_collateral_value(new_collateral, price);
    let new_ltv = if (new_collateral_val > 0 && debt > 0) {
        (((debt as u128) * 10000 / (new_collateral_val as u128)) as u64)
    } else {
        0
    };
    
    (would_add, new_ltv)
}

// Need to import coin for the new function
use sui::coin;
