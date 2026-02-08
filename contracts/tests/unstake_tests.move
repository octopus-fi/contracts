#[test_only]
module octopus_finance::unstake_tests;

use octopus_finance::liquid_staking::{Self, StakingPool, StakePosition};
use octopus_finance::mocksui::{Self, MOCKSUI};
use octopus_finance::octsui::{Self, OCTSUI};
use sui::clock;
use sui::coin::{Self, TreasuryCap};
use sui::test_scenario;

const ADDR_ADMIN: address = @0xA;
const ADDR_USER: address = @0xB;

#[test]
fun test_unstake_updates_shares() {
    let mut scenario = test_scenario::begin(ADDR_ADMIN);

    // Create clock for testing
    let mut test_clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // 1. Init all modules
    {
        octsui::init_for_testing(test_scenario::ctx(&mut scenario));
        mocksui::init_for_testing(test_scenario::ctx(&mut scenario));
    };

    // 2. Setup Staking Pool
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let octsui_cap = test_scenario::take_from_sender<TreasuryCap<OCTSUI>>(&scenario);
        liquid_staking::initialize_staking_pool<MOCKSUI>(
            octsui_cap,
            &test_clock,
            test_scenario::ctx(&mut scenario),
        );
    };

    // 3. Convert Clock to shared object (if needed internally, but here passed by reference)
    // Actually initialize_staking_pool didn't share it, we just keep it local for testing.

    // 4. Mint MockSUI to User
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut mocksui_cap = test_scenario::take_from_sender<TreasuryCap<MOCKSUI>>(&scenario);
        mocksui::mint(
            &mut mocksui_cap,
            100_000_000_000, // 100 mSUI
            ADDR_USER,
            test_scenario::ctx(&mut scenario),
        );
        test_scenario::return_to_sender(&scenario, mocksui_cap);
    };

    // 5. User Stakes MockSUI
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut pool = test_scenario::take_shared<StakingPool<MOCKSUI>>(&scenario);
        let payment = test_scenario::take_from_sender<coin::Coin<MOCKSUI>>(&scenario);

        liquid_staking::stake<MOCKSUI>(
            &mut pool,
            payment,
            &test_clock,
            test_scenario::ctx(&mut scenario),
        );
        test_scenario::return_shared(pool);
    };

    // 6. Verify Position and octSUI
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let pool = test_scenario::take_shared<StakingPool<MOCKSUI>>(&scenario);
        let position = test_scenario::take_shared<StakePosition>(&scenario);
        let octsui_coin = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);

        // Verify initial state
        assert!(coin::value(&octsui_coin) == 100_000_000_000, 1);
        assert!(liquid_staking::get_shares(&position) == 100_000_000_000, 2);
        assert!(liquid_staking::get_total_shares(&pool) == 100_000_000_000, 3);

        test_scenario::return_shared(pool);
        test_scenario::return_shared(position);
        test_scenario::return_to_sender(&scenario, octsui_coin);
    };

    // 7. Unstake HALF
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut pool = test_scenario::take_shared<StakingPool<MOCKSUI>>(&scenario);
        let mut position = test_scenario::take_shared<StakePosition>(&scenario);
        let mut octsui_coin = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);

        // Split 50 mSUI worth of octSUI
        let payment = coin::split(
            &mut octsui_coin,
            50_000_000_000,
            test_scenario::ctx(&mut scenario),
        );

        liquid_staking::unstake<MOCKSUI>(
            &mut pool,
            &mut position,
            payment,
            &test_clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(pool);
        test_scenario::return_shared(position);
        test_scenario::return_to_sender(&scenario, octsui_coin);
    };

    // 8. Verify Updated State
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let pool = test_scenario::take_shared<StakingPool<MOCKSUI>>(&scenario);
        let position = test_scenario::take_shared<StakePosition>(&scenario);

        // User should have 50 mSUI of octSUI left
        let octsui_coin = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);
        assert!(coin::value(&octsui_coin) == 50_000_000_000, 4);

        // User should have 50 mSUI of UNSTAKED MOCKSUI (plus maybe previous change? No, previous was 0)
        let mocksui_coin = test_scenario::take_from_sender<coin::Coin<MOCKSUI>>(&scenario);
        assert!(coin::value(&mocksui_coin) == 50_000_000_000, 5);

        // CRITICAL CHECK: Shares should be reduced!
        assert!(liquid_staking::get_shares(&position) == 50_000_000_000, 6);
        assert!(liquid_staking::get_total_shares(&pool) == 50_000_000_000, 7);

        test_scenario::return_shared(pool);
        test_scenario::return_shared(position);
        test_scenario::return_to_sender(&scenario, octsui_coin);
        test_scenario::return_to_sender(&scenario, mocksui_coin);
    };

    clock::destroy_for_testing(test_clock);
    test_scenario::end(scenario);
}
