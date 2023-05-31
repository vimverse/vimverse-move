module vimverse::math {
    const EOverFlow: u64 = 0; 
    public fun safe_mul_div_u64(x: u64, y: u64, z: u64): u64 {
        ((x as u128) * (y as u128) / (z as u128) as u64)
    }

    public fun safe_compare_mul_u64(a1: u64, b1: u64, a2: u64, b2: u64): bool {
        let left = (a1 as u128) * (b1 as u128);
        let right = (a2 as u128) * (b2 as u128);
        left >= right
    }

    public fun safe_mul_u64(x: u64, y: u64): u64 {
        ((x as u128) * (y as u128) as u64)
    }

    public fun fraction(x: u64, y: u64): u64 {
        let temp: u128 = ((x as u128) << 64) / (y as u128);
        (temp / 18446744073709 as u64)
    }

    public fun add(x: u64, y: u64): u64 {
        let c = x + y;
        assert!(c >= x, EOverFlow);
        c
    }

    public fun sub(x: u64, y: u64): u64 {
        assert!(x >= y, EOverFlow);
        x - y
    }

    /// Return the larger of `x` and `y`
    public fun max(x: u64, y: u64): u64 {
        if (x > y) {
            x
        } else {
            y
        }
    }

    /// Return the smaller of `x` and `y`
    public fun min(x: u64, y: u64): u64 {
        if (x < y) {
            x
        } else {
            y
        }
    }

    /// Return the absolute value of x - y
    public fun diff(x: u64, y: u64): u64 {
        if (x > y) {
            x - y
        } else {
            y - x
        }
    }

    /// Return the value of a base raised to a power
    public fun pow(base: u64, exponent: u8): u64 {
        let res = 1;
        while (exponent >= 1) {
            if (exponent % 2 == 0) {
                base = base * base;
                exponent = exponent / 2;
            } else {
                res = res * base;
                exponent = exponent - 1;
            }
        };

        res
    }

    /// Get a nearest lower integer Square Root for `x`. Given that this
    /// function can only operate with integers, it is impossible
    /// to get perfect (or precise) integer square root for some numbers.
    ///
    /// Example:
    /// ```
    /// math::sqrt(9) => 3
    /// math::sqrt(8) => 2 // the nearest lower square root is 4;
    /// ```
    ///
    /// In integer math, one of the possible ways to get results with more
    /// precision is to use higher values or temporarily multiply the
    /// value by some bigger number. Ideally if this is a square of 10 or 100.
    ///
    /// Example:
    /// ```
    /// math::sqrt(8) => 2;
    /// math::sqrt(8 * 10000) => 282;
    /// // now we can use this value as if it was 2.82;
    /// // but to get the actual result, this value needs
    /// // to be divided by 100 (because sqrt(10000)).
    ///
    ///
    /// math::sqrt(8 * 1000000) => 2828; // same as above, 2828 / 1000 (2.828)
    /// ```
    public fun sqrt(x: u64): u64 {
        let bit = 1u128 << 64;
        let res = 0u128;
        let x = (x as u128);

        while (bit != 0) {
            if (x >= res + bit) {
                x = x - (res + bit);
                res = (res >> 1) + bit;
            } else {
                res = res >> 1;
            };
            bit = bit >> 2;
        };

        (res as u64)
    }

    /// Similar to math::sqrt, but for u128 numbers. Get a nearest lower integer Square Root for `x`. Given that this
    /// function can only operate with integers, it is impossible
    /// to get perfect (or precise) integer square root for some numbers.
    ///
    /// Example:
    /// ```
    /// math::sqrt_u128(9) => 3
    /// math::sqrt_u128(8) => 2 // the nearest lower square root is 4;
    /// ```
    ///
    /// In integer math, one of the possible ways to get results with more
    /// precision is to use higher values or temporarily multiply the
    /// value by some bigger number. Ideally if this is a square of 10 or 100.
    ///
    /// Example:
    /// ```
    /// math::sqrt_u128(8) => 2;
    /// math::sqrt_u128(8 * 10000) => 282;
    /// // now we can use this value as if it was 2.82;
    /// // but to get the actual result, this value needs
    /// // to be divided by 100 (because sqrt_u128(10000)).
    ///
    ///
    /// math::sqrt_u128(8 * 1000000) => 2828; // same as above, 2828 / 1000 (2.828)
    /// ```
    public fun sqrt_u128(x: u128): u128 {
        let bit = 1u256 << 128;
        let res = 0u256;
        let x = (x as u256);

        while (bit != 0) {
            if (x >= res + bit) {
                x = x - (res + bit);
                res = (res >> 1) + bit;
            } else {
                res = res >> 1;
            };
            bit = bit >> 2;
        };

        (res as u128)
    }

    /// Calculate x / y, but round up the result.
    public fun divide_and_round_up(x: u64, y: u64): u64 {
        if (x % y == 0) {
            x / y
        } else {
            x / y + 1
        }
    }
}