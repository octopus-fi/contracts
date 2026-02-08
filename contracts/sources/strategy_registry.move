module octopus_finance::strategy_registry;

use std::string::String;
use sui::event;
use sui::table::{Self, Table};

// =================== Errors ===================
const EStrategyAlreadyExists: u64 = 0;
const EStrategyNotFound: u64 = 1;

// =================== Structs ===================

/// The Registry shared object
public struct StrategyRegistry has key, store {
    id: UID,
    /// Map: Strategy Name -> Walrus Blob ID
    strategies: Table<String, String>,
}

/// Admin Capability (to register strategies)
public struct RegistryAdminCap has key, store {
    id: UID,
}

// =================== Events ===================

public struct StrategyRegistered has copy, drop {
    name: String,
    blob_id: String,
}

// =================== Init ===================

fun init(ctx: &mut TxContext) {
    let registry = StrategyRegistry {
        id: object::new(ctx),
        strategies: table::new(ctx),
    };

    let admin_cap = RegistryAdminCap {
        id: object::new(ctx),
    };

    transfer::share_object(registry);
    transfer::transfer(admin_cap, tx_context::sender(ctx));
}

// =================== Admin Functions ===================

public entry fun register_strategy(
    _: &RegistryAdminCap,
    registry: &mut StrategyRegistry,
    name: String,
    blob_id: String,
) {
    if (table::contains(&registry.strategies, name)) {
        // Update existing
        let current_id = table::borrow_mut(&mut registry.strategies, name);
        *current_id = blob_id;
    } else {
        // Add newcomer
        table::add(&mut registry.strategies, name, blob_id);
    };

    event::emit(StrategyRegistered {
        name,
        blob_id,
    });
}

// =================== Public View Functions ===================

public fun get_strategy_blob_id(registry: &StrategyRegistry, name: String): String {
    assert!(table::contains(&registry.strategies, name), EStrategyNotFound);
    *table::borrow(&registry.strategies, name)
}

public fun has_strategy(registry: &StrategyRegistry, name: String): bool {
    table::contains(&registry.strategies, name)
}

// =================== Test Helpers ===================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
