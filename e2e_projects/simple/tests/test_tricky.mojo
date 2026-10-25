from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from mylib.tricky import (
    Rect, banner, nested, take_list, count_words, first_big, bits, pick,
    float_math, comptime_branch, safe_div, ignored, partly_ignored,
)


def test_rect() raises:
    var r = Rect.square(3)
    assert_equal(r.area(), 9)
    assert_true(r == Rect(3, 3))
    assert_equal(r.describe(), "shape with area 9")


def test_banner() raises:
    assert_true("hi" in banner("hi"))


def test_nested() raises:
    assert_equal(nested(2), 5)


def test_take_list() raises:
    var l = take_list([1, 2])
    assert_equal(len(l), 3)


def test_count_words() raises:
    var c = count_words("a b A")
    assert_equal(c["a"], 2)


def test_first_big() raises:
    assert_equal(first_big([1, 5, 9], 4), 5)


def test_misc() raises:
    _ = bits(5)
    assert_equal(pick(True, 1, 2), 1)
    assert_equal(float_math(1.0), 2.0)
    assert_equal(comptime_branch[3](), 30)
    assert_equal(safe_div(7, 2), 3)
    with assert_raises():
        _ = safe_div(1, 0)
    assert_equal(ignored(1), 2)
    assert_equal(partly_ignored(1), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run(quiet=True)
