from std.collections import Set
from std.testing import assert_equal, assert_true, TestSuite

from despell.fsutil import join, mkdirs, rmtree, write_text
from despell.project import load_config
from despell.runner import Run, add_exports, module_name


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


def test_overloads_get_distinct_mutant_ids() raises:
    var root = "tmp/overloads"
    rmtree(root)
    mkdirs(join(root, "src/pkg"))
    mkdirs(join(root, "tests"))
    write_text(
        join(root, "src/pkg/m.mojo"),
        "def f(x: Int) -> Int:\n    return x + 1\n\n\ndef f(x: Int, y: Int) -> Int:\n    return x - y\n",
    )
    write_text(join(root, "tests/test_m.mojo"), "def main():\n    pass\n")
    var r = Run(load_config(root), 1, join(root, "mutants"))
    r.prepare()
    var ids = Set[String]()
    for m in r.mutants:
        ids.add(m.id)
    assert_equal(len(ids), len(r.mutants))
    assert_true("pkg.m.f.1" in ids and "pkg.m.f.2" in ids, String(len(ids)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
