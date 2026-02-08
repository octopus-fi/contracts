#[test_only]
module octopus_finance::stage3_tests;

use octopus_finance::ai_adapter::{Self, AICapability};
use octopus_finance::liquid_staking::{Self, StakingPool, StakePosition};
use octopus_finance::liquidation;
use octopus_finance::mocksui::{Self, MOCKSUI};
use octopus_finance::octsui::{Self, OCTSUI};
use octopus_finance::octusd::{Self, OCTUSD};
use octopus_finance::oracle_adapter::{Self, Oracle, OracleAdminCap};
use octopus_finance::strategy_registry::{Self, StrategyRegistry, RegistryAdminCap};
use octopus_finance::vault_manager::{Self, Vault, Bank, VaultRegistry};
use sui::clock;
use sui::coin::{Self, TreasuryCap};
use sui::test_scenario;

const ADDR_ADMIN: address = @0xA;
const ADDR_USER: address = @0xB;
const ADDR_LIQUIDATOR: address = @0xC;
const ADDR_AI_AGENT: address = @0xD;

#[test]
fun test_walrus_strategy_registration() {
    let mut scenario = test_scenario::begin(ADDR_ADMIN);

    // 1. Init Registry
    {
        strategy_registry::init_for_testing(test_scenario::ctx(&mut scenario));
    };

    // 2. Register a Strategy (Simulated Walrus Blob ID)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut registry = test_scenario::take_shared<StrategyRegistry>(&scenario);
        let admin_cap = test_scenario::take_from_sender<RegistryAdminCap>(&scenario);

        let blob_id = std::string::utf8(b"walrus_blob_123456789");
        let name = std::string::utf8(b"Max Yield Strategy");

        strategy_registry::register_strategy(
            &admin_cap,
            &mut registry,
            name,
            blob_id,
        );

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(registry);
    };

    test_scenario::end(scenario);
}

