import textwrap

from despell.mutation import analyze, generate
from despell.tokenizer import tokenize


def mutations(body: str) -> list[str]:
    src = "def f():\n" + textwrap.indent(textwrap.dedent(body), "    ")
    return [m.describe() for f in analyze(src) for m in f.mutations]


def test_arithmetic_and_comparisons():
    assert mutations("return a + b < c\n") == ["`+` -> `-`", "`<` -> `<=`"]


def test_numbers_and_bools():
    assert mutations("return foo(1, 2.5, 0x10, True)\n") == [
        "`1` -> `2`", "`2.5` -> `3.5`", "`0x10` -> `17`", "`True` -> `False`",
    ]


def test_unary_vs_binary_minus():
    assert mutations("return -a - b\n") == ["remove `-`", "`-` -> `+`"]


def test_star_args_and_transfer_are_not_operators():
    assert mutations("return g(*args, x^)\n") == []


def test_xor_is_mutated():
    assert mutations("return a ^ b\n") == ["`^` -> `&`"]


def test_for_in_is_not_mutated_but_membership_is():
    assert mutations("for x in xs:\n    if x in ys:\n        pass\n") == ["`in` -> `not in`"]


def test_comprehension_in_is_not_mutated():
    assert mutations("return [x for x in xs if x not in ys]\n") == ["`not in` -> `in`"]


def test_is_not_and_not():
    assert mutations("return a is not b and not c\n") == ["`is not` -> `is`", "`and` -> `or`", "remove `not`"]


def test_augmented_assignment():
    assert mutations("x += 1\n") == ["`+=` -> `-=`", "`+=` -> `=`", "`1` -> `2`"]


def test_strings_but_not_messages():
    assert mutations('x = "a"\nraise Error("bad")\nprint("hi")\n') == ['`"a"` -> `"XXaXX"`']


def test_break_continue_and_min_max():
    assert mutations("while True:\n    break\nreturn min(a, b)\n") == [
        "`True` -> `False`", "`break` -> `continue`", "`min` -> `max`",
    ]


def test_method_swaps():
    assert mutations("return s.lower().find(x)\n") == ["`lower` -> `upper`", "`find` -> `rfind`"]


def test_pragma_skips_line_and_function():
    assert mutations("a = 1  # pragma: no mutate\nb = 2\n") == ["`2` -> `3`"]
    assert analyze("def f():  # pragma: no mutate\n    return 1\n") == []


def test_docstring_and_trait_stubs_are_skipped():
    src = 'trait T:\n    def f(self) -> Int:\n        ...\n\ndef g():\n    """Doc 1."""\n    return 1\n'
    [g] = analyze(src)
    assert g.qualname == "g"
    assert [m.describe() for m in g.mutations] == ["`1` -> `2`"]


def test_qualnames():
    src = "struct S:\n    def m(self) -> Int:\n        return 1\n\n    def n(self):\n        def inner():\n            pass\n        x = 2\n"
    assert [f.qualname for f in analyze(src)] == ["S.m", "S.n"]


SOURCE = '''\
"""Module docstring."""


def f(xs: List[Int], k: Int) -> Int:
    """Doc."""
    @parameter
    def helper(y: Int) -> Int:
        return y * 2

    var total = k + 1
    for x in xs:
        if x > k:
            total += x
        elif x == 0:
            break
    comptime N = 4 + 1
    return helper(total)
'''


def test_generate_schemata():
    gen = generate(SOURCE, analyze(SOURCE), first_fid=0, first_mutant=1, n_functions_total=1)
    text = gen.text
    assert text.startswith('"""Module docstring."""\nfrom std.ffi import _Global')
    tokenize(text)  # still tokenizes
    # Only the statement holding a mutation is duplicated. Statements inside a
    # duplicated block get their own dispatch only in the original copy, since
    # just one mutant is active at a time.
    assert text[text.index("def f(") :] == '''\
def f(xs: List[Int], k: Int) -> Int:
    """Doc."""
    var despell_m_ = _despell_active(0)
    @parameter
    def helper(y: Int) -> Int:
        if _despell_active(0) == 1:
            return y / 2
        elif _despell_active(0) == 2:
            return y * 3
        else:
            return y * 2

    var total = (
            (k - 1) if despell_m_ == 3 else
            (k + 2) if despell_m_ == 4 else
            (k + 1))
    for x in xs:
        if despell_m_ == 5:
            if x >= k:
                total += x
            elif x == 0:
                break
        else:
            if x > k:
                if despell_m_ == 6:
                    total -= x
                elif despell_m_ == 7:
                    total = x
                else:
                    total += x
            elif (
                    (x != 0) if despell_m_ == 8 else
                    (x == 1) if despell_m_ == 9 else
                    (x == 0)):
                if despell_m_ == 10:
                    continue
                else:
                    break
    comptime N = 4 + 1
    return helper(total)
    _despell_abort("despell: a mutant fell off the end of f")
'''
    lines = text.splitlines()
    mutant_lines = {r.mutant: lines[r.start].strip() for r in gen.regions if r.mutant}
    assert mutant_lines[3] == "(k - 1) if despell_m_ == 3 else"
    assert mutant_lines[5] == "if x >= k:"


def test_generate_respects_enabled_and_disabled():
    functions = analyze(SOURCE)
    gen = generate(SOURCE, functions, first_fid=0, first_mutant=1, n_functions_total=1, enabled={3})
    assert "despell_m_ == 3" in gen.text and "despell_m_ == 1" not in gen.text
    gen = generate(SOURCE, functions, first_fid=0, first_mutant=1, n_functions_total=1, disabled_functions={0})
    assert "despell_m_" not in gen.text

