module octopus_finance::liquid_staking;

use octopus_finance::octsui::{Self, OCTSUI};
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin, TreasuryCap};
use sui::event;

const E_NOT_OWNER: u64 = 1;
const E_INSUFFICIENT_SHARES: u64 = 2;

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
    /// 1,157,407 = 5 SUI per 6 hours per staked SUI
    /// Calculation: 6 hours = 4320 intervals (at 5 sec each), rate = 5e9 / 4320 ≈ 1,157,407
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
/// Uses Clock for real-time timestamps (not epoch_timestamp_ms which only updates per epoch)
public entry fun initialize_staking_pool<T>(
    treasury_cap: TreasuryCap<OCTSUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let pool = StakingPool<T> {
        id: object::new(ctx),
        asset_balance: balance::zero(),
        treasury_cap,
        total_shares: 0,
        total_rewards: 0,
        // Reward rate: 1,157,407 = 5 SUI per 6 hours per staked SUI (scaled by 1e9)
        // Calculation: 6 hours = 21,600,000ms = 4320 intervals (at 5 sec each)
        // rate = 5 * 1e9 / 4320 ≈ 1,157,407
        reward_rate_per_interval: 1_157_407,
        // 5 second intervals for demo (5000 ms)
        reward_interval_ms: 5000,
        last_reward_time_ms: clock::timestamp_ms(clock),
    };
    transfer::share_object(pool);
}

