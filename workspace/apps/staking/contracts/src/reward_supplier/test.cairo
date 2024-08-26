use core::option::OptionTrait;
use contracts::reward_supplier::interface::{IRewardSupplier, RewardSupplierStatus};
use starknet::get_block_timestamp;
use contracts::staking::interface::{IStaking, IStakingDispatcher, IStakingDispatcherTrait};
use openzeppelin::token::erc20::interface::{IERC20DispatcherTrait, IERC20Dispatcher};
use contracts::test_utils::{
    deploy_mock_erc20_contract, StakingInitConfig, deploy_staking_contract,
    stake_for_testing_using_dispatcher, initialize_reward_supplier_state_from_cfg,
    deploy_minting_curve_contract, fund
};
use contracts::reward_supplier::RewardSupplier::SECONDS_IN_YEAR;
use contracts::reward_supplier::RewardSupplier;
use contracts::minting_curve::MintingCurve::multiply_by_max_inflation;
use snforge_std::{start_cheat_block_timestamp_global, CheatSpan, test_address};
use core::num::traits::Zero;
use core::num::traits::Sqrt;
use contracts_commons::test_utils::cheat_caller_address_once;
use contracts::utils::{ceil_of_division, compute_threshold};
use contracts::event_test_utils::{assert_number_of_events, assert_mint_request_event,};
use snforge_std::cheatcodes::events::{Events, EventSpy, EventSpyTrait, EventsFilterTrait};

#[test]
fn test_reward_supplier_constructor() {
    let mut cfg: StakingInitConfig = Default::default();
    // Deploy the token contract.
    let token_address = deploy_mock_erc20_contract(
        initial_supply: cfg.test_info.initial_supply, owner_address: cfg.test_info.owner_address
    );
    // Deploy the staking contract, stake, and enter delegation pool.
    let staking_contract = deploy_staking_contract(:token_address, :cfg);
    cfg.test_info.staking_contract = staking_contract;
    let state = @initialize_reward_supplier_state_from_cfg(:token_address, :cfg);
    assert_eq!(state.staking_contract.read(), cfg.test_info.staking_contract);
    assert_eq!(state.token_address.read(), token_address);
    assert_eq!(state.l1_pending_requested_amount.read(), Zero::zero());
    assert_eq!(state.base_mint_amount.read(), cfg.reward_supplier.base_mint_amount);
    assert_eq!(state.base_mint_msg.read(), cfg.reward_supplier.base_mint_msg);
    assert_eq!(state.minting_curve_contract.read(), cfg.reward_supplier.minting_curve_contract);
    assert_eq!(state.l1_staking_minter.read(), cfg.reward_supplier.l1_staking_minter);
    assert_eq!(state.last_timestamp.read(), get_block_timestamp());
    assert_eq!(state.unclaimed_rewards.read(), 0_u128);
}

#[test]
fn test_claim_rewards() {
    let mut cfg: StakingInitConfig = Default::default();
    // Deploy the token contract.
    let token_address = deploy_mock_erc20_contract(
        initial_supply: cfg.test_info.initial_supply, owner_address: cfg.test_info.owner_address
    );
    // Deploy the staking contract and stake.
    let staking_contract = deploy_staking_contract(:token_address, :cfg);
    cfg.test_info.staking_contract = staking_contract;
    let amount = (cfg.test_info.initial_supply / 2).try_into().expect('amount does not fit in');
    cfg.test_info.staker_initial_balance = amount;
    cfg.staker_info.amount_own = amount;
    stake_for_testing_using_dispatcher(:cfg, :token_address, :staking_contract);
    // Deploy the minting curve contract.
    let minting_curve_contract = deploy_minting_curve_contract(:staking_contract, :cfg);
    cfg.reward_supplier.minting_curve_contract = minting_curve_contract;
    // Use the reward supplier contract state to claim rewards.
    let mut state = initialize_reward_supplier_state_from_cfg(:token_address, :cfg);
    // Fund the the reward supplier contract.
    fund(sender: cfg.test_info.owner_address, recipient: test_address(), :amount, :token_address);
    // Update the unclaimed rewards for testing purposes.
    state.unclaimed_rewards.write(amount);
    // Claim the rewards from the reward supplier contract.
    cheat_caller_address_once(contract_address: test_address(), caller_address: staking_contract);
    state.claim_rewards(:amount);
    // Validate that the rewards were claimed.
    assert_eq!(state.unclaimed_rewards.read(), Zero::zero());
    let erc20_dispatcher = IERC20Dispatcher { contract_address: token_address };
    let staking_balance = erc20_dispatcher.balance_of(account: staking_contract);
    assert_eq!(staking_balance, amount.into() * 2);
    let reward_supplier_balance = erc20_dispatcher.balance_of(account: test_address());
    assert_eq!(reward_supplier_balance, Zero::zero());
}

