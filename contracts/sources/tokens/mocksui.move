module octopus_finance::mocksui;

use std::option;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::transfer;
use sui::tx_context::{Self, TxContext};

/// A Mock SUI token for testing logic with huge supply
public struct MOCKSUI has drop {}

fun init(witness: MOCKSUI, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency<MOCKSUI>(
        witness,
        9,
        b"mSUI",
        b"Mock SUI",
        b"Mock SUI for testing",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
}

/// Mint Mock SUI
public entry fun mint(
    treasury_cap: &mut TreasuryCap<MOCKSUI>,
    amount: u64,
    recipient: address,
    ctx: &mut TxContext,
) {
    let coin = coin::mint(treasury_cap, amount, ctx);
    transfer::public_transfer(coin, recipient);
}

/// Burn Mock SUI
public entry fun burn(treasury_cap: &mut TreasuryCap<MOCKSUI>, coin: Coin<MOCKSUI>) {
    coin::burn(treasury_cap, coin);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(MOCKSUI {}, ctx)
}
