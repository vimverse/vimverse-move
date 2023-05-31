module vimverse::staking_distributor {
    friend vimverse::staking;
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::event;
    use sui::balance::{Self, Balance};
    use vimverse::vim::{Self, VIM, TreasuryLock};
    use vimverse::math;
    use vimverse::treasury::{Self, Treasury};

    struct AdminCap has key {
        id: UID,
    }

    struct StakingDistributorConfig has key {
        id: UID,
        rate: u64,
        adjust: Adjust
    }

    struct Adjust has store {
        add: bool,
        rate: u64,
        target: u64,
    }

    struct InitEvent has copy, drop {
        sender: address,
        config_id: ID,
    }

    struct SetRateEvent has copy, drop {
        sender: address,
        rate: u64
    }

    struct SetAdjustEvent has copy, drop {
        sender: address,
        add: bool,
        rate: u64,
        target: u64
    }

    const PercentUnit: u64 = 1_000_000;

    const EInvalidParams: u64 = 0;

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            AdminCap{
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );

        let config = StakingDistributorConfig {
            id: object::new(ctx),
            rate: 0,
            adjust: Adjust {
                add: false,
                rate: 0,
                target: 0
            }
        };

        let id = object::id(&config);
        transfer::share_object(config);

        event::emit(InitEvent{
            sender: tx_context::sender(ctx),
            config_id: id
        });
    }

    public entry fun set_rate(_: &AdminCap, config: &mut StakingDistributorConfig, rate: u64, ctx: &mut TxContext) {
        assert!(rate <= 100000, EInvalidParams);
        config.rate = rate;

        event::emit(SetRateEvent{
            sender: tx_context::sender(ctx),
            rate
        });
    }

    public entry fun set_adjust(_: &AdminCap, config: &mut StakingDistributorConfig, add: bool, rate: u64, target: u64, ctx: &mut TxContext) {
        assert!(rate <= 100000, EInvalidParams);
        assert!(target <= 100000, EInvalidParams);
        if (add == false) {
            assert!(rate <= config.rate, EInvalidParams);
        };
        config.adjust.add = add;
        config.adjust.rate = rate;
        config.adjust.target = target;

        event::emit(SetAdjustEvent{
            sender: tx_context::sender(ctx),
            add,
            rate, 
            target
        });
    }

    public(friend) fun distrbute(config: &mut StakingDistributorConfig, lock: &mut TreasuryLock<VIM>, treasury: &mut Treasury): Balance<VIM> {
        if (config.rate == 0) {
            return balance::zero()
        };

        let amount = nextreward_at(config, lock);
        let bal = treasury::mint_rewards(treasury, amount, lock);
        adjust(config);
        return bal
    }

    public fun nextreward_at(config: &StakingDistributorConfig, lock: &TreasuryLock<VIM>): u64 {
        math::safe_mul_div_u64(vim::total_supply(lock), config.rate, PercentUnit)
    }

    fun adjust(config: &mut StakingDistributorConfig) {
        if (config.adjust.rate > 0) {
            if (config.adjust.add) {
                if (config.rate + config.adjust.rate >= config.adjust.target) {
                    config.rate = config.adjust.target;
                    config.adjust.rate = 0;
                } else {
                    config.rate = config.rate + config.adjust.rate;
                }
            } else {
                if (config.rate - config.adjust.rate <= config.adjust.target) {
                    config.rate = config.adjust.target;
                    config.adjust.rate = 0;
                } else {
                    config.rate = config.rate - config.adjust.rate;
                }
            }
        }
    }
}