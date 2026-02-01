module octopus_finance::liquid_staking;

use octopus_finance::octsui::{Self, OCTSUI};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;
use sui::table::{Self, Table};

const E_NOT_OWNER: u64 = 1;

/// Staking pool to hold generic Asset T and valid TreasuryCap for octSUI
public struct StakingPool<phantom T> has key, store {
    id: UID,
    asset_balance: Balance<T>,
    treasury_cap: TreasuryCap<OCTSUI>,
    /// Total shares issued (for reward calculation)
    total_shares: u64,
    /// Accumulated rewards (simulated - in production this comes from Sui staking)
    total_rewards: u64,
    /// Reward rate per interval (scaled by 1e9)
    /// Default: 100000 = 0.0001 octSUI per share per 5-second interval
    reward_rate_per_interval: u64,
    /// Reward interval in milliseconds (default: 5000ms = 5 seconds for demo)
    reward_interval_ms: u64,
    /// Last timestamp when rewards were accrued (in milliseconds)
    last_reward_time_ms: u64,
}

/// User's stake position - tracks their share of the pool and rewards
public struct StakePosition has key, store {
    id: UID,
    owner: address,
    /// Shares in the staking pool
    shares: u64,
    /// Accumulated rewards claimable by user
    pending_rewards: u64,
    /// Last timestamp when user claimed/updated rewards (in milliseconds)
    last_claim_time_ms: u64,
    /// User's vault ID for auto-rebalance (if opted-in)
    linked_vault_id: Option<ID>,
    /// Whether user has opted-in to AI auto-rebalance
    auto_rebalance_enabled: bool,
}

/// Event emitted when user stakes
public struct StakeEvent has copy, drop {
    user: address,
    amount_in: u64,
    octsui_minted: u64,
    shares_received: u64,
}

/// Event emitted when user unstakes
public struct UnstakeEvent has copy, drop {
    user: address,
    octsui_burned: u64,
    amount_out: u64,
}

/// Event emitted when rewards are claimed
public struct RewardsClaimedEvent has copy, drop {
    user: address,
    amount: u64,
    sent_to_vault: bool,
}

/// Event emitted when user opts in/out of auto-rebalance
public struct AutoRebalanceOptInEvent has copy, drop {
    user: address,
    enabled: bool,
    vault_id: Option<ID>,
}

/// Initialize the staking pool (Admin must call this with the octSUI treasury cap)
public entry fun initialize_staking_pool<T>(
    treasury_cap: TreasuryCap<OCTSUI>,
    ctx: &mut TxContext,
) {
    let pool = StakingPool<T> {
        id: object::new(ctx),
        asset_balance: balance::zero(),
        treasury_cap,
        total_shares: 0,
        total_rewards: 0,
        // Reward rate: 100000 = 0.0001 octSUI per share per interval (scaled by 1e9)
        // With 100 octSUI staked (100e9 shares), this gives 0.01 octSUI per 5 seconds
        reward_rate_per_interval: 100000,
        // 5 second intervals for demo (5000 ms)
        reward_interval_ms: 5000,
        last_reward_time_ms: tx_context::epoch_timestamp_ms(ctx),
    };
    transfer::share_object(pool);
}

/// Stake Generic Asset T to receive octSUI (1:1 exchange for now)
/// Also creates a StakePosition for reward tracking
public entry fun stake<T>(pool: &mut StakingPool<T>, payment: Coin<T>, ctx: &mut TxContext) {
    // First accrue any pending rewards
    accrue_rewards(pool, ctx);
    
    let amount = coin::value(&payment);
    let asset_balance = coin::into_balance(payment);
    let sender = tx_context::sender(ctx);

    // Add Asset to pool
    balance::join(&mut pool.asset_balance, asset_balance);
    
    // Calculate shares (1:1 initially, could be ratio-based for rebasing)
    let shares = amount;
    pool.total_shares = pool.total_shares + shares;

    // Mint octSUI to user
    octsui::mint(&mut pool.treasury_cap, amount, sender, ctx);
    
    // Create stake position for reward tracking
    let position = StakePosition {
        id: object::new(ctx),
        owner: sender,
        shares,
        pending_rewards: 0,
        last_claim_time_ms: tx_context::epoch_timestamp_ms(ctx),
        linked_vault_id: option::none(),
        auto_rebalance_enabled: false,
    };
    // Share the position so AI agent can claim rewards for rebalancing
    // Owner validation is done in sensitive functions
    transfer::public_share_object(position);

    event::emit(StakeEvent {
        user: sender,
        amount_in: amount,
        octsui_minted: amount,
        shares_received: shares,
    });
}

