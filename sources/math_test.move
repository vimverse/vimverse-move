#[test_only]
module vimverse::math_test {
    use std::debug;
    use vimverse::math;

    #[test]
    fun fraction_test() {
        debug::print(&(math::fraction(10000000, 4800) / 10000));
        debug::print(&(math::fraction(100000000, 4800) / 10000));
    }
}