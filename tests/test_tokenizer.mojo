from std.testing import assert_equal, assert_true, TestSuite

from despell.tokenizer import NAME, NUMBER, OP, STRING, NEWLINE, COMMENT, tokenize


def kinds(source: String) raises -> String:
    """The tokens of `source` as `kind:text` words, without newlines and comments."""
    var out = String("")
    for t in tokenize(source).tokens:
        if t.kind == NEWLINE or t.kind == COMMENT:
            continue
        if out.byte_length():
            out += " "
        out += String(t.kind) + ":" + t.text
    return out^


def test_basic_tokens() raises:
    assert_equal(kinds("var x = a ** 2 // 3 -> 0x1F\n"), String("0:var 0:x 3:= 0:a 3:** 1:2 3:// 1:3 3:-> 1:0x1F"))


def test_numbers() raises:
    assert_equal(kinds("1_000 3.5e-2 .5 1.\n"), String("1:1_000 1:3.5e-2 1:.5 1:1."))


def test_strings_with_prefixes_and_escapes() raises:
    assert_equal(kinds('r"a\\"b" + t"{x}" + rb\'z\'\n'), String('2:r"a\\"b" 3:+ 2:t"{x}" 3:+ 2:rb\'z\''))


def test_name_ending_in_prefix_letter_is_not_a_string() raises:
    assert_equal(kinds('bar("x")\n'), String('0:bar 3:( 2:"x" 3:)'))


def test_multiline_string_lines_are_tracked() raises:
    var src = tokenize('def f():\n    x = """\n  a\nb"""\n    return x\n')
    assert_equal(len(src.in_string_lines), 2)
    assert_true(2 in src.in_string_lines and 3 in src.in_string_lines)
    assert_equal(len(src.logical_lines), 3)
    assert_equal(src.logical_lines[2].first_line, 4)


def test_logical_lines_span_brackets_and_continuations() raises:
    var src = tokenize("x = f(1,\n      2)\ny = 1 + \\\n    2\nz = 3\n")
    assert_equal(len(src.logical_lines), 3)
    assert_equal(src.logical_lines[0].last_line, 1)
    assert_equal(src.logical_lines[1].first_line, 2)
    assert_equal(src.logical_lines[1].last_line, 3)
    assert_equal(src.logical_lines[2].first_line, 4)


def test_comments_are_not_part_of_logical_lines() raises:
    var src = tokenize("x = 1  # one\n# lonely\ny = 2\n")
    assert_equal(len(src.logical_lines), 2)
    assert_equal(len(src.logical_lines[0].tokens), 3)
    assert_equal(src.logical_lines[1].tokens[0].text, String("y"))


def test_non_ascii() raises:
    assert_equal(kinds('x = "héllo"  # ö\nnäme = 1\n'), String('0:x 3:= 2:"héllo" 0:näme 3:= 1:1'))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
