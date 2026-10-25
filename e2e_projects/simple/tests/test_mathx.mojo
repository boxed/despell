from std.testing import assert_equal, assert_true, assert_false, TestSuite
from mylib.mathx import countdown, add, clamp, is_even, sum_to, scale, greeting, Counter, TABLE


def test_add() raises:
    assert_equal(add(2, 3), 5)


def test_clamp() raises:
    assert_equal(clamp(5, 0, 10), 5)
    assert_equal(clamp(-5, 0, 10), 0)


def test_is_even() raises:
    assert_true(is_even(4))


def test_sum_to() raises:
    assert_equal(sum_to(4), 6)


def test_scale() raises:
    assert_equal(scale(3, 2), 6)


def test_greeting() raises:
    assert_equal(greeting("Bob"), "Hello, Bob")


def test_counter() raises:
    var c = Counter(2)
    c.tick()
    assert_false(c.is_done(5))
    assert_equal(TABLE, 16)


def test_countdown() raises:
    assert_equal(countdown(3), 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run(quiet=True)
