from std.collections import Set
from std.testing import assert_equal, assert_true, TestSuite

from despell.runner import add_exports, module_name


def test_add_exports() raises:
    var text = String(
        "def _despell_active(fid: Int) -> Int:\n    return 0\n\ndef f() -> Int:\n    return 1\n\n"
        + "struct S:\n    @always_inline\n    def m(self) -> Int:\n        return 2\n    def g(self):\n        pass\n"
    )
    var skip = Set[Int]()
    skip.add(2)
    var exported = add_exports(text, skip)
    assert_equal(
        exported.text,
        String(
            "def _despell_active(fid: Int) -> Int:\n    return 0\n\n" + '@export("despell_x_0")\n'
            + "def f() -> Int:\n    return 1\n\nstruct S:\n    @always_inline\n" + '    @export("despell_x_1")\n'
            + "    def m(self) -> Int:\n        return 2\n    def g(self):\n        pass\n"
        ),
    )
    assert_equal(len(exported.by_line), 4)
    assert_equal(exported.by_line[3], 0)
    assert_equal(exported.by_line[4], 0)
    assert_equal(exported.by_line[9], 1)
    assert_equal(exported.by_line[10], 1)
    assert_equal(exported.original_line(2), 2)
    assert_equal(exported.original_line(4), 3)
    assert_equal(exported.original_line(10), 8)
    assert_equal(exported.original_line(12), 10)


def test_module_names() raises:
    assert_equal(module_name("mylib/mathx.mojo"), String("mylib.mathx"))
    assert_equal(module_name("mylib/__init__.mojo"), String("mylib"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
