module octopus_finance::oracle_adapter {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;

    /// Capability to update prices (Admin only for now, later Pyth)
    public struct OracleAdminCap has key, store {
        id: UID
    }

    /// The Oracle object storing prices
    public struct Oracle has key, store {
        id: UID,
        prices: sui::table::Table<std::type_name::TypeName, u64>
    }

    fun init(ctx: &mut TxContext) {
        let admin_cap = OracleAdminCap { id: object::new(ctx) };
        let oracle = Oracle {
            id: object::new(ctx),
            prices: sui::table::new(ctx)
        };
        
        transfer::share_object(oracle);
        transfer::public_transfer(admin_cap, sui::tx_context::sender(ctx));
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx)
    }

    /// Update price for a specific coin type
    /// Price is scaled by 1e9 for precision
    public entry fun update_price<T>(
        _: &OracleAdminCap, 
        oracle: &mut Oracle, 
        price: u64
    ) {
        let type_name = std::type_name::get<T>();
        if (sui::table::contains(&oracle.prices, type_name)) {
            let p = sui::table::borrow_mut(&mut oracle.prices, type_name);
            *p = price;
        } else {
            sui::table::add(&mut oracle.prices, type_name, price);
        }
    }

    /// Get price for a coin type
    public fun get_price<T>(oracle: &Oracle): u64 {
        let type_name = std::type_name::get<T>();
        if (sui::table::contains(&oracle.prices, type_name)) {
            *sui::table::borrow(&oracle.prices, type_name)
        } else {
            0 // Return 0 if no price found (safe default for now)
        }
    }
}
