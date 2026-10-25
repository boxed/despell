from despell.tokenizer import NAME, NUMBER, OP, STRING, tokenize


def kinds(source):
    return [(t.kind, t.text) for t in tokenize(source).tokens if t.kind not in ("newline", "comment")]


def test_basic_tokens():
    assert kinds("var x = a ** 2 // 3 -> 0x1F\n") == [
        (NAME, "var"), (NAME, "x"), (OP, "="), (NAME, "a"), (OP, "**"), (NUMBER, "2"),
        (OP, "//"), (NUMBER, "3"), (OP, "->"), (NUMBER, "0x1F"),
    ]


def test_strings_with_prefixes_and_escapes():
    assert kinds('r"a\\"b" + t"{x}" + rb\'z\'\n') == [
        (STRING, 'r"a\\"b"'), (OP, "+"), (STRING, 't"{x}"'), (OP, "+"), (STRING, "rb'z'"),
    ]


def test_name_ending_in_prefix_letter_is_not_a_string():
    assert kinds('bar("x")\n') == [(NAME, "bar"), (OP, "("), (STRING, '"x"'), (OP, ")")]


def test_multiline_string_lines_are_tracked():
    src = tokenize('def f():\n    x = """\n  a\nb"""\n    return x\n')
    assert src.in_string_lines == {2, 3}
    assert [ll.first_line for ll in src.logical_lines] == [0, 1, 4]


def test_logical_lines_span_brackets_and_continuations():
    src = tokenize("x = f(1,\n      2)\ny = 1 + \\\n    2\nz = 3\n")
    assert [(ll.first_line, ll.last_line) for ll in src.logical_lines] == [(0, 1), (2, 3), (4, 4)]


def test_comments_are_not_part_of_logical_lines():
    src = tokenize("x = 1  # one\n# lonely\ny = 2\n")
    assert [[t.text for t in ll.tokens] for ll in src.logical_lines] == [["x", "=", "1"], ["y", "=", "2"]]
