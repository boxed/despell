"""Equivalent mutants: ones whose function compiles, with optimization, to
exactly the same code as without them, so no test can tell them apart
("trivial compiler equivalence"). A dead store (`var i = 0` -> `var i = 1`
where `i` is set again before it's read) is the typical one.

Each function with mutants to check is copied into its module right after
itself: once unmutated and once per mutant, each exported so it's compiled on
its own, and the module is compiled to assembly. The copies sit at different
lines, and source locations end up in the code (the line of a bounds check,
say), so numbers within a copy's lines are compared relative to its first
line; copies start `EQ_GAP` lines apart, so a mutated constant can't pass for
a line number. Branch labels are compared by the order they're defined in,
data by its contents, and helpers the compiler split off a copy along with
it. Whatever this doesn't account for makes copies differ, never equal.
"""

from std.collections import Dict, Set
from std.sys.info import CompilationTarget

from .fsutil import hash_text
from .mutation import Function
from .textutil import split_lines

comptime EQ_PREFIX = "despell_eq_"
# bumped when the comparison improves, so mutants are compared again
comptime EQ_VERSION = 2
comptime EQ_GAP = 100


@fieldwise_init
struct EqCandidate(Copyable, Movable):
    """A mutant to check: its number, the index of its function in the
    module's functions, and the mutation (0-based line and columns)."""

    var number: Int
    var fn_index: Int
    var line: Int
    var col: Int
    var end_col: Int
    var replacement: String


@fieldwise_init
struct EqCopy(Copyable, Movable):
    """A copy of a function in the generated module: unmutated (`number`
    -1) or with one mutant, at 1-based lines `first_line..last_line`."""

    var tag: String
    var number: Int
    var fn_index: Int
    var first_line: Int
    var last_line: Int


struct EqModule(Movable):
    var text: String
    var copies: List[EqCopy]

    def __init__(out self, var text: String, var copies: List[EqCopy]):
        self.text = text^
        self.copies = copies^


def copy_tag(number: Int, fn_index: Int) -> String:
    """The copy's name. Ends in `_e` so no tag is part of another."""
    if number < 0:
        return EQ_PREFIX + "r" + String(fn_index) + "_e"
    return EQ_PREFIX + "m" + String(number) + "_e"


def _indent_of(line: String) -> String:
    return String(line[byte = 0 : line.byte_length() - String(line.lstrip()).byte_length()])


def _name_of(qualname: String) -> String:
    var dot = qualname.rfind(".")
    return String(qualname[byte = dot + 1 :]) if dot >= 0 else qualname


def can_copy(lines: List[String], f: Function) -> Bool:
    """Whether a renamed, exported copy of `f` can compile: not a
    constructor or destructor (`out self`, `deinit self` belong to their
    name), not parametric (can't be exported), not nested in a function."""
    var def_text = lines[f.def_line]
    if "out self" in def_text or "deinit self" in def_text:
        return False
    var name = _name_of(f.qualname)
    var at = def_text.find("def " + name)
    if at < 0:
        return False
    var after = at + 4 + name.byte_length()
    if after >= def_text.byte_length() or String(def_text[byte = after : after + 1]) != "(":
        return False
    # the nearest less indented line above: a `def` means it's nested
    var indent = _indent_of(def_text).byte_length()
    var i = f.def_line - 1
    while i >= 0:
        var stripped = String(lines[i].strip())
        if stripped.byte_length() and _indent_of(lines[i]).byte_length() < indent and not stripped.startswith("@"):
            return not (stripped.startswith("def ") or stripped.startswith("async def "))
        i -= 1
    return True