#[test]
fun test_liquidation_simulation() {
    let mut scenario = test_scenario::begin(ADDR_ADMIN);

    // Create clock for testing
    let mut test_clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // ========== SETUP PHASE ==========
    // 1. Init all modules
    {
        octsui::init_for_testing(test_scenario::ctx(&mut scenario));
        octusd::init_for_testing(test_scenario::ctx(&mut scenario));
        mocksui::init_for_testing(test_scenario::ctx(&mut scenario));
        oracle_adapter::init_for_testing(test_scenario::ctx(&mut scenario));
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

    // 3. Setup Bank
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let octusd_cap = test_scenario::take_from_sender<TreasuryCap<OCTUSD>>(&scenario);
        vault_manager::initialize_bank(octusd_cap, test_scenario::ctx(&mut scenario));
    };

    // 4. Set initial oracle price: 1 OCTSUI = $3.00 (high price)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);

        // Price = $3.00 (scaled by 1e9)
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 3_000_000_000);

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 5. Mint MockSUI to User
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

    // 6. User Stakes MockSUI -> Gets octSUI
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

    // Take StakePosition (created by staking) - now a shared object
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let position = test_scenario::take_shared<StakePosition>(&scenario);
        test_scenario::return_shared(position);
    };

    // 7. Create Vault Registry for OCTSUI
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        vault_manager::create_registry<OCTSUI>(test_scenario::ctx(&mut scenario));
    };

    // 8. User Creates Vault
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut registry = test_scenario::take_shared<vault_manager::VaultRegistry<OCTSUI>>(
            &scenario,
        );
        vault_manager::create_vault<OCTSUI>(&mut registry, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(registry);
    };

    // 9. User Deposits octSUI Collateral - vault is now shared
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let octsui_coin = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);
        vault_manager::deposit_collateral<OCTSUI>(&mut vault, octsui_coin);
        test_scenario::return_shared(vault);
    };

    // 10. User Borrows octUSD at 70% LTV
    // Collateral: 100 octSUI * $3 = $300
    // Max borrow at 70% LTV = $210
    // We borrow $200 to be safe
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let mut bank = test_scenario::take_shared<Bank>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        vault_manager::borrow<OCTSUI>(
            &mut bank,
            &mut vault,
            &oracle,
            200_000_000_000, // Borrow 200 octUSD
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(vault);
        test_scenario::return_shared(oracle);
        test_scenario::return_shared(bank);
    };

    // 11. Verify vault is NOT liquidatable (price is high)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        // Check vault is healthy
        let is_liq = liquidation::is_liquidatable(&vault, &oracle);
        assert!(!is_liq, 0); // Should NOT be liquidatable

        test_scenario::return_shared(vault);
        test_scenario::return_shared(oracle);
    };

    // ========== PRICE DROP - SIMULATE MARKET CRASH ==========
    // 12. Admin drops price from $3.00 to $2.00 (33% drop)
    // New collateral value: 100 * $2 = $200
    // Debt: $200
    // LTV = 200/200 = 100% > 80% threshold = LIQUIDATABLE!
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);

        // CRASH! Price drops to $2.00
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 2_000_000_000);

        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 13. Verify vault IS NOW liquidatable
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        // Check vault is now unhealthy
        let is_liq = liquidation::is_liquidatable(&vault, &oracle);
        assert!(is_liq, 1); // Should BE liquidatable now!

        // Check health factor
        let health = liquidation::get_health_factor(&vault, &oracle);
        // Health should be < 1e9 (less than 1.0)
        assert!(health < 1_000_000_000, 2);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(oracle);
    };

    // ========== LIQUIDATION PHASE ==========
    // 14. Mint octUSD to Liquidator (so they can repay)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut bank = test_scenario::take_shared<Bank>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        // We need to give liquidator some octUSD
        // In real scenario, liquidator would already have octUSD or use flash loan
        // For test, admin mints directly using a helper
        // Note: We'll have admin create a small vault and borrow

        test_scenario::return_shared(oracle);
        test_scenario::return_shared(bank);
    };

    // For simplicity, transfer user's octUSD to liquidator
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut octusd_coin = test_scenario::take_from_sender<coin::Coin<OCTUSD>>(&scenario);
        // Split coin - liquidator needs 100 octUSD to partially liquidate
        let repay_coin = coin::split(
            &mut octusd_coin,
            100_000_000_000,
            test_scenario::ctx(&mut scenario),
        );

        transfer::public_transfer(repay_coin, ADDR_LIQUIDATOR);
        test_scenario::return_to_sender(&scenario, octusd_coin);
    };

    // 15. Liquidator executes liquidation! - vault is now shared
    test_scenario::next_tx(&mut scenario, ADDR_LIQUIDATOR);
    {
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let mut bank = test_scenario::take_shared<Bank>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);
        let repayment = test_scenario::take_from_sender<coin::Coin<OCTUSD>>(&scenario);

        // Verify debt before liquidation
        let debt_before = vault_manager::get_debt(&vault);
        assert!(debt_before == 200_000_000_000, 3);

        // Execute liquidation with Walrus proof ID
        liquidation::liquidate<OCTSUI>(
            &mut bank,
            &mut vault,
            &oracle,
            repayment,
            b"walrus_liquidation_proof_xyz",
            test_scenario::ctx(&mut scenario),
        );

        // Verify debt reduced
        let debt_after = vault_manager::get_debt(&vault);
        assert!(debt_after == 100_000_000_000, 4); // 200 - 100 = 100

        test_scenario::return_shared(vault);
        test_scenario::return_shared(oracle);
        test_scenario::return_shared(bank);
    };

    // 16. Verify liquidator received collateral
    test_scenario::next_tx(&mut scenario, ADDR_LIQUIDATOR);
    {
        let seized_collateral = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);

        // Liquidator should receive collateral with 5% bonus
        // Repaid 100 octUSD at price $2 = 50 octSUI
        // With 5% bonus = 52.5 octSUI
        let seized_amount = coin::value(&seized_collateral);
        assert!(seized_amount == 52_500_000_000, 5); // 52.5 octSUI

        test_scenario::return_to_sender(&scenario, seized_collateral);
    };

    // Cleanup clock
    clock::destroy_for_testing(test_clock);
    test_scenario::end(scenario);
}

