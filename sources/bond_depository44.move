module vimverse::bond_depository44 {
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::coin::{Self, Coin};
    use vimverse::math;
    use vimverse::vim::{Self, VIM, TreasuryLock};
    use vimverse::svim::{Self, SVIM};
    use vimverse::treasury::{Self, Treasury, DepoisitToken};
    use vimverse::staking_distributor::{StakingDistributorConfig};
    use vimverse::staking::{Self, Staking};

    struct AdminCap has key {
        id: UID,
    }

    struct Terms<phantom T> has key {
        id: UID,
        pause: bool,
        control_variable: u64, // scaling variable for price
        vesting_term: u64,  // in secs
        minimum_price: u64, // vs principle value
        max_payout: u64,  // in thousandths of a %. i.e. 500 = 0.5%
        fee: u64,  //  as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        max_debt: u64, // 6 decimal debt ratio, max % total supply created as debt
        total_debt: u64, // total value of outstanding bonds; used for pricing
        last_decay: u64, // reference block for debt decay
        dao: address, //DAO address
        adjust: Adjust<T>,
    }

    struct Adjust<phantom T> has store {
        add: bool, // addition or subtraction
        rate: u64, // increment
        target: u64, // BCV when adjustment finished
    }

    struct Bond<phantom T> has store, drop {
        payout: u64,  // sVim remaining to be paid
        vesting: u64,  // Time left to vest
        last_timestamp: u64,  // Last interaction
        price_paid: u64, // In USDT, for front end viewing
    }

    struct BondDepository44<phantom T> has key {
        id: UID,
        user_bond_info: Table<address, Bond<T>>,
        svim_balance: Balance<SVIM>,
    }

    struct InitBondEvent<phantom T> has copy, drop {
        sender: address,
        bond_depository44_id: ID,
        terms_id: ID,
    }

    struct ControlVariableAdjustEvent<phantom T> has copy, drop {
        initial_bsv: u64,
        new_bsv: u64,
        adjust: u64,
        add: bool
    }

    struct BondCreatedEvent<phantom T> has copy, drop {
        deposit: u64,
        payout: u64,
        expires: u64,
        price_in_usd: u64,
        depositor_address: address,
        sender: address
    }

    struct BondRedeemedEvent<phantom T> has copy, drop {
        recipient: address,
        payout: u64,
        remaining: u64,
        sender: address
    }

    struct SetTermsEvent<phantom T> has copy, drop {
        type: u8, 
        input: u64
    }

    struct SetAdjustEvent<phantom T> has copy, drop {
        add: bool,
        rate: u64,
        target: u64
    }

    struct SetDaoEvent<phantom T> has copy, drop {
        dao: address
    }
    
    struct SetPauseEvent<phantom T> has copy, drop {
        pause: bool
    }

    const EVestingTermTooShort: u64 = 0;
    const EPayoutTooLarge: u64 = 1;
    const EFeeExceedPayout: u64 = 2;
    const EAdjustTooLarge: u64 = 3;
    const EMaxDebtReached: u64 = 4;
    const EMoreThanMaxPrice: u64 = 5;
    const EPayoutTooSmall: u64 = 6;
    const EStakingPause: u64 = 7;
    const ENoBond: u64 = 8;
    const ENotEnough: u64 = 9;

    const VestingUnit: u64 = 100_000_000;

    fun init(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        transfer::transfer(
            AdminCap{
                id: object::new(ctx)
            },
            sender
        );
    }

    public entry fun init_bond<T>(
        _: &AdminCap,
        control_variable: u64,
        vesting_term: u64,
        minimum_price: u64,
        max_payout: u64,
        fee: u64,
        max_debt: u64,
        init_debt: u64,
        dao: address,
        clock: &Clock,
        ctx: &mut TxContext) {

        let t = Terms<T>{
            id: object::new(ctx),
            pause: false,
            control_variable,
            vesting_term,
            minimum_price,
            max_payout,
            fee,
            max_debt,
            total_debt: init_debt,
            last_decay: clock::timestamp_ms(clock) / 1000,
            dao: dao,
            adjust: Adjust{
                add: false,
                rate: 0,
                target: 0
            }
        };

        let terms_id = object::id(&t);
        transfer::share_object(t);

        let b = BondDepository44<T>{
            id: object::new(ctx),
            user_bond_info: table::new(ctx),
            svim_balance: balance::zero<SVIM>(),
        };

        let bond_depository44_id = object::id(&b);
        transfer::share_object(b);

        event::emit(InitBondEvent<T>{
            sender: tx_context::sender(ctx),
            bond_depository44_id,
            terms_id
        });
    }

    public entry fun set_bond_terms<T>(
        _: &AdminCap,
        terms: &mut Terms<T>,
        type: u8, 
        input: u64, 
        _: &mut TxContext) {
        if (type == 0) {
            assert!(input >= 3600 * 12, EVestingTermTooShort);
            terms.vesting_term = input;
        } else if (type == 1) {
            assert!(input <= 1000, EPayoutTooLarge);
            terms.max_payout = input;
        } else if (type == 2) {
            assert!(input <= 10000, EFeeExceedPayout);
            terms.fee = input;
        } else if (type == 3) {
            terms.max_debt = input;
        } else if (type == 4) {
            terms.minimum_price = input;
        };

        event::emit(SetTermsEvent<T>{
            type,
            input
        });
    }

    public entry fun set_adjust<T>(
        _: &AdminCap,
        terms: &mut Terms<T>,
        add: bool,
        rate: u64,
        target: u64,
        _: &mut TxContext) {
        assert!(rate <= terms.control_variable * 100 / 1000, EAdjustTooLarge);

        terms.adjust.add = add;
        terms.adjust.rate = rate;
        terms.adjust.target = target;

        event::emit(SetAdjustEvent<T>{
            add,
            rate,
            target
        });
    }

    public entry fun set_dao<T>(
        _: &AdminCap,
        terms: &mut Terms<T>,
        dao: address,
        _: &mut TxContext) {
        terms.dao = dao;

        event::emit(SetDaoEvent<T>{
            dao
        });
    }

    public entry fun set_pause<T>(
        _: &AdminCap,
        terms: &mut Terms<T>,
        pause: bool,
        _: &mut TxContext
    ) {
        terms.pause = pause;
        event::emit(SetPauseEvent<T>{
            pause
        });
    }

    public entry fun deposit<T>(
        coin: Coin<T>,
        amount: u64,
        max_price: u64,
        depositor_address: address,
        terms: &mut Terms<T>,
        bond_depositor: &mut BondDepository44<T>,
        treasury: &mut Treasury, 
        deposit_token: &mut DepoisitToken<T>,
        staking: &mut Staking,
        config: &mut StakingDistributorConfig,
        lock: &mut TreasuryLock<VIM>,
        scap: &mut svim::TreasuryCap<SVIM>,
        clock: &Clock,
        ctx: &mut TxContext): u64 {
        assert!(terms.pause == false, EStakingPause);
        decay_debt(terms, clock);
        assert!(terms.total_debt <= terms.max_debt, EMaxDebtReached);

        let price_in_usd = bond_price_in_usd(terms, deposit_token, lock, clock);
        let native_price = bond_price_(terms, lock, clock);
        assert!(max_price >= native_price, EMoreThanMaxPrice);

        let value = treasury::value_of(deposit_token, amount);
        let payout = payout_for(value, terms, lock, clock);
        assert!(payout >= 10000, EPayoutTooSmall);
        assert!(payout <= max_payout(lock, terms), EPayoutTooLarge);

        let fee = math::safe_mul_div_u64(payout, terms.fee, 10000);
        let profit = math::sub(value, payout + fee);
        let balance = treasury::deposit(treasury, deposit_token, coin, amount, profit, lock, ctx);
        if (fee > 0) {
            transfer::public_transfer(coin::from_balance(balance::split(&mut balance, fee), ctx), terms.dao);
        };
        terms.total_debt = terms.total_debt + value;

        let payout_gons = svim::gons_from_value(scap, payout);
        if (table::contains(&bond_depositor.user_bond_info, depositor_address)) {
            let bond = table::borrow_mut(&mut bond_depositor.user_bond_info, depositor_address);
            bond.payout = bond.payout + payout_gons;
            bond.vesting = terms.vesting_term;
            bond.last_timestamp = clock::timestamp_ms(clock) / 1000;
            bond.price_paid = price_in_usd;
        } else {
            let bond = Bond {
                payout: payout_gons,
                vesting: terms.vesting_term,
                last_timestamp: clock::timestamp_ms(clock) / 1000,
                price_paid: price_in_usd
            };
            table::add(&mut bond_depositor.user_bond_info, depositor_address, bond);
        };

        balance::join(&mut bond_depositor.svim_balance, staking::stake_balance(staking, balance, lock, scap, config, treasury, clock));

        adjust(terms);

        event::emit(BondCreatedEvent<T>{
            deposit: amount,
            payout,
            expires: clock::timestamp_ms(clock) / 1000 + terms.vesting_term,
            price_in_usd,
            depositor_address,
            sender: tx_context::sender(ctx)
        });
        payout
    }

    public entry fun redeem<T> (
        recipient: address,
        bond_depositor: &mut BondDepository44<T>,
        scap: &mut svim::TreasuryCap<SVIM>,
        clock: &Clock,
        ctx: &mut TxContext) {
        assert!(table::contains(&bond_depositor.user_bond_info, recipient), ENoBond);

        let bond = table::borrow_mut(&mut bond_depositor.user_bond_info, recipient);
        let percent_vested = percent_vested_for(bond, clock);
        if (percent_vested >= VestingUnit) {
            transfer_svim(&mut bond_depositor.svim_balance, recipient, bond.payout, ctx);
            event::emit(BondRedeemedEvent<T>{
                recipient,
                payout: svim::value_from_gons(scap, bond.payout),
                remaining: 0,
                sender: tx_context::sender(ctx)
            });
            table::remove(&mut bond_depositor.user_bond_info, recipient);
        } else {
            let cur_timestamp = clock::timestamp_ms(clock) / 1000;
            let payout = math::safe_mul_div_u64(bond.payout, percent_vested, VestingUnit);
            bond.payout = bond.payout - payout;
            bond.vesting = bond.vesting - (cur_timestamp - bond.last_timestamp);
            bond.last_timestamp = cur_timestamp;
            transfer_svim(&mut bond_depositor.svim_balance, recipient, payout, ctx);
            event::emit(BondRedeemedEvent<T>{
                recipient,
                payout: svim::value_from_gons(scap, payout),
                remaining: svim::value_from_gons(scap, bond.payout),
                sender: tx_context::sender(ctx)
            });
        }
    }

    public fun max_payout<T>(lock: &TreasuryLock<VIM>, terms: &Terms<T>): u64 {
        math::safe_mul_div_u64(vim::total_supply(lock), terms.max_payout, 100000)
    }

    public fun payout_for<T>(value: u64, terms: &Terms<T>, lock: &TreasuryLock<VIM>, clock: &Clock): u64 {
        math::fraction(value, bond_price(terms, lock, clock)) / 10000
    }

    public fun bond_price_in_usd<T>(terms: &Terms<T>, deposit_token: &DepoisitToken<T>, lock: &TreasuryLock<VIM>, clock: &Clock): u64 {
        let decimals = math::pow(10, treasury::decimals(deposit_token));
        math::safe_mul_div_u64(bond_price(terms, lock, clock), decimals, 100)
    }

    public fun bond_price<T>(terms: &Terms<T>, lock: &TreasuryLock<VIM>, clock: &Clock): u64 {
        let price = math::safe_mul_u64(terms.control_variable, debt_ratio(terms, lock, clock));
        price = math::add(price, 1_000_000) / 10000;
        if (price < terms.minimum_price) {
            price = terms.minimum_price;
        };
        price
    }

    public fun debt_ratio<T>(terms: &Terms<T>, lock: &TreasuryLock<VIM>, clock: &Clock): u64 {
        let supply = vim::total_supply(lock);
        if (supply == 0) {
            return 0
        };

        let cur_debt = current_debt(terms, clock);
        math::fraction(cur_debt, supply)
    }

    public fun current_debt<T>(terms: &Terms<T>, clock: &Clock): u64 {
        let decay = debt_decay(terms, clock);
        terms.total_debt - decay
    }

    public fun debt_decay<T>(terms: &Terms<T>, clock: &Clock): u64 {
        let time_since_last = math::sub(clock::timestamp_ms(clock) / 1000, terms.last_decay);
        let decay = math::safe_mul_div_u64(terms.total_debt, time_since_last, terms.vesting_term);
        if (decay > terms.total_debt) {
            decay = terms.total_debt;
        };
        decay
    }

    public fun pending_payout_for<T>(depositor_address: address, bond_depositor: &BondDepository44<T>, clock: &Clock, scap: &svim::TreasuryCap<SVIM>): u64 {
        if (!table::contains(&bond_depositor.user_bond_info, depositor_address))
        {
            return 0
        };
        
        let bond = table::borrow(&bond_depositor.user_bond_info, depositor_address);
        let percent_vested = percent_vested_for(bond, clock);
        let pending_payout = bond.payout;
        if (percent_vested < VestingUnit) {
            pending_payout = math::safe_mul_div_u64(pending_payout, percent_vested, VestingUnit);
        };

        svim::value_from_gons(scap, pending_payout)
    }

    public fun unclaim_payout_for<T>(depositor_address: address, bond_depositor: &BondDepository44<T>, scap: &svim::TreasuryCap<SVIM>): u64 {
        if (!table::contains(&bond_depositor.user_bond_info, depositor_address))
        {
            return 0
        };

        let bond = table::borrow(&bond_depositor.user_bond_info, depositor_address);
        svim::value_from_gons(scap, bond.payout)
    }

    fun transfer_svim(
        svim_balance: &mut Balance<SVIM>,
        recipient: address,
        svim_amount: u64,
        ctx: &mut TxContext) {
        
        assert!(balance::value(svim_balance) >= svim_amount, ENotEnough);
        let svim = coin::from_balance(balance::split(svim_balance, svim_amount), ctx);
        transfer::public_transfer(svim, recipient);
    }

    fun bond_price_<T>(terms: &mut Terms<T>, lock: &TreasuryLock<VIM>, clock: &Clock): u64 {
        let price = math::safe_mul_u64(terms.control_variable, debt_ratio(terms, lock, clock));
        price = math::add(price, 1_000_000) / 10000;
        if (price < terms.minimum_price) {
            price = terms.minimum_price;
        } else if (terms.minimum_price > 0) {
            terms.minimum_price = 0;
        };
        price
    }

    fun decay_debt<T>(terms: &mut Terms<T>, clock: &Clock) {
        let decay = debt_decay(terms, clock);
        terms.total_debt = terms.total_debt - decay;
        terms.last_decay = clock::timestamp_ms(clock) / 1000;
    }

    fun adjust<T>(terms: &mut Terms<T>) {
        if (terms.adjust.rate > 0) {
            let initial = terms.control_variable;
            if (terms.adjust.add) {
                terms.control_variable = terms.control_variable + terms.adjust.rate;
                if (terms.control_variable >= terms.adjust.target) {
                    terms.adjust.rate = 0;
                }
            } else {
                if (terms.control_variable < terms.adjust.rate) {
                    terms.control_variable = 0;
                } else {
                    terms.control_variable = terms.control_variable - terms.adjust.rate;
                };
                if (terms.control_variable <= terms.adjust.target) {
                    terms.adjust.rate = 0;
                }
            };

            event::emit(ControlVariableAdjustEvent<T> {
                initial_bsv: initial,
                new_bsv: terms.control_variable,
                adjust: terms.adjust.rate,
                add: terms.adjust.add
            });
        }
    }

    fun percent_vested_for<T>(bond: &Bond<T>, clock: &Clock): u64 {
        let time_since_last = math::sub(clock::timestamp_ms(clock) / 1000, bond.last_timestamp);
        let vesting = bond.vesting;
        if (vesting > 0) {
            return math::safe_mul_div_u64(time_since_last, VestingUnit, vesting)
        } else {
            return 0
        }
    }
}