def equivalence_module(lines: List[String], functions: List[Function], candidates: List[EqCandidate]) -> EqModule:
    """`lines` (the module's source, imports made absolute) with copies of
    the candidates' functions (which `can_copy`) after each function."""
    var by_fn = Dict[Int, List[Int]]()
    for k in range(len(candidates)):
        var l = by_fn.get(candidates[k].fn_index, List[Int]())
        l.append(k)
        by_fn[candidates[k].fn_index] = l^
    var out = List[String]()
    var copies = List[EqCopy]()
    var pos = 0
    var last_start = -EQ_GAP
    for fi in range(len(functions)):
        if not (fi in by_fn):
            continue
        ref f = functions[fi]
        while pos <= f.body_end and pos < len(lines):
            out.append(_with_newline(lines[pos]))
            pos += 1
        var ks = by_fn.get(fi, List[Int]())
        for c in range(-1, len(ks)):
            var number = -1 if c < 0 else candidates[ks[c]].number
            var tag = copy_tag(number, fi)
            # far enough from the previous copy (see the module docstring)
            out.append(String("\n"))
            while len(out) + 2 - last_start < EQ_GAP:
                out.append(String("\n"))
            out.append(_indent_of(lines[f.def_line]) + "@export(\"" + tag + "\")\n")
            if _is_static(lines, f.def_line):
                out.append(_indent_of(lines[f.def_line]) + "@staticmethod\n")
            var first = len(out) + 1
            last_start = first
            for i in range(f.def_line, f.body_end + 1):
                var line = _with_newline(lines[i])
                if i == f.def_line:
                    line = line.replace("def " + _name_of(f.qualname) + "(", "def " + tag + "(")
                if c >= 0 and i == candidates[ks[c]].line:
                    ref m = candidates[ks[c]]
                    line = String(line[byte = 0 : m.col]) + m.replacement + String(line[byte = m.end_col :])
                out.append(line^)
            copies.append(EqCopy(tag, number, fi, first, len(out)))
    while pos < len(lines):
        out.append(_with_newline(lines[pos]))
        pos += 1
    var text = String("")
    for line in out:
        text += line
    return EqModule(text^, copies^)


def _with_newline(line: String) -> String:
    return line if line.endswith("\n") else line + "\n"


def _is_static(lines: List[String], def_line: Int) -> Bool:
    var i = def_line - 1
    while i >= 0 and String(lines[i].strip()).startswith("@"):
        if String(lines[i].strip()) == "@staticmethod":
            return True
        i -= 1
    return False


# ---- comparing the compiled copies ---------------------------------------------


struct Assembly(Movable):
    """A compiled module: each function's lines, and each data label's
    contents."""

    var functions: Dict[String, List[String]]
    var data: Dict[String, String]

    def __init__(out self):
        self.functions = Dict[String, List[String]]()
        self.data = Dict[String, String]()


def _label(line: String) -> String:
    """The label a line defines (at column 0, ending in `:`), or ""."""
    if line.byte_length() == 0 or line.startswith(" ") or line.startswith("\t"):
        return ""
    var stripped = String(line.rstrip())
    if not stripped.endswith(":"):
        return ""
    var name = String(stripped[byte = 0 : stripped.byte_length() - 1])
    if name.startswith("\"") and name.endswith("\"") and name.byte_length() >= 2:
        return String(name[byte = 1 : name.byte_length() - 1])
    return name^


def parse_assembly(text: String) -> Assembly:
    """Functions are what's between `.cfi_startproc` and `.cfi_endproc`,
    named by the label before; data is what follows any other label."""
    var asm = Assembly()
    var current = String("")  # the function being read
    var body = List[String]()
    var last_label = String("")
    var data = String("")
    for raw in split_lines(text):
        var line = String(raw)
        var stripped = String(line.strip())
        if current.byte_length():
            if stripped == ".cfi_endproc":
                asm.functions[current] = body^
                body = List[String]()
                current = String("")
            else:
                body.append(line^)
            continue
        if stripped == ".cfi_startproc":
            current = last_label
            last_label = String("")
            data = String("")
            continue
        var label = _label(line)
        if label.byte_length():
            if last_label.byte_length():
                asm.data[last_label] = data
            last_label = label^
            data = String("")
        elif last_label.byte_length() and _is_data(stripped):
            # only the data itself: what follows it (a `.globl` naming the
            # next function, say) isn't part of it
            data += stripped + "\n"
    if last_label.byte_length():
        asm.data[last_label] = data
    return asm^


def _comment_start(line: String) -> Int:
    comptime if CompilationTarget.is_x86():
        return line.find("#")
    else:
        var a = line.find(";")
        var b = line.find("//")
        if a < 0:
            return b
        if b < 0:
            return a
        return min(a, b)


comptime _DATA_DIRECTIVES = " .byte .short .hword .long .word .quad .xword .ascii .asciz .zero .space "


