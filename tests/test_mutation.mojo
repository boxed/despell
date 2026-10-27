from std.collections import Set
from std.testing import assert_equal, assert_true, assert_false, TestSuite

from despell.mutation import analyze, generate, Function


def mutations(body: String) raises -> String:
    """The mutations in a function with `body` (one statement per line,
    indented 4), as their descriptions joined with `|`."""
    var src = String("def f():\n")
    for line in body.splitlines():
        src += "    " + String(line) + "\n"
    return described(analyze(src))


def described(functions: List[Function]) -> String:
    var out = String("")
    for f in functions:
        for m in f.mutations():
            if out.byte_length():
                out += "|"
            out += m.describe()
    return out^


def test_arithmetic_and_comparisons() raises:
    assert_equal(mutations("return a + b < c"), String("`+` -> `-`|`<` -> `<=`"))


def test_numbers_and_bools() raises:
    assert_equal(mutations("return foo(1, 2.5, 0x10, True)"), String("`1` -> `2`|`2.5` -> `3.5`|`0x10` -> `17`|`True` -> `False`"))


def test_numbers_too_big_for_an_int() raises:
    assert_equal(mutations("return 0xFFFFFFFFFFFFFFFF"), String("`0xFFFFFFFFFFFFFFFF` -> `0x10000000000000000`"))


def test_unary_vs_binary_minus() raises:
    assert_equal(mutations("return -a - b"), String("remove `-`|`-` -> `+`"))


def test_star_args_and_transfer_are_not_operators() raises:
    assert_equal(mutations("return g(*args, x^)"), String(""))


def test_xor_is_mutated() raises:
    assert_equal(mutations("return a ^ b"), String("`^` -> `&`"))


def test_for_in_is_not_mutated_but_membership_is() raises:
    assert_equal(mutations("for x in xs:\n    if x in ys:\n        pass"), String("`in` -> `not in`"))


def test_comprehension_in_is_not_mutated() raises:
    assert_equal(mutations("return [x for x in xs if x not in ys]"), String("`not in` -> `in`"))


def test_is_not_and_not() raises:
    assert_equal(mutations("return a is not b and not c"), String("`is not` -> `is`|`and` -> `or`|remove `not`"))


def test_augmented_assignment() raises:
    assert_equal(mutations("x += 1"), String("`+=` -> `-=`|`+=` -> `=`|`1` -> `2`"))


def test_strings_but_not_messages() raises:
    assert_equal(mutations('x = "a"\nraise Error("bad")\nprint("hi")'), String('`"a"` -> `"XXaXX"`'))


def test_symbol_names_are_not_mutated() raises:
    assert_equal(mutations('var r = external_call["chdir", Int32](d["k"])'), String('`"k"` -> `"XXkXX"`'))


def test_break_continue_and_min_max() raises:
    assert_equal(
        mutations("while True:\n    break\nreturn min(a, b)"),
        String("`True` -> `False`|`break` -> `continue`|`min` -> `max`"),
    )


def test_method_swaps() raises:
    assert_equal(mutations("return s.lower().find(x)"), String("`lower` -> `upper`|`find` -> `rfind`"))


def test_pragma_skips_line_and_function() raises:
    assert_equal(mutations("a = 1  # pragma: no mutate\nb = 2"), String("`2` -> `3`"))
    assert_equal(len(analyze("def f():  # pragma: no mutate\n    return 1\n")), 0)


def test_docstring_and_trait_stubs_are_skipped() raises:
    var fs = analyze('trait T:\n    def f(self) -> Int:\n        ...\n\ndef g():\n    """Doc 1."""\n    return 1\n')
    assert_equal(len(fs), 1)
    assert_equal(fs[0].qualname, String("g"))
    assert_equal(described(fs), String("`1` -> `2`"))


def test_qualnames() raises:
    var fs = analyze("struct S:\n    def m(self) -> Int:\n        return 1\n\n    def n(self):\n        def inner():\n            pass\n        x = 2\n")
    assert_equal(len(fs), 2)
    assert_equal(fs[0].qualname, String("S.m"))
    assert_equal(fs[1].qualname, String("S.n"))


def test_semicolons_and_nested_defs_in_compound_statements_are_left_alone() raises:
    assert_equal(mutations("var a = x + 1; var b = 2\nreturn a"), String(""))
    var fs = analyze("def f(x: Int) -> Int:\n    if x > 0:\n        def g() -> Int:\n            return 1\n        return g()\n    return x + 1\n")
    assert_equal(described(fs), String("`1` -> `2`|`+` -> `-`|`1` -> `2`"))


def test_literal_subscripts_stay_in_bounds() raises:
    assert_equal(mutations("return t[1] + t[0]"), String("`1` -> `0`|`+` -> `-`|`0` -> `1`"))
    assert_equal(mutations("return xs[i + 1]"), String("`+` -> `-`|`1` -> `2`"))