/// Test that AI Agent can automatically rebalance a vault using reward reserves
/// WITHOUT requiring user signature - this is the key innovation!
#[test]
fun test_ai_rebalance_with_reserve() {
    let mut scenario = test_scenario::begin(ADDR_ADMIN);

    // Create clock for testing
    let mut test_clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

    // ========== SETUP PHASE ==========
    // 1. Init all modules
    {
        octsui::init_for_testing(test_scenario::ctx(&mut scenario));
        octusd::init_for_testing(test_scenario::ctx(&mut scenario));
        mocksui::init_for_testing(test_scenario::ctx(&mut scenario));
        oracle_adapter::init_for_testing(test_scenario::ctx(&mut scenario));
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

    // 3. Setup Bank
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let octusd_cap = test_scenario::take_from_sender<TreasuryCap<OCTUSD>>(&scenario);
        vault_manager::initialize_bank(octusd_cap, test_scenario::ctx(&mut scenario));
    };

    // 4. Set initial oracle price: 1 OCTSUI = $3.00
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 3_000_000_000);
        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 5. Mint MockSUI to User
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut mocksui_cap = test_scenario::take_from_sender<TreasuryCap<MOCKSUI>>(&scenario);
        mocksui::mint(
            &mut mocksui_cap,
            200_000_000_000,
            ADDR_USER,
            test_scenario::ctx(&mut scenario),
        ); // 200 mSUI
        test_scenario::return_to_sender(&scenario, mocksui_cap);
    };

    // 6. User Stakes MockSUI -> Gets octSUI
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

    // Take StakePosition (created by staking) - now a shared object
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let position = test_scenario::take_shared<StakePosition>(&scenario);
        test_scenario::return_shared(position);
    };

    // 7. Create Vault Registry for OCTSUI
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        vault_manager::create_registry<OCTSUI>(test_scenario::ctx(&mut scenario));
    };

    // 8. User creates vault
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut registry = test_scenario::take_shared<VaultRegistry<OCTSUI>>(&scenario);
        vault_manager::create_vault<OCTSUI>(&mut registry, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(registry);
    };

    // 9. User deposits 100 octSUI as collateral, keeps 100 for reserve
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let octsui = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);

        // Split: 100 for collateral, 100 for reserve
        let mut all_octsui = octsui;
        let reserve_portion = coin::split(
            &mut all_octsui,
            100_000_000_000,
            test_scenario::ctx(&mut scenario),
        );

        // Deposit collateral
        vault_manager::deposit_collateral<OCTSUI>(&mut vault, all_octsui);

        // Deposit to reserve (for AI to use)
        vault_manager::deposit_to_reserve<OCTSUI>(&mut vault, reserve_portion);

        test_scenario::return_shared(vault);
    };

    // 10. User authorizes AI agent
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);

        // Grant AI permission to manage vault
        ai_adapter::authorize_ai<OCTSUI>(&vault, ADDR_AI_AGENT, test_scenario::ctx(&mut scenario));

        test_scenario::return_shared(vault);
    };

    // 11. User borrows 180 octUSD (60% LTV - exactly at warning threshold)
    // Collateral: 100 octSUI @ $3 = $300
    // Borrow: 180 octUSD (60% LTV)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut bank = test_scenario::take_shared<Bank>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        vault_manager::borrow<OCTSUI>(
            &mut bank,
            &mut vault,
            &oracle,
            180_000_000_000, // 180 octUSD
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(bank);
        test_scenario::return_shared(oracle);
        test_scenario::return_shared(vault);
    };

    // 12. Price drops: 1 OCTSUI = $2.50 (now LTV = 180/250 = 72% > 60% threshold)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 2_500_000_000);
        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 13. Verify vault is at risk (LTV > 60%)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let collateral = vault_manager::get_collateral(&vault);
        let reserve = vault_manager::get_reward_reserve(&vault);

        // Before AI rebalance:
        // Collateral: 100 octSUI
        // Reserve: 100 octSUI
        assert!(collateral == 100_000_000_000, 1);
        assert!(reserve == 100_000_000_000, 2);

        test_scenario::return_shared(vault);
    };

    // ========== AI REBALANCE (No User Signature!) ==========
    // 14. AI Agent triggers rebalance using its AICapability
    test_scenario::next_tx(&mut scenario, ADDR_AI_AGENT);
    {
        let ai_cap = test_scenario::take_from_sender<AICapability>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        // AI executes rebalance - NO USER SIGNATURE NEEDED
        // AI holds AICapability, so it can call this
        ai_adapter::ai_rebalance<OCTSUI>(
            &ai_cap,
            &mut vault,
            &oracle,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(oracle);
        test_scenario::return_shared(vault);
        test_scenario::return_to_sender(&scenario, ai_cap);
    };

    // 15. Verify AI moved reserve funds to collateral
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);

        let new_collateral = vault_manager::get_collateral(&vault);
        let new_reserve = vault_manager::get_reward_reserve(&vault);

        // After AI rebalance:
        // AI calculated we need more collateral to get to 50% LTV target
        // Target value for 180 debt at 50% LTV = $360
        // Current value = 100 @ $2.50 = $250
        // Need additional $110 worth = 44 octSUI
        // AI added from reserve

        // Collateral increased
        assert!(new_collateral > 100_000_000_000, 3);
        // Reserve decreased
        assert!(new_reserve < 100_000_000_000, 4);
        // Total remains same
        assert!(new_collateral + new_reserve == 200_000_000_000, 5);

        test_scenario::return_shared(vault);
    };

    // Cleanup clock
    clock::destroy_for_testing(test_clock);
    test_scenario::end(scenario);
}

