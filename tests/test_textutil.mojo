from std.testing import assert_equal, assert_true, assert_false, TestSuite

from despell.textutil import (
    absolutize_imports, first_error, first_failed_test, glob_match, link_references, numbers_after,
    parse_diagnostics, split_lines, without_warnings,
)


def test_split_lines_only_splits_on_newlines() raises:
    # String.splitlines also splits on tabs, which assembly is full of
    var lines = split_lines("\tmov\tw0, #1\r\nb\x0bc\n\nlast")
    assert_equal(len(lines), 4)
    assert_equal(lines[0], "\tmov\tw0, #1")
    assert_equal(lines[1], "b\x0bc")
    assert_equal(lines[2], "")
    assert_equal(lines[3], "last")
    var kept = split_lines("a\tb\r\nc\n", keepends=True)
    assert_equal(len(kept), 2)
    assert_equal(kept[0], "a\tb\r\n")
    assert_equal(kept[1], "c\n")
    assert_equal(len(split_lines("")), 0)
    var multibyte = split_lines("é\nx—\r\n😀")
    assert_equal(len(multibyte), 3)
    assert_equal(multibyte[0], "é")
    assert_equal(multibyte[1], "x—")
    assert_equal(multibyte[2], "😀")


def test_glob() raises:
    assert_true(glob_match("mylib.*.clamp.*", "mylib.mathx.clamp.2"))
    assert_true(glob_match("src/*.mojo", "src/a.mojo"))
    assert_true(glob_match("a?c", "abc"))
    assert_true(glob_match("[ab]x", "bx"))
    assert_false(glob_match("[!ab]x", "bx"))
    assert_false(glob_match("mylib.*", "other.x"))


def test_absolutize_imports() raises:
    var text = String("from .canvas import Canvas\nfrom ..util.x import y\nfrom . import geometry\nfrom std.os import getenv\n")
    assert_equal(
        absolutize_imports(text, [String("pkg"), String("sub")]),
        String("from pkg.sub.canvas import Canvas\nfrom pkg.util.x import y\nfrom pkg.sub import geometry\nfrom std.os import getenv\n"),
    )


def test_diagnostics() raises:
    var out = String(
        "Included from /x/tests/t.mojo:3:\n"
        + "src/a.mojo:12:5: error: function instantiation failed\n"
        + "    def f():\n"
        + "Mojo/stdlib/std/simd.mojo:983:9: note: constraint failed: the SIMD type must be floating point\n"
        + "/bin/mojo: error: failed to run the pass manager\n"
    )
    var d = parse_diagnostics(out)
    assert_equal(len(d), 2)
    assert_equal(d[0].path, String("src/a.mojo"))
    assert_equal(d[0].line, 11)
    assert_true(d[0].is_error)
    assert_equal(d[1].message, String("constraint failed: the SIMD type must be floating point"))
    assert_equal(first_error(out), String("function instantiation failed"))


def test_output_lines() raises:
    var out = String("despell-hit 3\nx\ndespell-hit 1\ndespell-hit 3\ndespell-site 7\n")
    var hits = numbers_after(out, "despell-hit ")
    assert_equal(len(hits), 2)
    assert_equal(hits[0], 1)
    assert_equal(numbers_after(out, "despell-site ")[0], 7)
    assert_equal(first_failed_test("    PASS [ 0.1 ] test_a\n    FAIL [ 0.2 ] test_b\n"), String("test_b"))
    var refs = link_references("Undefined symbols:\n      _turbokod::posix::chdir_path(::String) in mojo_archive-a8b61e5.a\n")
    assert_equal(len(refs), 1)
    assert_equal(refs[0], String("turbokod::posix::chdir_path"))


def test_without_warnings() raises:
    var out = String("a.mojo:1:1: warning: unused\n  x = 1\n  ^\na.mojo:2:1: error: bad\n  y\n")
    assert_equal(without_warnings(out), String("a.mojo:2:1: error: bad\n  y"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
