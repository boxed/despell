from std.testing import TestSuite, assert_equal, assert_false, assert_true

from despell.equivalence import (
    EQ_GAP, EqCandidate, EqCopy, can_copy, copy_tag, equivalence_module, equivalent_copies, parse_assembly,
)
from despell.mutation import analyze


def _lines(text: String) -> List[String]:
    var out = List[String]()
    for l in text.splitlines(keepends=True):
        out.append(String(l))
    return out^


comptime SOURCE = """struct Acc:
    var total: Int

    def __init__(out self):
        self.total = 0

    def add(mut self, x: Int) -> Int:
        var unused = 0
        unused = x
        return self.total + unused


def twice(x: Int) -> Int:
    return x * 2


def outer() -> Int:
    def inner() -> Int:
        return 1 + 1
    return inner()


def generic[T: Intable](x: T) -> Int:
    return Int(x) + 1
"""


def test_what_can_be_copied() raises:
    var lines = _lines(SOURCE)
    var fs = analyze(SOURCE)
    var copyable = List[String]()
    for f in fs:
        if can_copy(lines, f):
            copyable.append(f.qualname)
    # not the constructor, the nested function or the parametric one
    assert_equal(len(copyable), 3)
    assert_equal(copyable[0], "Acc.add")
    assert_equal(copyable[1], "twice")
    assert_equal(copyable[2], "outer")


def test_the_module_holds_a_copy_per_mutant_and_one_unmutated() raises:
    var lines = _lines(SOURCE)
    var fs = analyze(SOURCE)
    var add = -1
    for i in range(len(fs)):
        if fs[i].qualname == "Acc.add":
            add = i
    var cands = List[EqCandidate]()
    # `var unused = 0` -> `= 1`, line 7 (0-based), column of the 0
    cands.append(EqCandidate(5, add, 7, 21, 22, "1"))
    var mod = equivalence_module(lines, fs, cands)
    assert_equal(len(mod.copies), 2)
    var text_lines = mod.text.splitlines()
    ref unmutated = mod.copies[0]
    ref mutated = mod.copies[1]
    assert_equal(unmutated.number, -1)
    assert_equal(mutated.number, 5)
    assert_true(mutated.first_line - unmutated.first_line >= EQ_GAP)
    assert_equal(String(text_lines[unmutated.first_line - 2].strip()), "@export(\"" + copy_tag(-1, add) + "\")")
    assert_equal(String(text_lines[unmutated.first_line - 1].strip()), "def " + copy_tag(-1, add) + "(mut self, x: Int) -> Int:")
    assert_equal(String(text_lines[unmutated.first_line].strip()), "var unused = 0")
    assert_equal(String(text_lines[mutated.first_line].strip()), "var unused = 1")
    assert_equal(String(text_lines[mutated.last_line - 1].strip()), "return self.total + unused")
    # inside the struct, before what follows it
    assert_true(mod.text.find(copy_tag(5, add)) < mod.text.find("def twice"))


comptime ASM = """\t.globl\t_despell_eq_r1_e
_despell_eq_r1_e:
\t.cfi_startproc
\tadrp\tx8, l_.str.1@PAGE
\tcmp\tx0, #3
\tb.lt\tLBB0_2
\tmov\tw0, #1001
\tb\tLBB0_3
LBB0_2:
\tmov\tw0, #7
LBB0_3:
\tret
\t.cfi_endproc
\t.globl\t_despell_eq_m5_e
_despell_eq_m5_e:
\t.cfi_startproc
\tadrp\tx8, l_.str.2@PAGE
\tcmp\tx0, #3
\tb.lt\tLBB1_7
\tmov\tw0, #2001
\tb\tLBB1_8
LBB1_7:
\tmov\tw0, #7
LBB1_8:
\tret
\t.cfi_endproc
\t.globl\t_despell_eq_m6_e
_despell_eq_m6_e:
\t.cfi_startproc
\tadrp\tx8, l_.str.1@PAGE
\tcmp\tx0, #3
\tb.lt\tLBB2_8
\tmov\tw0, #3001
\tb\tLBB2_7
LBB2_7:
\tmov\tw0, #7
LBB2_8:
\tret
\t.cfi_endproc
\t.globl\t_despell_eq_m7_e
_despell_eq_m7_e:
\t.cfi_startproc
\tadrp\tx8, l_.str.3@PAGE
\tcmp\tx0, #3
\tb.lt\tLBB3_2
\tmov\tw0, #4001
\tb\tLBB3_3
LBB3_2:
\tmov\tw0, #7
LBB3_3:
\tret
\t.cfi_endproc
\t.globl\t_despell_eq_m8_e
_despell_eq_m8_e:
\t.cfi_startproc
\tadrp\tx8, l_.str.1@PAGE
\tcmp\tx0, #4
\tb.lt\tLBB4_2
\tmov\tw0, #5001
\tb\tLBB4_3
LBB4_2:
\tmov\tw0, #7
LBB4_3:
\tret
\t.cfi_endproc
l_.str.1:
\t.asciz\t"index out of range"
l_.str.2:
\t.asciz\t"index out of range"
l_.str.3:
\t.asciz\t"something else"
"""


def test_copies_are_compared_without_what_differs_between_copies() raises:
    var asm = parse_assembly(ASM)
    var copies = List[EqCopy]()
    copies.append(EqCopy(copy_tag(-1, 1), -1, 1, 1000, 1010))
    # other labels, its own line, data with the same contents: equivalent
    copies.append(EqCopy(copy_tag(5, 1), 5, 1, 2000, 2010))
    # the branches swapped
    copies.append(EqCopy(copy_tag(6, 1), 6, 1, 3000, 3010))
    # different data
    copies.append(EqCopy(copy_tag(7, 1), 7, 1, 4000, 4010))
    # a different constant
    copies.append(EqCopy(copy_tag(8, 1), 8, 1, 5000, 5010))
    var eq = equivalent_copies(asm, copies)
    assert_equal(len(eq), 1)
    assert_true(5 in eq)


def test_a_copy_that_isnt_there_is_never_equivalent() raises:
    var asm = parse_assembly(ASM)
    var copies = List[EqCopy]()
    copies.append(EqCopy(copy_tag(-1, 9), -1, 9, 1000, 1010))
    copies.append(EqCopy(copy_tag(5, 9), 5, 9, 2000, 2010))
    assert_equal(len(equivalent_copies(asm, copies)), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
