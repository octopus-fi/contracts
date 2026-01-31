module octopus_finance::octsui {
    use std::option;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// The type identifier of coin. The coin will have a type
    /// `coin::Coin<OCTSUI>` and depend on this module.
    public struct OCTSUI has drop {}

    /// Register the managed currency to acquire its `TreasuryCap`. Because
    /// this is a module initializer, it ensures the currency only gets
    /// registered once.
    fun init(witness: OCTSUI, ctx: &mut TxContext) {
        // Get a treasury cap for the coin and give it to the transaction sender
        let (treasury_cap, metadata) = coin::create_currency<OCTSUI>(
            witness, 
            9, 
            b"octSUI", 
            b"Octopus Staked SUI", 
            b"Liquid Staking Token for Octopus Finance", 
            option::none(), 
            ctx
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    /// Manager can burn coins
    public entry fun burn(treasury_cap: &mut TreasuryCap<OCTSUI>, coin: Coin<OCTSUI>) {
        coin::burn(treasury_cap, coin);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(OCTSUI {}, ctx)
    }

    /// Manager can mint coins
    public entry fun mint(
        treasury_cap: &mut TreasuryCap<OCTSUI>, 
        amount: u64, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        let coin = coin::mint(treasury_cap, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }
}