/// Stake Generic Asset T to receive octSUI (1:1 exchange for now)
/// Also creates a StakePosition for reward tracking
public entry fun stake<T>(
    pool: &mut StakingPool<T>,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // First accrue any pending rewards
    accrue_rewards(pool, clock);

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
        last_claim_time_ms: clock::timestamp_ms(clock),
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
/// Requires StakePosition to update shares and claim rewards
public entry fun unstake<T>(
    pool: &mut StakingPool<T>,
    position: &mut StakePosition,
    payment: Coin<OCTSUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let amount = coin::value(&payment);
    let sender = tx_context::sender(ctx);

    // Verify ownership
    assert!(position.owner == sender, E_NOT_OWNER);

    // Accrue rewards before modifying shares
    claim_rewards(pool, position, clock, ctx);

    // Decrease shares on position
    // Since stake() mints 1:1 shares for amount, we burn 1:1 shares
    assert!(position.shares >= amount, 0); // TODO: Add better error code
    position.shares = position.shares - amount;

    // Decrease total shares
    assert!(pool.total_shares >= amount, 0);
    pool.total_shares = pool.total_shares - amount;

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
/// Uses Clock for real-time timestamps
fun accrue_rewards<T>(pool: &mut StakingPool<T>, clock: &Clock) {
    let current_time_ms = clock::timestamp_ms(clock);

    // Safety check: avoid underflow if timestamp hasn't advanced or is somehow earlier
    if (current_time_ms <= pool.last_reward_time_ms) {
        return
    };

    // Safe subtraction (underflow already checked above)
    let elapsed_ms = current_time_ms - pool.last_reward_time_ms;

    // Calculate number of complete intervals elapsed
    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;

    if (intervals_elapsed > 0 && pool.total_shares > 0) {
        // Calculate rewards using u128 to prevent overflow:
        // total_shares * rate_per_interval * intervals / 1e9
        // Max values: shares ~10^18, rate ~10^9, intervals ~10^6 → product ~10^33 fits in u128
        let shares_128 = (pool.total_shares as u128);
        let rate_128 = (pool.reward_rate_per_interval as u128);
        let intervals_128 = (intervals_elapsed as u128);

        let reward_128 = (shares_128 * rate_128 * intervals_128) / 1_000_000_000;

        // Safe cast back to u64 (cap at max u64 to prevent overflow)
        let reward = if (reward_128 > (18_446_744_073_709_551_615u128)) {
            18_446_744_073_709_551_615u64 // max u64
        } else {
            (reward_128 as u64)
        };

        // Use saturating add to prevent overflow
        let new_total = (pool.total_rewards as u128) + (reward as u128);
        pool.total_rewards = if (new_total > (18_446_744_073_709_551_615u128)) {
            18_446_744_073_709_551_615u64
        } else {
            (new_total as u64)
        };

        // Update last reward time to the last complete interval
        pool.last_reward_time_ms =
            pool.last_reward_time_ms + (intervals_elapsed * pool.reward_interval_ms);
    }
}

/// Calculate pending rewards for a user's position
public fun calculate_pending_rewards<T>(
    pool: &StakingPool<T>,
    position: &StakePosition,
    clock: &Clock,
): u64 {
    if (position.shares == 0 || pool.total_shares == 0) {
        return position.pending_rewards
    };

    let current_time_ms = clock::timestamp_ms(clock);

    // Safety check: avoid underflow
    if (current_time_ms <= position.last_claim_time_ms) {
        return position.pending_rewards
    };

    let elapsed_ms = current_time_ms - position.last_claim_time_ms;

    // Calculate number of complete intervals elapsed
    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;

    // User's share of rewards for elapsed intervals (using u128 to prevent overflow)
    let shares_128 = (position.shares as u128);
    let rate_128 = (pool.reward_rate_per_interval as u128);
    let intervals_128 = (intervals_elapsed as u128);

    let user_reward_128 = (shares_128 * rate_128 * intervals_128) / 1_000_000_000;

    // Safe cast to u64
    let user_reward = if (user_reward_128 > (18_446_744_073_709_551_615u128)) {
        18_446_744_073_709_551_615u64
    } else {
        (user_reward_128 as u64)
    };

    // Saturating add for pending_rewards + user_reward
    let total_128 = (position.pending_rewards as u128) + (user_reward as u128);
    if (total_128 > (18_446_744_073_709_551_615u128)) {
        18_446_744_073_709_551_615u64
    } else {
        (total_128 as u64)
    }
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
public entry fun disable_auto_rebalance(position: &mut StakePosition, ctx: &TxContext) {
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
    clock: &Clock,
    ctx: &mut TxContext,
) {
    // Only position owner can manually claim rewards
    assert!(position.owner == tx_context::sender(ctx), E_NOT_OWNER);

    // Accrue global rewards first
    accrue_rewards(pool, clock);

    // Calculate user's pending rewards based on time
    let current_time_ms = clock::timestamp_ms(clock);

    // Safety check: avoid underflow
    let elapsed_ms = if (current_time_ms > position.last_claim_time_ms) {
        current_time_ms - position.last_claim_time_ms
    } else {
        0
    };

    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;

    let user_reward = if (position.shares > 0 && intervals_elapsed > 0) {
        // Use u128 intermediate calculation to prevent overflow
        let shares_128 = (position.shares as u128);
        let rate_128 = (pool.reward_rate_per_interval as u128);
        let intervals_128 = (intervals_elapsed as u128);

        let reward_128 = (shares_128 * rate_128 * intervals_128) / 1_000_000_000;

        // Safe cast to u64
        if (reward_128 > (18_446_744_073_709_551_615u128)) {
            18_446_744_073_709_551_615u64
        } else {
            (reward_128 as u64)
        }
    } else {
        0
    };

    // Saturating add for total_claimable
    let total_claimable_128 = (position.pending_rewards as u128) + (user_reward as u128);
    let total_claimable = if (total_claimable_128 > (18_446_744_073_709_551_615u128)) {
        18_446_744_073_709_551_615u64
    } else {
        (total_claimable_128 as u64)
    };

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
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<OCTSUI> {
    // Accrue global rewards first
    accrue_rewards(pool, clock);

    // Calculate user's pending rewards based on time
    let current_time_ms = clock::timestamp_ms(clock);

    // Safety check: avoid underflow
    let elapsed_ms = if (current_time_ms > position.last_claim_time_ms) {
        current_time_ms - position.last_claim_time_ms
    } else {
        0
    };

    let intervals_elapsed = elapsed_ms / pool.reward_interval_ms;

    let user_reward = if (position.shares > 0 && intervals_elapsed > 0) {
        // Use u128 intermediate calculation to prevent overflow
        let shares_128 = (position.shares as u128);
        let rate_128 = (pool.reward_rate_per_interval as u128);
        let intervals_128 = (intervals_elapsed as u128);

        let reward_128 = (shares_128 * rate_128 * intervals_128) / 1_000_000_000;

        // Safe cast to u64
        if (reward_128 > (18_446_744_073_709_551_615u128)) {
            18_446_744_073_709_551_615u64
        } else {
            (reward_128 as u64)
        }
    } else {
        0
    };

    // Saturating add for total_claimable
    let total_claimable_128 = (position.pending_rewards as u128) + (user_reward as u128);
    let total_claimable = if (total_claimable_128 > (18_446_744_073_709_551_615u128)) {
        18_446_744_073_709_551_615u64
    } else {
        (total_claimable_128 as u64)
    };

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
        balance::value(&pool.asset_balance),
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
    // Return APY in basis points (using u128 to avoid overflow)
    let rate_128 = (pool.reward_rate_per_interval as u128);
    let intervals_128 = (intervals_per_year as u128);
    let apy_128 = (rate_128 * intervals_128 * 100) / 1_000_000_000;
    (apy_128 as u64)
}

/// Get user's share of the pool as a percentage (in basis points)
public fun get_share_percentage<T>(pool: &StakingPool<T>, position: &StakePosition): u64 {
    if (pool.total_shares == 0) {
        return 0
    };
    (((position.shares as u128) * 10000 / (pool.total_shares as u128)) as u64)
}