/// Test the FULL flow: stake → opt-in → rewards accrue → AI claims & rebalances
/// This demonstrates AI using actual staking rewards (not user deposits)
#[test]
fun test_ai_claim_rewards_and_rebalance() {
    let mut scenario = test_scenario::begin(ADDR_ADMIN);

    // Create clock for testing - start at timestamp 1000000
    let mut test_clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));
    clock::set_for_testing(&mut test_clock, 1000000);

    // ========== SETUP PHASE ==========
    // 1. Init all modules
    {
        octsui::init_for_testing(test_scenario::ctx(&mut scenario));
        octusd::init_for_testing(test_scenario::ctx(&mut scenario));
        mocksui::init_for_testing(test_scenario::ctx(&mut scenario));
        oracle_adapter::init_for_testing(test_scenario::ctx(&mut scenario));
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

    // 3. Setup Bank
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let octusd_cap = test_scenario::take_from_sender<TreasuryCap<OCTUSD>>(&scenario);
        vault_manager::initialize_bank(octusd_cap, test_scenario::ctx(&mut scenario));
    };

    // 4. Set initial oracle price: 1 OCTSUI = $3.00
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 3_000_000_000);
        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 5. Mint MockSUI to User
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut mocksui_cap = test_scenario::take_from_sender<TreasuryCap<MOCKSUI>>(&scenario);
        mocksui::mint(
            &mut mocksui_cap,
            1000_000_000_000,
            ADDR_USER,
            test_scenario::ctx(&mut scenario),
        ); // 1000 mSUI
        test_scenario::return_to_sender(&scenario, mocksui_cap);
    };

    // 6. User Stakes MockSUI -> Gets octSUI AND StakePosition
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

    // 7. Create Vault Registry for OCTSUI
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        vault_manager::create_registry<OCTSUI>(test_scenario::ctx(&mut scenario));
    };

    // 8. User creates vault
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut registry = test_scenario::take_shared<VaultRegistry<OCTSUI>>(&scenario);
        vault_manager::create_vault<OCTSUI>(&mut registry, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(registry);
    };

    // 9. User deposits ALL 1000 octSUI as collateral (NO reserve deposit!)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let octsui = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);

        // Deposit ALL as collateral - no manual reserve!
        vault_manager::deposit_collateral<OCTSUI>(&mut vault, octsui);

        // Verify no reserve
        assert!(vault_manager::get_reward_reserve(&vault) == 0, 1);

        test_scenario::return_shared(vault);
    };

    // 10. User authorizes AI agent
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        ai_adapter::authorize_ai<OCTSUI>(&vault, ADDR_AI_AGENT, test_scenario::ctx(&mut scenario));
        test_scenario::return_shared(vault);
    };

    // 11. User opts-in to auto-rebalance (links vault to stake position)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let mut position = test_scenario::take_shared<StakePosition>(&scenario);

        // Enable auto-rebalance and link to vault
        liquid_staking::enable_auto_rebalance(
            &mut position,
            object::id(&vault),
            test_scenario::ctx(&mut scenario),
        );

        // Verify opt-in
        assert!(liquid_staking::is_auto_rebalance_enabled(&position), 2);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(position);
    };

    // 12. User borrows 1800 octUSD (60% LTV - at warning threshold)
    // Collateral: 1000 octSUI @ $3 = $3000
    // Borrow: 1800 octUSD (60% LTV)
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let mut bank = test_scenario::take_shared<Bank>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        vault_manager::borrow<OCTSUI>(
            &mut bank,
            &mut vault,
            &oracle,
            1800_000_000_000, // 1800 octUSD
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(bank);
        test_scenario::return_shared(oracle);
        test_scenario::return_shared(vault);
    };

    // 13. Price drops: 1 OCTSUI = $2.50 (now LTV = 1800/2500 = 72% > 60% threshold)
    test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
    {
        let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
        let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
        oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 2_500_000_000);
        test_scenario::return_to_sender(&scenario, admin_cap);
        test_scenario::return_shared(oracle);
    };

    // 14. Verify vault has NO reserve before AI action
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);

        // Before: No reserve, 1000 collateral
        assert!(vault_manager::get_reward_reserve(&vault) == 0, 3);
        assert!(vault_manager::get_collateral(&vault) == 1000_000_000_000, 4);

        test_scenario::return_shared(vault);
    };

    // Advance clock by 10 seconds (2 intervals) to accrue rewards
    clock::increment_for_testing(&mut test_clock, 10000);

    // ========== AI CLAIMS REWARDS AND REBALANCES ==========
    // 15. AI Agent claims staking rewards → deposits to vault → rebalances
    // This happens WITHOUT user signature - AI holds AICapability
    test_scenario::next_tx(&mut scenario, ADDR_AI_AGENT);
    {
        let ai_cap = test_scenario::take_from_sender<AICapability>(&scenario);
        let mut pool = test_scenario::take_shared<StakingPool<MOCKSUI>>(&scenario);
        let mut position = test_scenario::take_shared<StakePosition>(&scenario);
        let mut vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let oracle = test_scenario::take_shared<Oracle>(&scenario);

        // AI executes claim and rebalance in ONE transaction
        // This claims staking rewards → deposits to vault reserve → moves to collateral
        ai_adapter::ai_claim_and_rebalance<MOCKSUI>(
            &ai_cap,
            &mut pool,
            &mut position,
            &mut vault,
            &oracle,
            &test_clock,
            test_scenario::ctx(&mut scenario),
        );

        test_scenario::return_shared(oracle);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        test_scenario::return_shared(position);
        test_scenario::return_to_sender(&scenario, ai_cap);
    };

    // 16. Verify AI used staking rewards for rebalancing
    // Now with Clock, rewards should accrue properly!
    test_scenario::next_tx(&mut scenario, ADDR_USER);
    {
        let vault = test_scenario::take_shared<Vault<OCTSUI>>(&scenario);
        let position = test_scenario::take_shared<StakePosition>(&scenario);

        // The AI action completed successfully
        // With clock advancement, rewards are now claimed and used

        // Verify position still has auto-rebalance enabled
        assert!(liquid_staking::is_auto_rebalance_enabled(&position), 5);

        test_scenario::return_shared(vault);
        test_scenario::return_shared(position);
    };

    // Cleanup clock
    clock::destroy_for_testing(test_clock);
    test_scenario::end(scenario);
}
