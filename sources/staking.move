module vimverse::staking {
    friend vimverse::bond_depository44;
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use vimverse::svim::{Self, SVIM};
    use vimverse::vim::{VIM, TreasuryLock};
    use vimverse::staking_distributor::{Self, StakingDistributorConfig};
    use vimverse::treasury::{Treasury};

    struct AdminCap has key {
        id: UID,
    }

    struct Staking has key {
        id: UID,
        config: StakingConfig,
        vim_balance: Balance<VIM>,
        svim_balance: Balance<SVIM>,
    }

    struct StakingConfig has store {
        pause: bool,
        epoch_length: u64,
        epoch_number: u64,
        epoch_timestamp: u64,
        epoch_distribute: u64,
    }

    struct InitEvent has copy, drop {
        sender: address,
        staking_id: ID,
    }

    const ENotEnough: u64 = 0;
    const EInitialize: u64 = 1;
    const EStakingPause: u64 = 2;
    const EZeroAmount: u64 = 3;

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            AdminCap{
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );

        let s = Staking{
            id: object::new(ctx),
            config: StakingConfig{
                pause: false,
                epoch_length: 0,
                epoch_number: 0,
                epoch_timestamp: 0,
                epoch_distribute: 0,
            },
            vim_balance: balance::zero<VIM>(),
            svim_balance: balance::zero<SVIM>()
        };

        let id = object::id(&s);
        transfer::share_object(s);

        event::emit(InitEvent{
            sender: tx_context::sender(ctx),
            staking_id: id
        });
    }

    public entry fun initialize(
        _: &AdminCap, 
        staking: &mut Staking, 
        epoch_length: u64,  
        epoch_number: u64,
        first_epoch_timestamp: u64, 
        cap: &mut svim::TreasuryCap<SVIM>,
        clock: &Clock,
        _: &mut TxContext) {
        
        assert!(staking.config.epoch_length == 0, EInitialize);
        staking.config.epoch_length = epoch_length;
        staking.config.epoch_number = epoch_number;
        if (first_epoch_timestamp == 0) {
            staking.config.epoch_timestamp = clock::timestamp_ms(clock) / 1000 + epoch_length;
        } else {
            staking.config.epoch_timestamp = first_epoch_timestamp;
        };

        balance::join(&mut staking.svim_balance, svim::initialize(cap));
    }

    public entry fun set_pause(
        _: &AdminCap,
        staking: &mut Staking,
        pause: bool,
        _: &mut TxContext
    ) {
        staking.config.pause = pause;
    }


    public entry fun stake(
        staking: &mut Staking, 
        vim: Coin<VIM>,
        amount: u64,
        recipient: address,
        lock: &mut TreasuryLock<VIM>,
        scap: &mut svim::TreasuryCap<SVIM>,
        config: &mut StakingDistributorConfig,
        treasury: &mut Treasury,
        clock: &Clock,
        ctx: &mut TxContext) {

        assert!(staking.config.pause == false, EStakingPause);
        assert!(amount > 0, EZeroAmount);
        assert!(coin::value(&vim) >= amount, ENotEnough);

        rebase(staking, lock, scap, config, treasury, clock);

        let svim_amount = svim::gons_from_value(scap, amount);
        assert!(balance::value(&staking.svim_balance) >= svim_amount, ENotEnough);

        let coin_balance = coin::into_balance(vim);
        let staking_balance = balance::split(&mut coin_balance, amount);
        balance::join(&mut staking.vim_balance, staking_balance);
        reture_back_or_delete(coin_balance, ctx);

        let svim = coin::from_balance(balance::split(&mut staking.svim_balance, svim_amount), ctx);
        transfer::public_transfer(svim, recipient);
    }

    public(friend) fun stake_balance(
        staking: &mut Staking, 
        vim_balance: Balance<VIM>,
        lock: &mut TreasuryLock<VIM>,
        scap: &mut svim::TreasuryCap<SVIM>,
        config: &mut StakingDistributorConfig,
        treasury: &mut Treasury,
        clock: &Clock): Balance<SVIM> {

        assert!(staking.config.pause == false, EStakingPause);
        let amount = balance::value(&vim_balance);
        assert!(amount > 0, EZeroAmount);

        rebase(staking, lock, scap, config, treasury, clock);
        balance::join(&mut staking.vim_balance, vim_balance);

        let svim_amount = svim::gons_from_value(scap, amount);
        assert!(balance::value(&staking.svim_balance) >= svim_amount, ENotEnough);
        balance::split(&mut staking.svim_balance, svim_amount)
    }

    public entry fun unstake(
        staking: &mut Staking,
        svim: Coin<SVIM>,
        amount: u64,
        cap: &mut svim::TreasuryCap<SVIM>,
        ctx: &mut TxContext) {

        assert!(amount > 0, EZeroAmount);
        let svim_amount = svim::gons_from_value(cap, amount);
        assert!(coin::value(&svim) >= svim_amount, ENotEnough);
        assert!(balance::value(&staking.vim_balance) >= amount, ENotEnough);

        let coin_balance = coin::into_balance(svim);
        let unstake_balance = balance::split(&mut coin_balance, svim_amount);

        balance::join(&mut staking.svim_balance, unstake_balance);
        reture_back_or_delete(coin_balance, ctx);

        let vim = coin::from_balance(balance::split(&mut staking.vim_balance, amount), ctx);
        transfer::public_transfer(vim, tx_context::sender(ctx));
    }

    public entry fun rebase(
        staking: &mut Staking,
        lock: &mut TreasuryLock<VIM>,
        scap: &mut svim::TreasuryCap<SVIM>, 
        config: &mut StakingDistributorConfig,
        treasury: &mut Treasury,
        clock: &Clock) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        if (staking.config.epoch_timestamp <= timestamp) {
            svim::rebase(staking.config.epoch_distribute, staking.config.epoch_number, &staking.svim_balance, scap, clock);

            staking.config.epoch_timestamp = staking.config.epoch_timestamp + staking.config.epoch_length;
            staking.config.epoch_number = staking.config.epoch_number + 1;

            balance::join(&mut staking.vim_balance, staking_distributor::distrbute(config, lock, treasury));

            let bal = balance::value(&staking.vim_balance);
            let staked = svim::circulating_supply(scap, &staking.svim_balance);
            if (bal <= staked) {
                staking.config.epoch_distribute = 0;
            } else {
                staking.config.epoch_distribute = bal - staked;
            }
        }
    }

    public fun next_reward(staking: &Staking): u64 {
        staking.config.epoch_distribute
    }

    public fun next_reward_time(staking: &Staking): u64 {
        staking.config.epoch_timestamp
    }

    public fun vim_staking_balance(staking: &Staking, scap: &svim::TreasuryCap<SVIM>): u64 {
        svim::circulating_supply(scap, &staking.svim_balance)
    }

    fun reture_back_or_delete<CoinType>(
        balance: Balance<CoinType>,
        ctx: &mut TxContext
    ) {
        if(balance::value(&balance) > 0) {
            transfer::public_transfer(coin::from_balance(balance , ctx), tx_context::sender(ctx));
        } else {
            balance::destroy_zero(balance);
        }
    }
}