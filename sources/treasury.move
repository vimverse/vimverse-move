module vimverse::treasury {
    friend vimverse::staking_distributor;
    friend vimverse::bond_depository44;
    use sui::object::{Self, UID, ID};
    use sui::tx_context::{Self, TxContext};
    use sui::vec_set::{Self, VecSet};
    use sui::transfer;
    use sui::event;
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin, CoinMetadata};
    use vimverse::math;
    use vimverse::vim::{Self, VIM, TreasuryLock};

    struct AdminCap has key {
        id: UID,
    }

    struct DepoisitToken<phantom T> has key, store {
        id: UID,
        is_lp: bool,
        deposit_balance: Balance<T>,
        decimals: u8
    }

    struct Treasury has key, store {
        id: UID,
        managers: VecSet<address>,
        total_reserves: u64
    } 

    struct InitEvent has copy, drop {
        sender: address,
        treasury_id: ID,
    }

    struct SetDepositTokenEvent has copy, drop {
        sender: address,
        id: ID
    }

    struct RewardsMintedEvent has copy, drop {
        amount: u64
    }

    struct DepositEvent has copy, drop {
        sender: address,
        deposit_token_id: ID,
        amount: u64,
        value: u64
    }
    
    struct WithdrawEvent has copy, drop {
        sender: address,
        deposit_token_id: ID,
        amount: u64,
        value: u64
    }

    struct ReservesUpdatedEvent has copy, drop {
        total_reserves: u64
    }
    
    struct ReservesManagedEvent has copy, drop {
        sender: address,
        deposit_token_id: ID,
        amount: u64,
        value: u64
    }

    const ENotExist: u64 = 0;
    const EAlreadyExist: u64 = 1;
    const EInsufficient: u64 = 2;
    const EZeroAmount: u64 = 3;
    const ENotAccepted: u64 = 4;
    const ENotEnough: u64 = 5;

    fun init(ctx: &mut TxContext) {
        transfer::transfer(
            AdminCap{
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );

        let t = Treasury {
            id: object::new(ctx),
            managers: vec_set::empty(),
            total_reserves: 0
        };

        vec_set::insert(&mut t.managers, tx_context::sender(ctx));

        let id = object::id(&t);
        transfer::share_object(t);

        event::emit(InitEvent{
            sender: tx_context::sender(ctx),
            treasury_id: id
        });
    }

    public entry fun set_deposit_token<T>(_: &AdminCap, is_lp: bool, coin_metadata: &CoinMetadata<T>, ctx: &mut TxContext) {
        let d = DepoisitToken<T> {
            id: object::new(ctx),
            is_lp,
            deposit_balance: balance::zero<T>(),
            decimals: coin::get_decimals(coin_metadata)
        };

        let id = object::id(&d);
        transfer::share_object(d);

        event::emit(SetDepositTokenEvent{
            sender: tx_context::sender(ctx),
            id
        });
    }

    public entry fun set_mamager(_: &AdminCap, treasury: &mut Treasury, manager: address, add: bool, _: &mut TxContext) {
        if (add) {
            assert!(!vec_set::contains(&treasury.managers, &manager), EAlreadyExist);
            vec_set::insert(&mut treasury.managers, manager);
        } else {
            assert!(vec_set::contains(&treasury.managers, &manager), ENotExist);
            vec_set::remove(&mut treasury.managers, &manager);
        }
    }

    public entry fun set_total_reserves(_: &AdminCap, treasury: &mut Treasury, reserves: u64, _: &mut TxContext) {
        treasury.total_reserves = reserves;
    }

    public(friend) fun deposit<T>(
        treasury: &mut Treasury, 
        deposit_token: &mut DepoisitToken<T>, 
        coin: Coin<T>, 
        amount: u64, 
        profit: u64,
        lock: &mut TreasuryLock<VIM>,
        ctx: &mut TxContext): Balance<VIM> {
        assert!(coin::value(&coin) >= amount, ENotEnough);

        let coin_balance = coin::into_balance(coin);
        let deposit_balance = balance::split(&mut coin_balance, amount);
        balance::join(&mut deposit_token.deposit_balance, deposit_balance);
        return_back_or_delete(coin_balance, ctx);

        let value = value_of(deposit_token, amount);
        let send = math::sub(value, profit);

        treasury.total_reserves = treasury.total_reserves + value;
        event::emit(ReservesUpdatedEvent{
            total_reserves: treasury.total_reserves
        });

        event::emit(DepositEvent{
            sender: tx_context::sender(ctx),
            deposit_token_id: object::id(deposit_token),
            amount,
            value
        });

        vim::mint_balance(lock, send)
    }

    public entry fun withdraw<T>(
        treasury: &mut Treasury, 
        deposit_token: &mut DepoisitToken<T>,
        amount: u64,
        coin: Coin<VIM>, 
        lock: &mut TreasuryLock<VIM>,
        ctx: &mut TxContext) {
        
        let sender = tx_context::sender(ctx);
        assert!(vec_set::contains(&treasury.managers, &sender), ENotAccepted);
        assert!(balance::value(&deposit_token.deposit_balance) >= amount, ENotEnough);

        transfer::public_transfer(coin::from_balance(balance::split(&mut deposit_token.deposit_balance, amount), ctx), sender);

        let value = value_of(deposit_token, amount);
        vim::burn(lock, coin, value, ctx);

        treasury.total_reserves = math::sub(treasury.total_reserves, value);
        event::emit(ReservesUpdatedEvent{
            total_reserves: treasury.total_reserves
        });

        event::emit(WithdrawEvent{
            sender,
            deposit_token_id: object::id(deposit_token),
            amount,
            value
        });
    }

    public entry fun manage<T>(
        treasury: &mut Treasury, 
        deposit_token: &mut DepoisitToken<T>,
        amount: u64,
        lock: &mut TreasuryLock<VIM>,
        ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);
        assert!(vec_set::contains(&treasury.managers, &sender), ENotAccepted);
        assert!(balance::value(&deposit_token.deposit_balance) >= amount, ENotEnough);

        let value = value_of(deposit_token, amount);
        assert!(value <= excess_reserves(treasury, lock), EInsufficient);
        transfer::public_transfer(coin::from_balance(balance::split(&mut deposit_token.deposit_balance, amount), ctx), sender);

        treasury.total_reserves = math::sub(treasury.total_reserves, value);
        event::emit(ReservesUpdatedEvent{
            total_reserves: treasury.total_reserves
        });

        event::emit(ReservesManagedEvent{
            sender,
            deposit_token_id: object::id(deposit_token),
            amount,
            value
        });
    }

    public(friend) fun mint_rewards(
        treasury: &mut Treasury, 
        amount: u64, 
        lock: &mut TreasuryLock<VIM>): Balance<VIM> {
        assert!(amount > 0, EZeroAmount);
        assert!(amount <= excess_reserves(treasury, lock), EInsufficient);

        event::emit(RewardsMintedEvent{
            amount
        });

        vim::mint_balance(lock, amount)
    }

    public fun excess_reserves(treasury: &Treasury, lock: &TreasuryLock<VIM>): u64 {
        math::sub(treasury.total_reserves, vim::total_supply(lock))
    }

    public fun value_of<T>(deposit_token: &DepoisitToken<T>, amount: u64): u64 {
        let decimals1 = math::pow(10, 6);
        let decimals2 = math::pow(10, deposit_token.decimals);
        math::safe_mul_div_u64(amount, decimals1, decimals2)
    }

    public fun deposit_balance<T>(deposit_token: &DepoisitToken<T>): u64 {
        balance::value(&deposit_token.deposit_balance)
    }

    public fun decimals<T>(deposit_token: &DepoisitToken<T>): u8 {
        deposit_token.decimals
    }

    public fun total_reserves(treasury: &Treasury): u64 {
        treasury.total_reserves
    }

    fun return_back_or_delete<CoinType>(
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