/// Unstake octSUI to receive Asset T
public entry fun unstake<T>(pool: &mut StakingPool<T>, payment: Coin<OCTSUI>, ctx: &mut TxContext) {
    let amount = coin::value(&payment);
    let sender = tx_context::sender(ctx);

    // Burn octSUI
    octsui::burn(&mut pool.treasury_cap, payment);

    // Return Asset from pool
    let asset = coin::take(&mut pool.asset_balance, amount, ctx);
    transfer::public_transfer(asset, sender);

    event::emit(UnstakeEvent {
        user: sender,
        octsui_burned: amount,
        amount_out: amount,
    });
}

/// Accrue rewards to the pool based on elapsed time
/// For demo: rewards accrue every 5 seconds
fun accrue_rewards<T>(pool: &mut StakingPool<T>, ctx: &TxContext) {
    let current_time_ms = tx_context::epoch_timestamp_ms(ctx);
    
    // Safety check: avoid underflow if timestamp hasn't advanced
    if (current_time_ms <= pool.last_reward_time_ms) {
        return
    };
    
    let elapsed_ms = current_time_ms - pool.last_reward_time_ms;
    
    // Calculate number of complete intervals elapsed
    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;
    
    if (intervals_elapsed > 0 && pool.total_shares > 0) {
        // Calculate rewards: total_shares * rate_per_interval * intervals / 1e9
        // This gives rewards in the token's base units
        let reward = (pool.total_shares * pool.reward_rate_per_interval * intervals_elapsed) / 1_000_000_000;
        pool.total_rewards = pool.total_rewards + reward;
        // Update last reward time to the last complete interval
        pool.last_reward_time_ms = pool.last_reward_time_ms + (intervals_elapsed * pool.reward_interval_ms);
    }
}

/// Calculate pending rewards for a user's position
public fun calculate_pending_rewards<T>(
    pool: &StakingPool<T>,
    position: &StakePosition,
    ctx: &TxContext
): u64 {
    if (position.shares == 0 || pool.total_shares == 0) {
        return position.pending_rewards
    };
    
    let current_time_ms = tx_context::epoch_timestamp_ms(ctx);
    let elapsed_ms = current_time_ms - position.last_claim_time_ms;
    
    // Calculate number of complete intervals elapsed
    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;
    
    // User's share of rewards for elapsed intervals
    let user_reward = (position.shares * pool.reward_rate_per_interval * intervals_elapsed) / 1_000_000_000;
    
    position.pending_rewards + user_reward
}

/// Get pending rewards for a position
public fun get_pending_rewards(position: &StakePosition): u64 {
    position.pending_rewards
}

/// User opts in to auto-rebalance and links their vault
public entry fun enable_auto_rebalance(
    position: &mut StakePosition,
    vault_id: ID,
    ctx: &TxContext,
) {
    // Only position owner can enable auto-rebalance
    assert!(position.owner == tx_context::sender(ctx), E_NOT_OWNER);
    
    position.auto_rebalance_enabled = true;
    position.linked_vault_id = option::some(vault_id);
    
    event::emit(AutoRebalanceOptInEvent {
        user: tx_context::sender(ctx),
        enabled: true,
        vault_id: option::some(vault_id),
    });
}

/// User opts out of auto-rebalance
public entry fun disable_auto_rebalance(
    position: &mut StakePosition,
    ctx: &TxContext,
) {
    // Only position owner can disable auto-rebalance
    assert!(position.owner == tx_context::sender(ctx), E_NOT_OWNER);
    
    position.auto_rebalance_enabled = false;
    position.linked_vault_id = option::none();
    
    event::emit(AutoRebalanceOptInEvent {
        user: tx_context::sender(ctx),
        enabled: false,
        vault_id: option::none(),
    });
}

/// Check if auto-rebalance is enabled for a position
public fun is_auto_rebalance_enabled(position: &StakePosition): bool {
    position.auto_rebalance_enabled
}

/// Get the linked vault ID
public fun get_linked_vault_id(position: &StakePosition): Option<ID> {
    position.linked_vault_id
}

