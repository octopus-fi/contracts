module octopus_finance::octusd {
    use std::option;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// The type identifier of coin. The coin will have a type
    /// `coin::Coin<OCTUSD>` and depend on this module.
    public struct OCTUSD has drop {}

    /// Register the managed currency to acquire its `TreasuryCap`. Because
    /// this is a module initializer, it ensures the currency only gets
    /// registered once.
    fun init(witness: OCTUSD, ctx: &mut TxContext) {
        // Get a treasury cap for the coin and give it to the transaction sender
        let (treasury_cap, metadata) = coin::create_currency<OCTUSD>(
            witness, 
            9, 
            b"octUSD", 
            b"Octopus Stablecoin", 
            b"Overcollateralized Stablecoin for Octopus Finance", 
            option::none(), 
            ctx
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    /// Manager can burn coins
    public entry fun burn(treasury_cap: &mut TreasuryCap<OCTUSD>, coin: Coin<OCTUSD>) {
        coin::burn(treasury_cap, coin);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(OCTUSD {}, ctx)
    }

    /// Manager can mint coins
    public entry fun mint(
        treasury_cap: &mut TreasuryCap<OCTUSD>, 
        amount: u64, 
        recipient: address, 
        ctx: &mut TxContext
    ) {
        let coin = coin::mint(treasury_cap, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }
}
