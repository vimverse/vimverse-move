module vimverse::svim {
    friend vimverse::staking;
    use std::string;
    use std::ascii;
    use std::option::{Self, Option};
    use sui::balance::{Self, Balance, Supply};
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::event;
    use sui::url::{Url};
    use sui::clock::{Self, Clock};
    use vimverse::math;

    struct SVIM has drop {}

    struct AdminCap has key {
        id: UID,
    }

    struct TreasuryCap<phantom T> has key, store {
        id: UID,
        total_supply: Supply<T>,
        gons_per_fragment: u64,
        index: u64
    }

    struct Coin<phantom T> has key, store {
        id: UID,
        balance: Balance<T>
    }

    struct CoinMetadata<phantom T> has key, store {
        id: UID,
        decimals: u8,
        name: string::String,
        symbol: ascii::String,
        description: string::String,
        icon_url: Option<Url>
    }

    struct CurrencyCreated<phantom T> has copy, drop {
        decimals: u8
    }

    struct InitEvent has copy, drop {
        sender: address,
        treasury_cap_id: ID
    }

    struct RebaseEvent has copy, drop {
        epoch_number: u64,
        rebase_amount: u64,
        index: u64,
        total_supply: u64,
        timestamp: u64
    }

    const EBadWitness: u64 = 0;
    const EInitialize: u64 = 1;

    const INITIAL_FRAGMENTS_SUPPLY: u64 = 1_000_000 * 1_000_000; 
    const MAX_UINT64: u64 = 18446744073709551615; //2^64-1
    const TOTAL_GONS: u64 = 18446744073709551615 - (18446744073709551615 % (1_000_000 * 1_000_000)); //MAX_UINT64 - MAX_UINT64 % INITIAL_FRAGMENTS_SUPPLY
    const MAX_SUPPLY: u64 = 4294967295 * 1_000_000; //2^32-1 * 10^6


    fun init(witness: SVIM, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = create_currency<SVIM>(witness, 6, b"sVim", b"Staked Vim", b"", option::none(), ctx);
        transfer::public_freeze_object(metadata);
        let id = object::id(&treasury_cap);
        transfer::public_share_object(treasury_cap);

        transfer::transfer(
            AdminCap{
                id: object::new(ctx)
            },
            tx_context::sender(ctx)
        );

        event::emit(InitEvent{
            sender: tx_context::sender(ctx),
            treasury_cap_id: id
        });
    }

    public(friend) fun initialize<T>(cap: &mut TreasuryCap<T>): Balance<T> {
        assert!(cap.gons_per_fragment == 0, EInitialize);
        let bal = balance::increase_supply(&mut cap.total_supply, TOTAL_GONS);
        cap.gons_per_fragment = TOTAL_GONS / INITIAL_FRAGMENTS_SUPPLY;
        cap.index = cap.gons_per_fragment * 1_000_000;
        return bal
    }

    public(friend) fun rebase<T>(profit: u64, epoch_number: u64, staking_balance: &Balance<T>, cap: &mut TreasuryCap<T>, clock: &Clock) {
        let timestamp = clock::timestamp_ms(clock) / 1000;
        let total_supply = total_supply(cap);
        let circulating_supply = circulating_supply(cap, staking_balance);
        let rebase_amount = 0;
        if (profit == 0) {
            event::emit(RebaseEvent {
                epoch_number,
                rebase_amount,
                index: index(cap),
                total_supply,
                timestamp
            });
            return
        } else if (circulating_supply > 0) {
            rebase_amount = math::safe_mul_div_u64(profit, total_supply, circulating_supply);
        } else {
            rebase_amount = profit;
        };

        if (total_supply + rebase_amount> MAX_SUPPLY) {
            rebase_amount = MAX_SUPPLY - total_supply;
            total_supply = MAX_SUPPLY;
        } else {
            total_supply = total_supply + rebase_amount;
        };

        cap.gons_per_fragment = TOTAL_GONS / total_supply;

        event::emit(RebaseEvent {
            epoch_number,
            rebase_amount,
            index: index(cap),
            total_supply,
            timestamp
        });
    }

    public fun total_supply<T>(cap: &TreasuryCap<T>): u64 {
        balance::supply_value(&cap.total_supply) / cap.gons_per_fragment
    }

    public fun circulating_supply<T>(cap: &TreasuryCap<T>, staking_balance: &Balance<T>): u64 {
        (balance::supply_value(&cap.total_supply) - balance::value(staking_balance)) / cap.gons_per_fragment
    }

    public fun value<T>(self: &Coin<T>): u64 {
        balance::value(&self.balance)
    }

    public fun value_from_gons<T>(cap: &TreasuryCap<T>, gons: u64): u64 {
        gons / cap.gons_per_fragment
    }

    public fun gons_from_value<T>(cap: &TreasuryCap<T>, value: u64): u64 {
        cap.gons_per_fragment * value
    }

    public fun index<T>(cap: &TreasuryCap<T>): u64 {
        cap.index / cap.gons_per_fragment
    }

    public fun balance<T>(coin: &Coin<T>): &Balance<T> {
        &coin.balance
    }

    public fun balance_mut<T>(coin: &mut Coin<T>): &mut Balance<T> {
        &mut coin.balance
    }

    public fun from_balance<T>(balance: Balance<T>, ctx: &mut TxContext): Coin<T> {
        Coin { id: object::new(ctx), balance }
    }

    public fun into_balance<T>(coin: Coin<T>): Balance<T> {
        let Coin { id, balance } = coin;
        object::delete(id);
        balance
    }

    public fun take<T>(
        balance: &mut Balance<T>, value: u64, ctx: &mut TxContext,
    ): Coin<T> {
        Coin {
            id: object::new(ctx),
            balance: balance::split(balance, value)
        }
    }

    public entry fun join<T>(self: &mut Coin<T>, c: Coin<T>) {
        let Coin { id, balance } = c;
        object::delete(id);
        balance::join(&mut self.balance, balance);
    }

    public fun split<T>(
        self: &mut Coin<T>, split_amount: u64, ctx: &mut TxContext
    ): Coin<T> {
        take(&mut self.balance, split_amount, ctx)
    }
    
    public fun zero<T>(ctx: &mut TxContext): Coin<T> {
        Coin { id: object::new(ctx), balance: balance::zero() }
    }

    public fun destroy_zero<T>(c: Coin<T>) {
        let Coin { id, balance } = c;
        object::delete(id);
        balance::destroy_zero(balance)
    }

    public fun create_currency<T: drop>(
        witness: T,
        decimals: u8,
        symbol: vector<u8>,
        name: vector<u8>,
        description: vector<u8>,
        icon_url: Option<Url>,
        ctx: &mut TxContext
    ): (TreasuryCap<T>, CoinMetadata<T>) {
        // Make sure there's only one instance of the type T
        assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

        // Emit Currency metadata as an event.
        event::emit(CurrencyCreated<T> {
            decimals
        });

        (
            TreasuryCap {
                id: object::new(ctx),
                total_supply: balance::create_supply(witness),
                gons_per_fragment: 0,
                index: 0
            },

            CoinMetadata {
                id: object::new(ctx),
                decimals,
                name: string::utf8(name),
                symbol: ascii::string(symbol),
                description: string::utf8(description),
                icon_url
            }
        )
    }

    public fun get_decimals<T>(
        metadata: &CoinMetadata<T>
    ): u8 {
        metadata.decimals
    }

    public fun get_name<T>(
        metadata: &CoinMetadata<T>
    ): string::String {
        metadata.name
    }

    public fun get_symbol<T>(
        metadata: &CoinMetadata<T>
    ): ascii::String {
        metadata.symbol
    }

    public fun get_description<T>(
        metadata: &CoinMetadata<T>
    ): string::String {
        metadata.description
    }

    public fun get_icon_url<T>(
        metadata: &CoinMetadata<T>
    ): Option<Url> {
        metadata.icon_url
    }
}