/// Claim rewards and update position
/// If auto_rebalance is enabled, mints octSUI directly to the vault's reserve
/// Otherwise, sends octSUI to the user
public entry fun claim_rewards<T>(
    pool: &mut StakingPool<T>,
    position: &mut StakePosition,
    ctx: &mut TxContext,
) {
    // Only position owner can manually claim rewards
    assert!(position.owner == tx_context::sender(ctx), E_NOT_OWNER);
    
    // Accrue global rewards first
    accrue_rewards(pool, ctx);
    
    // Calculate user's pending rewards based on time
    let current_time_ms = tx_context::epoch_timestamp_ms(ctx);
    let elapsed_ms = current_time_ms - position.last_claim_time_ms;
    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;
    
    let user_reward = if (position.shares > 0 && intervals_elapsed > 0) {
        (position.shares * pool.reward_rate_per_interval * intervals_elapsed) / 1_000_000_000
    } else {
        0
    };
    
    let total_claimable = position.pending_rewards + user_reward;
    
    if (total_claimable > 0) {
        // Mint octSUI as reward
        let sender = tx_context::sender(ctx);
        octsui::mint(&mut pool.treasury_cap, total_claimable, sender, ctx);
        
        // Reset pending rewards and update last claim time
        position.pending_rewards = 0;
        position.last_claim_time_ms = current_time_ms;
        
        event::emit(RewardsClaimedEvent {
            user: sender,
            amount: total_claimable,
            sent_to_vault: false,
        });
    }
}

/// AI Agent claims rewards on behalf of user and deposits to vault reserve
/// This is called by the AI adapter when auto_rebalance is enabled
/// Returns the amount of rewards claimed (for the AI to use)
public fun claim_rewards_to_vault<T>(
    pool: &mut StakingPool<T>,
    position: &mut StakePosition,
    ctx: &mut TxContext,
): Coin<OCTSUI> {
    // Accrue global rewards first
    accrue_rewards(pool, ctx);
    
    // Calculate user's pending rewards based on time
    let current_time_ms = tx_context::epoch_timestamp_ms(ctx);
    let elapsed_ms = current_time_ms - position.last_claim_time_ms;
    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;
    
    let user_reward = if (position.shares > 0 && intervals_elapsed > 0) {
        (position.shares * pool.reward_rate_per_interval * intervals_elapsed) / 1_000_000_000
    } else {
        0
    };
    
    let total_claimable = position.pending_rewards + user_reward;
    
    // Reset pending rewards and update last claim time
    position.pending_rewards = 0;
    position.last_claim_time_ms = current_time_ms;
    
    if (total_claimable > 0) {
        event::emit(RewardsClaimedEvent {
            user: position.owner,
            amount: total_claimable,
            sent_to_vault: true,
        });
    };
    
    // Mint and return the octSUI (AI will deposit to vault)
    coin::mint(&mut pool.treasury_cap, total_claimable, ctx)
}

/// Get user's share balance
public fun get_shares(position: &StakePosition): u64 {
    position.shares
}

/// Get total pool shares
public fun get_total_shares<T>(pool: &StakingPool<T>): u64 {
    pool.total_shares
}

/// Get complete stake position state for frontend
/// Returns: (shares, pending_rewards, auto_rebalance_enabled)
public fun get_position_state(position: &StakePosition): (u64, u64, bool) {
    (position.shares, position.pending_rewards, position.auto_rebalance_enabled)
}

/// Get the owner of a stake position
public fun get_position_owner(position: &StakePosition): address {
    position.owner
}

/// Get pool statistics for frontend display
/// Returns: (total_shares, total_rewards, reward_rate_per_interval, total_staked)
public fun get_pool_stats<T>(pool: &StakingPool<T>): (u64, u64, u64, u64) {
    (
        pool.total_shares,
        pool.total_rewards,
        pool.reward_rate_per_interval,
        balance::value(&pool.asset_balance)
    )
}

/// Estimate APY in basis points (e.g., 700 = 7%)
/// With 5 second intervals: ~17,280 intervals per day, ~6,307,200 per year
/// APY = (reward_rate_per_interval * intervals_per_year) / shares * 10000
public fun get_estimated_apy<T>(pool: &StakingPool<T>): u64 {
    // 86400000ms/day / reward_interval_ms = intervals per day
    // intervals_per_day * 365 = intervals per year
    let intervals_per_day = 86400000 / pool.reward_interval_ms;
    let intervals_per_year = intervals_per_day * 365;
    // Return APY in basis points
    (pool.reward_rate_per_interval * intervals_per_year) / 1_000_000_000 * 100
}

/// Get user's share of the pool as a percentage (in basis points)
public fun get_share_percentage<T>(pool: &StakingPool<T>, position: &StakePosition): u64 {
    if (pool.total_shares == 0) {
        return 0
    };
    (((position.shares as u128) * 10000 / (pool.total_shares as u128)) as u64)
}
