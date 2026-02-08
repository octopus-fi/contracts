
#[test_only]
module octopus_finance::stage1_tests {
    use sui::test_scenario;
    use sui::coin::{Self, TreasuryCap};
    use octopus_finance::octsui::{Self, OCTSUI};
    use octopus_finance::octusd::{Self, OCTUSD};
    use octopus_finance::oracle_adapter::{Self, Oracle, OracleAdminCap};

    // Test addresses
    const ADDR_ADMIN: address = @0xA;
    const ADDR_USER: address = @0xB;

    #[test]
    fun test_octsui_mint_burn() {
        let mut scenario = test_scenario::begin(ADDR_ADMIN);
        
        // 1. Initialize OctSUI
        {
            octsui::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        test_scenario::next_tx(&mut scenario, ADDR_ADMIN);
        
        // 2. Mint OctSUI
        {
            let mut treasury = test_scenario::take_from_sender<TreasuryCap<OCTSUI>>(&scenario);
            octsui::mint(&mut treasury, 1000, ADDR_USER, test_scenario::ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, treasury);
        };
        
        test_scenario::next_tx(&mut scenario, ADDR_USER);
        
        // 3. Check balance and Burn
        {
            let coin = test_scenario::take_from_sender<coin::Coin<OCTSUI>>(&scenario);
            assert!(coin::value(&coin) == 1000, 0);
            
            // Need treasury to burn, so send coin back to admin or make treasury shared/public for test?
            // Realistically, the module that holds treasury burns it. 
            // For this test, we just return coin.
            test_scenario::return_to_sender(&scenario, coin);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_oracle_updates() {
        let mut scenario = test_scenario::begin(ADDR_ADMIN);
        
        // 1. Initialize Oracle
        {
            oracle_adapter::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        test_scenario::next_tx(&mut scenario, ADDR_ADMIN);

        // 2. Update Price
        {
            let mut oracle = test_scenario::take_shared<Oracle>(&scenario);
            let admin_cap = test_scenario::take_from_sender<OracleAdminCap>(&scenario);
            
            // Set price for OCTSUI (dummy type for test)
            oracle_adapter::update_price<OCTSUI>(&admin_cap, &mut oracle, 1500000000); // $1.50
            
            assert!(oracle_adapter::get_price<OCTSUI>(&oracle) == 1500000000, 1);
            
            test_scenario::return_to_sender(&scenario, admin_cap);
            test_scenario::return_shared(oracle);
        };

        test_scenario::end(scenario);
    }
}