#[test]
fn test_calculate_staking_rewards() {
    let mut cfg: StakingInitConfig = Default::default();
    // Deploy the token contract.
    let token_address = deploy_mock_erc20_contract(
        initial_supply: cfg.test_info.initial_supply, owner_address: cfg.test_info.owner_address
    );
    // Deploy the staking contract and stake.
    let staking_contract = deploy_staking_contract(:token_address, :cfg);
    cfg.test_info.staking_contract = staking_contract;
    let amount = (cfg.test_info.initial_supply / 2).try_into().expect('amount does not fit in');
    cfg.test_info.staker_initial_balance = amount;
    cfg.staker_info.amount_own = amount;
    stake_for_testing_using_dispatcher(:cfg, :token_address, :staking_contract);
    // Deploy the minting curve contract.
    let minting_curve_contract = deploy_minting_curve_contract(:staking_contract, :cfg);
    cfg.reward_supplier.minting_curve_contract = minting_curve_contract;
    // Use the reward supplier contract state to claim rewards.
    let mut state = initialize_reward_supplier_state_from_cfg(:token_address, :cfg);
    // Fund the the reward supplier contract.
    let balance = cfg.reward_supplier.base_mint_amount;
    fund(
        sender: cfg.test_info.owner_address,
        recipient: test_address(),
        amount: balance,
        :token_address
    );
    start_cheat_block_timestamp_global(
        block_timestamp: get_block_timestamp()
            + SECONDS_IN_YEAR.try_into().expect('does not fit in')
    );
    cheat_caller_address_once(contract_address: test_address(), caller_address: staking_contract);
    let mut spy = snforge_std::spy_events();
    let rewards = state.calculate_staking_rewards();
    // Validate the rewards, unclaimed rewards and l1_pending_requested_amount.
    let unadjusted_expected_rewards: u128 = (cfg.test_info.initial_supply * amount.into()).sqrt();
    let expected_rewards = multiply_by_max_inflation(unadjusted_expected_rewards);
    assert_eq!(rewards, expected_rewards);
    let expected_unclaimed_rewards = rewards;
    assert_eq!(state.unclaimed_rewards.read(), expected_unclaimed_rewards);
    let base_mint_amount = cfg.reward_supplier.base_mint_amount;
    let diff = expected_unclaimed_rewards + compute_threshold(base_mint_amount) - balance;
    let num_msgs = ceil_of_division(dividend: diff, divisor: base_mint_amount);
    let expected_l1_pending_requested_amount = num_msgs * base_mint_amount;
    assert_eq!(state.l1_pending_requested_amount.read(), expected_l1_pending_requested_amount);
    // Validate the single MintRequest event.
    let events = spy.get_events().emitted_by(contract_address: test_address()).events;
    assert_number_of_events(
        actual: events.len(), expected: 1, message: "calculate_staking_rewards"
    );
    assert_mint_request_event(
        spied_event: events[0], total_amount: expected_l1_pending_requested_amount, :num_msgs
    );
}

#[test]
fn test_state_of() {
    let mut cfg: StakingInitConfig = Default::default();
    // Deploy the token contract.
    let token_address = deploy_mock_erc20_contract(
        initial_supply: cfg.test_info.initial_supply, owner_address: cfg.test_info.owner_address
    );
    // Change the block_timestamp so the state_of() won't return zero for all fields.
    let block_timestamp = get_block_timestamp() + 1;
    start_cheat_block_timestamp_global(:block_timestamp);
    let state = initialize_reward_supplier_state_from_cfg(:token_address, :cfg);
    let expected_status = RewardSupplierStatus {
        last_timestamp: block_timestamp,
        unclaimed_rewards: Zero::zero(),
        l1_pending_requested_amount: Zero::zero(),
    };
    assert_eq!(state.state_of(), expected_status);
}