def test_generate_respects_enabled_and_disabled() raises:
    var src = String("def f(k: Int) -> Int:\n    var total = k + 1\n    if k > 2:\n        return total\n    return k * 3\n")
    var fs = analyze(src)
    var only3 = Set[Int]()
    only3.add(3)
    var text = generate(src, fs, 0, 1, 1, enabled=only3^).text
    assert_true("despell_m_ == 3" in text and not ("despell_m_ == 1" in text))
    var off = Set[Int]()
    off.add(0)
    assert_false("despell_m_" in generate(src, fs, 0, 1, 1, disabled_functions=off).text)


def _site_hooks(text: String) -> List[String]:
    var hooks = List[String]()
    for line in text.splitlines():
        if "_despell_site(" in line:
            hooks.append(String(line.strip()))
    return hooks^


def test_hooks_everywhere_records_coverage_without_mutants() raises:
    var src = String(
        "def f(k: Int) -> Int:\n    var total = k + 1\n    if k > 2:\n        total += 1\n        return total\n"
        + "    return k * 3\n"
    )
    var fs = analyze(src)
    var full = generate(src, fs, 0, 1, 1).text
    var none = generate(src, fs, 0, 1, 1, enabled=Set[Int](), hooks_everywhere=True).text
    # the same statements record coverage, but no mutant is in there
    assert_equal(_site_hooks(none), _site_hooks(full))
    assert_true(len(_site_hooks(none)) >= 3)
    assert_false("despell_m_ == 1" in none or "@inline" in none)
    # without it, functions without active mutants are left alone
    assert_false("despell_m_" in generate(src, fs, 0, 1, 1, enabled=Set[Int]()).text)


def test_no_inline_on_mutated_functions() raises:
    var src = String(
        "@always_inline\ndef a(x: Int) -> Int:\n    return x + 1\n\n"
        + '@always_inline("builtin")\ndef b(x: Int) -> Int:\n    return x + 1\n\n'
        + "@staticmethod\ndef c(x: Int) -> Int:\n    return x + 1\n\n"
        + "def d(x: Int) -> Int:\n    return x\n"
    )
    var text = generate(src, analyze(src), 0, 1, 3, no_inline=True).text
    assert_true("@inline(.never)\ndef a(" in text and not ("@always_inline\n" in text))
    assert_true('@always_inline("builtin")\ndef b(' in text)
    assert_true("@staticmethod\n@inline(.never)\ndef c(" in text)
    assert_false("@inline(.never)\ndef d(" in text)


def test_regions_line_up_with_multiline_statements() raises:
    var src = String(
        "def f(a: Int, b: Int) -> Int:\n    var x = max(\n        a + 1,\n        b,\n    )\n"
        + "    var y: Int = (\n        a * 2\n    )\n    if a > (\n        b - 1\n    ):\n"
        + "        return x + y\n    return x - y\n"
    )
    var gen = generate(src, analyze(src), 0, 1, 1)
    var lines = gen.text.splitlines()
    for r in gen.regions:
        if r.mutant < 0:
            continue
        # every mutant's region holds its mutated code
        var replacement = String("")
        for f in gen.functions:
            for gm in f.mutants:
                if gm.number == r.mutant:
                    replacement = gm.mutation.replacement
        var found = False
        for i in range(r.start, r.end + 1):
            if replacement in lines[i]:
                found = True
        assert_true(found)


def test_regions_line_up_past_a_tab_in_a_string() raises:
    var src = String("def f(a: Int) -> String:\n    var s = \"x\ty\"\n    if a > 1:\n        return s\n    return \"z\"\n")
    var gen = generate(src, analyze(src), 0, 1, 1)
    var lines = gen.text.split("\n")
    var checked = 0
    for r in gen.regions:
        if r.mutant < 0:
            continue
        var replacement = String("")
        for f in gen.functions:
            for gm in f.mutants:
                if gm.number == r.mutant:
                    replacement = gm.mutation.replacement
        var found = False
        for i in range(r.start, r.end + 1):
            if replacement in lines[i]:
                found = True
        assert_true(found, replacement)
        checked += 1
    assert_true(checked > 0)


def test_wrapped_expressions_stay_inside_their_block() raises:
    var src = String(
        "def f(a: Int, b: Int) -> Bool:\n    if not a and b > 1:\n        var ok = (\n"
        + "            a > 0\n            and b < 1\n        )\n        return ok\n    return False\n"
    )
    var lines = generate(src, analyze(src), 0, 1, 1).text.splitlines()
    var starts = 0
    for i in range(len(lines)):
        if String(lines[i].lstrip()).startswith("var ok = ("):
            starts += 1
            var indent = lines[i].byte_length() - String(lines[i].lstrip()).byte_length()
            var j = i + 1
            while not String(lines[j].lstrip()).startswith("return ok"):
                assert_true(lines[j].byte_length() - String(lines[j].lstrip()).byte_length() >= indent)
                j += 1
    assert_true(starts > 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
