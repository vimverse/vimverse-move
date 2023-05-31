module vimverse::vim {
    friend vimverse::treasury;
    friend vimverse::presale;
    use std::option;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::balance::{Balance};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::object::{Self, UID};

    struct VIM has drop {}

    struct AdminCap has key {
        id: UID,
    }

    struct TreasuryLock<phantom T> has key {
        id: UID,
        treasury_cap: TreasuryCap<T>
    }

    const ENotEnough: u64 = 0;
    const ENotExist: u64 = 1;
    const EAlreadyExist: u64 = 2;
    const ENoAuth: u64 = 3;

    fun init(witness: VIM, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency<VIM>(witness, 6, b"Vim", b"Vimverse Coin", b"", option::none(), ctx);
        transfer::public_freeze_object(metadata);

        let sender = tx_context::sender(ctx);
        transfer::public_transfer(treasury_cap, sender);
        transfer::transfer(
            AdminCap{
                id: object::new(ctx)
            },
            sender
        );
    }

    public entry fun new_lock<T>(cap: TreasuryCap<T>, ctx: &mut TxContext) {
        let lock = TreasuryLock {
            id: object::new(ctx),
            treasury_cap: cap
        };
        transfer::share_object(lock);
    }

    public(friend) fun burn<T>(lock: &mut TreasuryLock<T>, coin: Coin<T>, amount: u64, ctx: &mut TxContext) {
        assert!(coin::value(&coin) >= amount, ENotEnough);
        let burn_coin = coin::split(&mut coin, amount, ctx);
        coin::burn(&mut lock.treasury_cap, burn_coin);
        reture_back_or_delete(coin, ctx);
    }

    public(friend) fun mint_balance<T>(lock: &mut TreasuryLock<T>, amount: u64): Balance<T> {
        coin::mint_balance(&mut lock.treasury_cap, amount)
    }

    public fun total_supply<T>(lock: &TreasuryLock<T>): u64 {
        coin::total_supply(&lock.treasury_cap)
    }

    fun reture_back_or_delete<T>(
        coin: Coin<T>,
        ctx: &mut TxContext
    ) {
        if(coin::value(&coin) > 0) {
            transfer::public_transfer(coin, tx_context::sender(ctx));
        } else {
            coin::destroy_zero(coin);
        }
    }
}