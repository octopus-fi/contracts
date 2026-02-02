module octopus_finance::strategy_registry;

use std::string::{Self, String};
use sui::event;
use sui::object::{Self, UID, ID};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

// Error codes
const E_STRATEGY_ALREADY_EXISTS: u64 = 0;

/// Event emitted when a new strategy is registered
public struct StrategyRegistered has copy, drop {
    id: ID,
    name: String,
    blob_id: String,
}

/// Represents a verified strategy stored on Walrus
public struct VaultStrategy has key, store {
    id: UID,
    name: String,
    creator: address,
    /// The Walrus Blob ID where the full strategy JSON/code is stored
    /// The contract doesn't need the data, it just points to it.
    blob_id: String,
    /// On-chain metadata for quick filtering
    risk_score: u8,
    apy_bps: u64,
}

/// Registry to track all strategies (shared object)
public struct Registry has key {
    id: UID,
    // In a real app, we might use a Table or Bag here
    // For simplicity/hackathon, we'll just emit events and let indexers track
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
    });
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Register a new strategy.
/// The user must have ALREADY uploaded the strategy to Walrus and got the `blob_id`.
public entry fun register_strategy(
    _registry: &mut Registry, // Not strictly used in this simple version but good for future
    name: vector<u8>,
    blob_id: vector<u8>,
    risk_score: u8,
    apy_bps: u64,
    ctx: &mut TxContext,
) {
    let id = object::new(ctx);
    let strategy_id = object::uid_to_inner(&id);
    let name_str = string::utf8(name);
    let blob_str = string::utf8(blob_id);

    let strategy = VaultStrategy {
        id,
        name: name_str,
        creator: tx_context::sender(ctx),
        blob_id: blob_str,
        risk_score,
        apy_bps,
    };

    // Emit event so frontend can find it
    event::emit(StrategyRegistered {
        id: strategy_id,
        name: strategy.name,
        blob_id: strategy.blob_id,
    });

    // Make the strategy object public/shared so anyone can verify it
    transfer::public_share_object(strategy);
}
