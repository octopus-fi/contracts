#[test_only]
module octopus_finance::stage2_tests;

use octopus_finance::liquid_staking::{Self, StakingPool, StakePosition};
use octopus_finance::mocksui::{Self, MOCKSUI};
use octopus_finance::octsui::{Self, OCTSUI};
use octopus_finance::octusd::{Self, OCTUSD};
use octopus_finance::oracle_adapter::{Self, Oracle, OracleAdminCap};
use octopus_finance::vault_manager::{Self, Vault, Bank};
use sui::coin::{Self, TreasuryCap};
use sui::test_scenario;

const ADDR_ADMIN: address = @0xA;
const ADDR_USER: address = @0xB;

#[test]
fun test_stake_and_borrow() {
    let mut scenario = test_scenario::begin(ADDR_ADMIN);

    // 1. Init all modules
    {
        octsui::init_for_testing(test_scenario::ctx(&mut scenario));
        octusd::init_for_testing(test_scenario::ctx(&mut scenario));
        mocksui::init_for_testing(test_scenario::ctx(&mut scenario)); // Init MockSUI
        oracle_adapter::init_for_testing(test_scenario::ctx(&mut scenario));
        // liquid_staking and vault_manager have explicit logic, no test init needed
    };

    // 2. Setup Staking Pool & Bank (Admin deposits TreasuryCaps)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let octsui_cap = test_scenario::take_from_sender<TreasuryCap<OCTSUI>>(&scenario);
        liquid_staking::initialize_staking_pool<MOCKSUI>(
            octsui_cap,
            test_scenario::ctx(&mut scenario),
        );
    };

    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let octusd_cap = test_scenario::take_from_sender<TreasuryCap<OCTUSD>>(&scenario);
        vault_manager::initialize_bank(octusd_cap, test_scenario::ctx(&mut scenario));
    };

    // 3. Set Oracle Price (1 MockSUI = $1.50)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
        // Updating price for MOCKSUI, NOT octSUI (price is for underlying)
        // But wait, vault_manager checks price of T (MOCKSUI).
        oracle_adapter::update_price<MOCKSUI>(&admin_cap, &mut oracle, 1_500_000_000);

        // Also need price for OCTSUI if we were treating it as collateral?
        // The vault holds T, so we price T.

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 4. User Mint MockSUI -> Stakes -> Gets octSUI
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {};

    // Admin mints MockSUI for User
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut mocksui_cap = test_scenario::take_from_sender<TreasuryCap<MOCKSUI>>(&scenario);
        mocksui::mint(
            &mut mocksui_cap,
            100_000_000_000,
            ADDR_USER,
            test_scenario::ctx(&mut scenario),
        ); // 100 mSUI
        test_scenario::return_to_sender(&scenario, mocksui_cap);
    };

    // User Stakes
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut pool = test_scenario::take_shared<StakingPool<MOCKSUI>>(&scenario);
        let payment = test_scenario::take_from_sender<coin::Coin<MOCKSUI>>(&scenario);

        liquid_staking::stake<MOCKSUI>(&mut pool, payment, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(pool);
    };
    
    // Take and hold the StakePosition (created by staking)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let position = test_scenario::take_from_sender<StakePosition>(&scenario);
        // Just verify it exists, return it
        test_scenario::return_to_sender(&scenario, position);
    };

    // 5. User Creates Vault (for OCTSUI collateral)
    // Oops, Liquid Staking gives octSUI.
    // Vault Manager takes `T`.
    // If we stake `MOCKSUI`, we get `OCTSUI`.
    // Then we deposit `OCTSUI` into a Vault.
    // So the Vault should be `Vault<OCTSUI>`, NOT `Vault<MOCKSUI>`.
    // The previous design was: `Vault` holds `OCTSUI`.
    // Refactor made `Vault<T>`.
    // Correct usage: `create_vault<OCTSUI>`.

    // 5. User Creates Vault (for OCTSUI collateral)
    // First, Admin must create the Registry for OCTSUI
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        vault_manager::create_registry<OCTSUI>(test_scenario::ctx(&mut scenario));
    };

    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut registry = test_scenario::take_shared<vault_manager::VaultRegistry<OCTSUI>>(
            &scenario,
        );
        vault_manager::create_vault<OCTSUI>(&mut registry, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(registry);
    };

    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut vault = test_scenario::take_from_sender<Vault<OCTSUI>>(&scenario);
        let octsui_coin = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);

        vault_manager::deposit_collateral<OCTSUI>(&mut vault, octsui_coin);

        test_scenario::return_to_sender(&scenario, vault);
    };

    // 6. User Borrows octUSD
    // Collateral is OCTSUI.
    // We need price of OCTSUI.
    // Step 3 set price of MOCKSUI. We need price of OCTSUI too.
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
        // Assuming 1 octSUI ~ 1 MockSUI = $1.50
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 1_500_000_000);

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut vault = test_scenario::take_from_sender<Vault<OCTSUI>>(&scenario);
        let mut bank = test_scenario::take_shared<Bank>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        // Borrow 50 OCTUSD
        vault_manager::borrow<OCTSUI>(
            &mut bank,
            &mut vault,
            &oracle,
            50_000_000_000,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_to_sender(&scenario, vault);
        test_scenario::return_shared(oracle);
        test_scenario::return_shared(bank);
    };

    // 7. Verify Balances
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let octusd_coin = test_scenario::take_from_sender<coin::Coin<OCTUSD>>(&scenario);
        assert!(coin::value(&octusd_coin) == 50_000_000_000, 0);
        test_scenario::return_to_sender(&scenario, octusd_coin);
    };

    test_scenario::end(scenario);
}