def _is_data(line: String) -> Bool:
    var words = line.split()
    return len(words) > 0 and " " + String(words[0]) + " " in _DATA_DIRECTIVES


def _is_ident_char(c: String, first: Bool) -> Bool:
    if c.byte_length() != 1:
        return True  # non-ASCII, in a mangled name
    var b = c.as_bytes()[0]
    if (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 46 or b == 36:
        return True
    return not first and b >= 48 and b <= 57


def normalize(body: List[String], asm: Assembly, copy: EqCopy) -> String:
    """`body` (a function of the copy `copy`) with what differs between
    copies of the same code taken out: see the module docstring."""
    var labels = Dict[String, String]()
    for line in body:
        var label = _label(line)
        if label.byte_length():
            labels[label] = "@L" + String(len(labels))
    var out = String("")
    for line in body:
        var label = _label(line)
        if label.byte_length():
            out += labels.get(label, "") + ":\n"
            continue
        var cut = _comment_start(line)
        var code = String(String(line[byte=0:cut]).strip()) if cut >= 0 else String(line.strip())
        if code.byte_length() == 0:
            continue
        if code.startswith(".") and not _is_data(code):
            continue
        out += _normalize_line(code, labels, asm, copy) + "\n"
    return out^


def _normalize_line(code: String, labels: Dict[String, String], asm: Assembly, copy: EqCopy) -> String:
    var out = String("")
    var chars = List[String]()
    for c in code.codepoint_slices():
        chars.append(String(c))
    var i = 0
    while i < len(chars):
        var c = chars[i]
        if c == "\"":
            var j = i + 1
            while j < len(chars) and chars[j] != "\"":
                j += 1
            var name = String("")
            for k in range(i + 1, min(j, len(chars))):
                name += chars[k]
            out += _symbol(name, labels, asm, copy)
            i = j + 1
            continue
        if _is_ident_char(c, True):
            var j = i
            var name = String("")
            while j < len(chars) and _is_ident_char(chars[j], False):
                name += chars[j]
                j += 1
            out += _symbol(name, labels, asm, copy)
            i = j
            continue
        if c.byte_length() == 1 and c.as_bytes()[0] >= 48 and c.as_bytes()[0] <= 57:
            var j = i
            var digits = String("")
            while j < len(chars) and _is_ident_char(chars[j], False):
                digits += chars[j]
                j += 1
            out += _number(digits, copy)
            i = j
            continue
        out += c
        i += 1
    return out^


def _symbol(name: String, labels: Dict[String, String], asm: Assembly, copy: EqCopy) -> String:
    if name in labels:
        return labels.get(name, "")
    # the copy's own name, in a call to itself or a helper split off it
    if copy.tag in name:
        return name.replace(copy.tag, "@COPY")
    if name in asm.data:
        return "@D" + hash_text(asm.data.get(name, ""))
    return name


def _number(digits: String, copy: EqCopy) -> String:
    var value: Int
    try:
        if digits.startswith("0x"):
            value = Int(atol(String(digits[byte=2:]), base=16))
        else:
            value = Int(atol(digits))
    except:
        return digits
    if value >= copy.first_line and value <= copy.last_line:
        return "@LINE+" + String(value - copy.first_line)
    return digits


def copy_code(asm: Assembly, copy: EqCopy) -> String:
    """Everything the copy compiled to, normalized: its function and the
    helpers split off it, in name order. Empty if it isn't there."""
    var names = List[String]()
    for item in asm.functions.items():
        if copy.tag in item.key:
            names.append(item.key)
    sort(names)
    var out = String("")
    for name in names:
        out += name.replace(copy.tag, "@COPY") + ":\n"
        out += normalize(asm.functions.get(name, List[String]()), asm, copy)
    return out^


def equivalent_copies(asm: Assembly, copies: List[EqCopy]) -> Set[Int]:
    """The mutants whose copy compiled to the same code as their
    function's unmutated copy."""
    var reference = Dict[Int, String]()
    for c in copies:
        if c.number < 0:
            reference[c.fn_index] = copy_code(asm, c)
    var out = Set[Int]()
    for c in copies:
        if c.number < 0:
            continue
        var ref_code = reference.get(c.fn_index, "")
        if ref_code.byte_length() == 0:
            continue
        if copy_code(asm, c) == ref_code:
            out.add(c.number)
    return out^
