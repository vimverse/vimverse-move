module vimverse::dashboard {
    use sui::clock::{Self, Clock};
    use vimverse::svim::{Self, SVIM, TreasuryCap};
    use vimverse::staking::{Self, Staking};
    use vimverse::treasury::{Self, DepoisitToken, Treasury};
    use vimverse::bond_depository44::{Self, BondDepository44, Terms};
    use vimverse::vim::{VIM, TreasuryLock};

    struct VimverseInfo has copy, drop {
        index: u64,
        vim_staking_balance: u64,
        next_reward: u64,
        rebase_left_time: u64,
        total_reserves: u64
    }

    struct BondInfo has copy, drop {
        mv: u64,
        rfv: u64,
        pol: u64,
        price_in_usd: u64
    }

    struct UserBondInfo has copy, drop {
        price_in_usd: u64,
        bond_price: u64,
        max_payout: u64,
        debt_ratio: u64,
        current_debt: u64,
        unclaim_payout: u64,
        claimable_payout: u64,
        payout: u64
    }

    public fun query_vimverse_info(scap: &TreasuryCap<SVIM>, treasury: &Treasury, staking: &Staking, clock: &Clock): VimverseInfo {
        let next_reward_time = staking::next_reward_time(staking);
        let cur_time = clock::timestamp_ms(clock) / 1000;
        let rebase_left_time = 0;
        if (next_reward_time > cur_time) {
            rebase_left_time = next_reward_time - cur_time;
        };
        let info = VimverseInfo {
            index: svim::index(scap),
            vim_staking_balance: staking::vim_staking_balance(staking, scap),
            next_reward: staking::next_reward(staking),
            rebase_left_time,
            total_reserves: treasury::total_reserves(treasury)
        };
        info
    }

    public fun query_bond_info<T>(terms: &Terms<T>, deposit_token: &DepoisitToken<T>, lock: &TreasuryLock<VIM>, clock: &Clock): BondInfo {
        let bal = treasury::deposit_balance(deposit_token);
        let info = BondInfo {
            mv: bal,
            rfv: bal,
            pol: 0,
            price_in_usd: bond_depository44::bond_price_in_usd(terms, deposit_token, lock, clock)
        };
        info
    }

    public fun query_user_bond_info<T>(
        user: address, 
        pay_value: u64,
        bond_depositor: &BondDepository44<T>, 
        terms: &Terms<T>, 
        deposit_token: &DepoisitToken<T>, 
        lock: &TreasuryLock<VIM>, 
        scap: &TreasuryCap<SVIM>,
        clock: &Clock): UserBondInfo {
        let info = UserBondInfo {
            price_in_usd: bond_depository44::bond_price_in_usd(terms, deposit_token, lock, clock),
            bond_price: bond_depository44::bond_price(terms, lock, clock),
            max_payout: bond_depository44::max_payout(lock, terms),
            debt_ratio: bond_depository44::debt_ratio(terms, lock, clock),
            current_debt: bond_depository44::current_debt(terms, clock),
            unclaim_payout: bond_depository44::unclaim_payout_for(user, bond_depositor, scap),
            claimable_payout: bond_depository44::pending_payout_for(user, bond_depositor, clock, scap),
            payout: bond_depository44::payout_for(pay_value, terms, lock, clock)
        };
        info
    }
}