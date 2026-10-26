"""Find functions in Mojo source, generate mutants, and emit mutation schemata.

All mutants go into the same program. Each statement holding mutations
switches on the active mutant, read from `DESPELL_MUTANT`:

    def clamp(x: Int, lo: Int, hi: Int) -> Int:
        var despell_m_ = _despell_active(1)
        if despell_m_ == 2:
            if x <= lo:
                return lo
        else:
            if x < lo:
                return lo

Only the statement is duplicated, never the whole function, so the generated
code grows linearly with the number of mutants.
"""

from std.collections import Set

from .tokenizer import NAME, NUMBER, OP, STRING, LogicalLine, Token, TokenizedSource, tokenize

comptime INDENT = "    "

comptime _KEYWORDS = (
    " and or not in is if elif else for while return raise def fn var ref comptime alias struct trait"
    " with as try except finally pass break continue from import out mut owned deinit read raises"
    " lambda yield assert "
)


def _in(word: String, words: String) -> Bool:
    """Whether `word` is one of the space-separated (and padded) `words`."""
    return words.find(" " + word + " ") >= 0


def _binary_swap(op: String) -> String:
    if op == "+":
        return "-"
    if op == "-":
        return "+"
    if op == "*":
        return "/"
    if op == "/":
        return "*"
    if op == "//":
        return "*"  # Int `/` truncates too, so `//` -> `/` is mostly equivalent
    if op == "%":
        return "/"
    if op == "**":
        return "*"
    if op == "<<":
        return ">>"
    if op == ">>":
        return "<<"
    if op == "&":
        return "|"
    if op == "|":
        return "&"
    if op == "^":
        return "&"
    return ""


def _comparison_swap(op: String) -> String:
    if op == "<":
        return "<="
    if op == "<=":
        return "<"
    if op == ">":
        return ">="
    if op == ">=":
        return ">"
    if op == "==":
        return "!="
    if op == "!=":
        return "=="
    return ""


def _augmented_swap(op: String) -> String:
    if op == "+=":
        return "-="
    if op == "-=":
        return "+="
    if op == "*=":
        return "/="
    if op == "/=":
        return "*="
    if op == "//=" or op == "%=":
        return "/="
    if op == "**=":
        return "*="
    if op == "<<=":
        return ">>="
    if op == ">>=":
        return "<<="
    if op == "&=":
        return "|="
    if op == "|=" or op == "^=":
        return "&="
    return ""


def _name_swap(name: String) -> String:
    if name == "True":
        return "False"
    if name == "False":
        return "True"
    if name == "and":
        return "or"
    if name == "or":
        return "and"
    if name == "break":
        return "continue"
    if name == "continue":
        return "break"
    return ""


def _call_swap(name: String) -> String:
    if name == "min":
        return "max"
    if name == "max":
        return "min"
    return ""


def _method_swap(name: String) -> String:
    comptime pairs = (
        " lower upper upper lower lstrip rstrip rstrip lstrip find rfind rfind find ljust rjust"
        " rjust ljust removeprefix removesuffix removesuffix removeprefix startswith endswith"
        " endswith startswith "
    )
    var words = String(pairs).split(" ")
    var i = 1
    while i + 1 < len(words):
        if words[i] == name:
            return String(words[i + 1])
        i += 2
    return ""


# Strings in these calls are messages for humans; mutating them mostly
# produces survivors nobody cares about.
comptime _MESSAGE_CALLS = " debug_assert abort print Error "
# Strings in the brackets after these name symbols: a mutant would compile
# and then fail to link.
comptime _SYMBOL_PARAMS = " external_call __mlir_attr __mlir_op __mlir_type "


@fieldwise_init
struct Mutation(Copyable, Movable):
    var line: Int  # 0-based physical line
    var col: Int
    var end_col: Int
    var original: String
    var replacement: String

    def describe(self) -> String:
        if self.replacement.byte_length() == 0:
            return "remove `" + self.original + "`"
        return "`" + self.original + "` -> `" + self.replacement + "`"


comptime DUP = 0  # the statement is duplicated per mutant behind an if/elif chain
comptime WRAP = 1  # the expression becomes a chain of ternaries, one per mutant
# `var x: T = e` becomes `var x: T` plus a duplicated `x = e`: a ternary would
# lose the declared type as context (a list literal for an `Array`, say).
# Untyped declarations stay ternaries: initializing in branches would confine
# the origin of a reference (a `Span`, say) to the branch.
comptime DECL = 2


struct Site(Copyable, Movable):
    """A statement holding mutations, and how the schemata switch between them.

    Declarations (`var x = ...`) can't be duplicated, since each copy would
    declare its own `x` in its own scope, so their expression is wrapped
    instead. Block headers (`if`, `for`, ...) can't be wrapped (a ternary
    would copy a non-copyable `for` iterable), so the whole compound
    statement is duplicated.
    """

    var kind: Int
    var first_line: Int  # physical lines of the statement, including nested blocks for DUP
    var last_line: Int
    var indent: String
    var nested: Bool  # inside a nested def, which can't see the function's despell_m_
    var mutations: List[Mutation]
    # WRAP: the expression's span
    var expr_line: Int
    var expr_col: Int
    var expr_end_line: Int
    var expr_end_col: Int
    # DECL: the name, its type, and the columns of `var` and `=` on first_line
    var decl_name: String
    var decl_type: String
    var decl_var_col: Int
    var decl_eq_col: Int
    # whether a coverage hook can go before the statement (not before `elif`)
    var hook: Bool

    def __init__(
        out self, kind: Int, first_line: Int, last_line: Int, indent: String, nested: Bool,
        var mutations: List[Mutation],
    ):
        self.kind = kind
        self.first_line = first_line
        self.last_line = last_line
        self.indent = indent
        self.nested = nested
        self.mutations = mutations^
        self.expr_line = -1
        self.expr_col = -1
        self.expr_end_line = -1
        self.expr_end_col = -1
        self.decl_name = String("")
        self.decl_type = String("")
        self.decl_var_col = -1
        self.decl_eq_col = -1
        self.hook = True


struct Function(Copyable, Movable):
    var qualname: String
    var def_line: Int  # 0-based physical line of `def`
    var body_start: Int  # 0-based first physical line of the mutable body
    var body_end: Int  # 0-based last physical line of the body (inclusive)
    var body_indent: String
    # whether the function produces a value, so must not fall off its end
    var has_result: Bool
    var sites: List[Site]

    def __init__(
        out self, qualname: String, def_line: Int, body_start: Int, body_end: Int, body_indent: String,
        has_result: Bool,
    ):
        self.qualname = qualname
        self.def_line = def_line
        self.body_start = body_start
        self.body_end = body_end
        self.body_indent = body_indent
        self.has_result = has_result
        self.sites = List[Site]()

    def mutations(self) -> List[Mutation]:
        var result = List[Mutation]()
        for site in self.sites:
            for m in site.mutations:
                result.append(m.copy())
        return result^


def _is_operand_end(toks: List[Token], i: Int) -> Bool:
    if i < 0 or i >= len(toks):
        return False
    ref tok = toks[i]
    if tok.kind == NUMBER or tok.kind == STRING:
        return True
    if tok.kind == NAME:
        return not _in(tok.text, _KEYWORDS)
    return tok.kind == OP and (tok.text == ")" or tok.text == "]" or tok.text == "}")


def _is_operand_start(toks: List[Token], i: Int) -> Bool:
    if i < 0 or i >= len(toks):
        return False
    ref tok = toks[i]
    if tok.kind == NUMBER or tok.kind == STRING:
        return True
    if tok.kind == NAME:
        return not _in(tok.text, _KEYWORDS) or tok.text == "not"
    return tok.kind == OP and _in(tok.text, " ( [ { - + ~ ")


def _all_digits(text: String) -> Bool:
    if text.byte_length() == 0:
        return False
    for b in text.as_bytes():
        if Int(b) < ord("0") or Int(b) > ord("9"):
            return False
    return True


def _increment_digits(digits: String, base: Int) -> String:
    """`digits` (in `base`) plus one, done on the text, for literals too big
    for an Int."""
    comptime symbols = "0123456789abcdef"
    var out = List[String]()
    var carry = True
    var bytes = digits.lower().as_bytes()
    for k in range(len(bytes) - 1, -1, -1):
        var v = String(symbols).find(String(chr(Int(bytes[k]))))
        if carry:
            v += 1
            carry = v == base
            if carry:
                v = 0
        out.append(String(String(symbols)[byte=v]))
    if carry:
        out.append("1")
    var result = String("")
    for k in range(len(out) - 1, -1, -1):
        result += out[k]
    return result^


def _mutate_number(text: String) -> String:
    """`text` plus one, or "" if it can't be read."""
    var clean = text.replace("_", "")
    var lower = clean.lower()
    try:
        if lower.startswith("0x") or lower.startswith("0b") or lower.startswith("0o"):
            var base = 16 if lower.startswith("0x") else (2 if lower.startswith("0b") else 8)
            var digits = String(clean[byte=2:])
            try:
                return String(atol(digits, base) + 1)
            except:
                return String(clean[byte=0:2]) + _increment_digits(digits, base)
        if "." in clean or "e" in lower:
            var value = atof(clean) + 1
            return String(value)
        return String(atol(clean) + 1)
    except:
        return String("")


def _mutate_string(text: String) -> String:
    """The string literal `text` with XX added inside, or "" for docstring
    style (triple-quoted) ones."""
    var bytes = text.as_bytes()
    var i = 0
    while Int(bytes[i]) != ord('"') and Int(bytes[i]) != ord("'"):
        i += 1
    var prefix = String(text[byte=0:i])
    var body = String(text[byte=i:])
    if body.startswith('"""') or body.startswith("'''"):
        return String("")
    var n = body.byte_length()
    var quote = String(body[byte=0:1])
    return prefix + quote + "XX" + String(body[byte=1 : n - 1]) + "XX" + quote


def _add(mut result: List[Mutation], toks: List[Token], i: Int, replacement: String, end: Int = -1):
    """A mutation replacing token `i` (through token `end`)."""
    var e = end if end >= 0 else i
    result.append(Mutation(toks[i].line, toks[i].col, toks[e].end_col, _token_text(toks, i, e), replacement))


def _token_text(toks: List[Token], start: Int, end: Int) -> String:
    if start == end:
        return toks[start].text
    if toks[start].end_col < toks[end].col:
        return toks[start].text + " " + toks[end].text
    return toks[start].text + toks[end].text


def mutations_for_logical_line(ll: LogicalLine) -> List[Mutation]:
    ref toks = ll.tokens
    var result = List[Mutation]()

    var message_line = toks[0].text == "raise" or toks[0].text == "assert"
    for t in toks:
        if t.kind == NAME and _in(t.text, _MESSAGE_CALLS):
            message_line = True

    # bracket depths at which a `for` is waiting for its `in`
    var pending_for = Set[Int]()
    var depth = 0
    # depth of the brackets after an `external_call` and the like, if inside
    var symbol_depth = -1
    var skip_next = False
    var n = len(toks)
    for i in range(n):
        ref tok = toks[i]
        var prev_text = toks[i - 1].text if i > 0 else String("")
        var next_text = toks[i + 1].text if i + 1 < n else String("")

        if tok.kind == OP and (tok.text == "(" or tok.text == "[" or tok.text == "{"):
            depth += 1
            if symbol_depth < 0 and tok.text == "[" and i > 0 and _in(prev_text, _SYMBOL_PARAMS):
                symbol_depth = depth
        elif tok.kind == OP and (tok.text == ")" or tok.text == "]" or tok.text == "}"):
            pending_for.discard(depth)
            if depth == symbol_depth:
                symbol_depth = -1
            depth -= 1

        if skip_next:
            skip_next = False
            continue

        if tok.kind == NUMBER:
            var new: String
            if prev_text == "[" and next_text == "]" and _all_digits(tok.text):
                # `x[1]` -> `x[0]` rather than `x[2]`: on a tuple, going past
                # the last element is an error only lowering catches, slowly
                try:
                    var value = atol(tok.text)
                    new = String(value - 1) if value > 0 else String("1")
                except:
                    new = String("")
            else:
                new = _mutate_number(tok.text)
            if new.byte_length():
                _add(result, toks, i, new)
        elif tok.kind == STRING:
            if not message_line and symbol_depth < 0 and tok.line == tok.end_line:
                var new = _mutate_string(tok.text)
                if new.byte_length():
                    _add(result, toks, i, new)
        elif tok.kind == NAME:
            var text = tok.text
            if text == "for":
                pending_for.add(depth)
            elif text == "in":
                if depth in pending_for:
                    pending_for.discard(depth)
                else:
                    _add(result, toks, i, "not in")
            elif text == "not":
                if next_text == "in":
                    _add(result, toks, i, "in", end=i + 1)
                    skip_next = True
                else:
                    _add(result, toks, i, "")
            elif text == "is":
                if next_text == "not":
                    _add(result, toks, i, "is", end=i + 1)
                    skip_next = True
                else:
                    _add(result, toks, i, "is not")
            elif _name_swap(text).byte_length():
                _add(result, toks, i, _name_swap(text))
            elif _call_swap(text).byte_length() and next_text == "(" and prev_text != ".":
                _add(result, toks, i, _call_swap(text))
            elif _method_swap(text).byte_length() and prev_text == "." and next_text == "(":
                _add(result, toks, i, _method_swap(text))
        elif tok.kind == OP:
            var text = tok.text
            if _comparison_swap(text).byte_length():
                _add(result, toks, i, _comparison_swap(text))
            elif _augmented_swap(text).byte_length() and depth == 0:
                _add(result, toks, i, _augmented_swap(text))
                _add(result, toks, i, "=")
            elif _binary_swap(text).byte_length():
                if _is_operand_end(toks, i - 1):
                    if _is_operand_start(toks, i + 1):
                        _add(result, toks, i, _binary_swap(text))
                elif text == "-" and _is_operand_start(toks, i + 1):
                    _add(result, toks, i, "")  # unary minus
            elif text == "~" and _is_operand_start(toks, i + 1):
                _add(result, toks, i, "")
    return result^


def _has_pragma(src: TokenizedSource, line: Int) -> Bool:
    ref text = src.lines[line]
    return "#" in text and ("pragma: no mutate" in text or "despell: skip" in text)


def _skip_body(body: List[LogicalLine]) -> Bool:
    return len(body) == 1 and len(body[0].tokens) == 1 and (body[0].tokens[0].text == "..." or body[0].tokens[0].text == "pass")


def _has_result(header: LogicalLine) -> Bool:
    var depth = 0
    ref toks = header.tokens
    for i in range(len(toks)):
        ref t = toks[i].text
        if t == "(" or t == "[" or t == "{":
            depth += 1
        elif t == ")" or t == "]" or t == "}":
            depth -= 1
        elif depth == 0 and t == "->":
            return not (i + 2 < len(toks) and toks[i + 1].text == "None" and toks[i + 2].text == ":")
    return False


# Lines that are never mutated: compile-time code, declarations of nested
# things, and statements whose strings are messages.
comptime _UNMUTATED_STARTS = " comptime alias @ def fn struct trait raise else try except finally match case pass "


def _continuations(header: String) -> String:
    """The clauses that continue a compound statement (`elif`, `else`)."""
    if header == "if":
        return " elif else "
    if header == "for" or header == "while":
        return " else "
    return " "


def _is_compound(word: String) -> Bool:
    return word == "if" or word == "for" or word == "while" or word == "with"


def _statement_end(body: List[LogicalLine], i: Int) -> Int:
    """Index of the last logical line of the compound statement starting at i."""
    var indent = body[i].indent
    var continuations = _continuations(body[i].tokens[0].text)
    var j = i + 1
    while j < len(body) and body[j].indent > indent:
        j += 1
    while j < len(body) and body[j].indent == indent and _in(body[j].tokens[0].text, continuations):
        j += 1
        while j < len(body) and body[j].indent > indent:
            j += 1
    return j - 1


def _depth0_index(toks: List[Token], text: String) -> Int:
    var depth = 0
    for i in range(len(toks)):
        ref t = toks[i].text
        if t == "(" or t == "[" or t == "{":
            depth += 1
        elif t == ")" or t == "]" or t == "}":
            depth -= 1
        elif depth == 0 and t == text:
            return i
    return -1


def _make_site(
    src: TokenizedSource, body: List[LogicalLine], i: Int, mutations: List[Mutation], nested: Bool
) -> Optional[Site]:
    ref ll = body[i]
    ref toks = ll.tokens
    var first = toks[0].text
    var indent = String(src.lines[ll.first_line][byte=0 : ll.indent])
    if _in(first, _UNMUTATED_STARTS):
        return None
    if _depth0_index(toks, ";") >= 0:
        return None  # several statements on one line
    if i > 0 and body[i - 1].tokens[0].text == "@":
        return None  # e.g. `@parameter if`: compile-time
    var ends_block = toks[len(toks) - 1].text == ":"

    if _is_compound(first):
        if not ends_block:
            return None  # body on the same line
        var end_index = _statement_end(body, i)
        for j in range(i + 1, end_index + 1):
            var w = body[j].tokens[0].text
            if w == "def" or w == "fn" or w == "struct":
                return None  # a copy would declare them again
        return Site(DUP, ll.first_line, body[end_index].last_line, indent, nested, mutations.copy())

    var expr_start: Int
    var expr_end: Int  # inclusive
    var eq = -1
    if first == "elif":
        if not ends_block:
            return None
        expr_start = 1
        expr_end = len(toks) - 2
    elif first == "var" or first == "ref":
        eq = _depth0_index(toks, "=")
        if eq < 0 or eq + 1 >= len(toks):
            return None
        expr_start = eq + 1
        expr_end = len(toks) - 1
    elif ends_block:
        return None
    else:
        return Site(DUP, ll.first_line, ll.last_line, indent, nested, mutations.copy())

    var sl = toks[expr_start].line
    var sc = toks[expr_start].col
    var el = toks[expr_end].end_line
    var ec = toks[expr_end].end_col
    var inside = List[Mutation]()
    for m in mutations:
        var after_start = m.line > sl or (m.line == sl and m.col >= sc)
        var before_end = m.line < el or (m.line == el and m.end_col <= ec)
        if after_start and before_end:
            inside.append(m.copy())
    if len(inside) == 0:
        return None
    if first == "var" and toks[1].kind == NAME and toks[eq].line == toks[0].line and toks[2].text == ":":
        var site = Site(DECL, ll.first_line, ll.last_line, indent, nested, inside^)
        site.decl_name = toks[1].text
        site.decl_type = String(String(src.lines[ll.first_line][byte = toks[2].end_col : toks[eq].col]).strip())
        site.decl_var_col = toks[0].col
        site.decl_eq_col = toks[eq].col
        return site^
    var site = Site(WRAP, ll.first_line, ll.last_line, indent, nested, inside^)
    site.expr_line = sl
    site.expr_col = sc
    site.expr_end_line = el
    site.expr_end_col = ec
    site.hook = first != "elif"
    return site^


@fieldwise_init
struct _Scope(Copyable, Movable):
    var indent: Int
    var name: String
    var is_def: Bool


def find_functions(src: TokenizedSource) -> List[Function]:
    ref lls = src.logical_lines
    var functions = List[Function]()
    var stack = List[_Scope]()
    for idx in range(len(lls)):
        ref ll = lls[idx]
        while len(stack) > 0 and stack[len(stack) - 1].indent >= ll.indent:
            _ = stack.pop()
        ref first = ll.tokens[0]
        if first.kind != NAME or len(ll.tokens) < 2:
            continue
        if first.text == "struct" or first.text == "trait":
            stack.append(_Scope(ll.indent, ll.tokens[1].text, False))
            continue
        if first.text != "def" and first.text != "fn":
            continue
        var name = ll.tokens[1].text
        var nested = False
        var qualname = String("")
        for s in stack:
            if s.is_def:
                nested = True
            qualname += s.name + "."
        qualname += name
        stack.append(_Scope(ll.indent, name, True))
        if nested:
            continue
        if ll.tokens[len(ll.tokens) - 1].text != ":":
            continue  # declaration without body, or a body on the same line
        var pragma = False
        for line in range(ll.first_line, ll.last_line + 1):
            if _has_pragma(src, line):
                pragma = True
        if pragma:
            continue

        var body = List[LogicalLine]()
        for j in range(idx + 1, len(lls)):
            if lls[j].indent <= ll.indent:
                break
            body.append(lls[j].copy())
        if len(body) == 0:
            continue
        if body[0].tokens[0].kind == STRING and len(body[0].tokens) == 1:
            _ = body.pop(0)  # docstring stays above the dispatch
        if len(body) == 0 or _skip_body(body):
            continue

        var f = Function(
            qualname,
            ll.first_line,
            body[0].first_line,
            body[len(body) - 1].last_line,
            String(src.lines[body[0].first_line][byte = 0 : body[0].indent]),
            _has_result(ll),
        )
        var nested_defs = List[Int]()  # indents of enclosing nested defs
        for i in range(len(body)):
            ref b = body[i]
            while len(nested_defs) > 0 and b.indent <= nested_defs[len(nested_defs) - 1]:
                _ = nested_defs.pop()
            if b.tokens[0].text == "def" or b.tokens[0].text == "fn":
                nested_defs.append(b.indent)
                continue
            var pragma_line = False
            for line in range(b.first_line, b.last_line + 1):
                if _has_pragma(src, line):
                    pragma_line = True
            if pragma_line:
                continue
            var mutations = mutations_for_logical_line(b)
            if len(mutations) > 0:
                var site = _make_site(src, body, i, mutations, len(nested_defs) > 0)
                if site:
                    f.sites.append(site.value().copy())
        if len(f.sites) > 0:
            functions.append(f^)
    return functions^


def analyze(source: String) raises -> List[Function]:
    return find_functions(tokenize(source))


comptime RUNTIME_HEADER = """from std.ffi import _Global as _DespellGlobal
from std.os import getenv as _despell_getenv
from std.os import abort as _despell_abort


def _despell_init_mutant() -> Int:
    try:
        return Int(_despell_getenv("DESPELL_MUTANT", "0"))
    except:
        return 0


def _despell_init_hits() -> List[Bool]:
    return List[Bool](length=N_FUNCTIONS, fill=False)


comptime _despell_mutant = _DespellGlobal["despell_mutant", _despell_init_mutant]
comptime _despell_hits = _DespellGlobal["despell_hits", _despell_init_hits]


def _despell_init_sites() -> List[Bool]:
    return List[Bool](length=N_MUTANTS, fill=False)


comptime _despell_sites = _DespellGlobal["despell_sites", _despell_init_sites]


def _despell_site(key: Int):
    \"\"\"Records that a statement holding mutants ran, in coverage mode.\"\"\"
    try:
        var hits = _despell_sites.get_or_create_ptr()
        if not hits[][key]:
            hits[][key] = True
            print("despell-site", key)
    except:
        pass


def _despell_active(fid: Int) -> Int:
    # code evaluated at compile time runs unmutated: globals don't exist there
    if __is_run_in_comptime_interpreter:
        return 0
    try:
        var m = _despell_mutant.get_or_create_ptr()[]
        if m == -1:
            var hits = _despell_hits.get_or_create_ptr()
            if not hits[][fid]:
                hits[][fid] = True
                # print rather than file I/O: the program already uses print,
                # while extra FFI could clash with the user's own declarations
                print("despell-hit", fid)
        return m
    except:
        return 0

"""


struct Region(Copyable, Movable):
    """Maps a range of generated lines back to what produced them."""

    var start: Int  # 0-based, inclusive
    var end: Int  # 0-based, inclusive
    var fid: Int
    var mutant: Int  # the lines of one mutant (-1: not)
    var site: List[Int]  # the lines of a statement holding these mutants
    var orig_start: Int  # the source lines of that statement (-1: none)
    var orig_end: Int
    # with neither mutant nor site: the function's own dispatch lines

    def __init__(out self, start: Int, end: Int, fid: Int, mutant: Int = -1, orig_start: Int = -1, orig_end: Int = -1):
        self.start = start
        self.end = end
        self.fid = fid
        self.mutant = mutant
        self.site = List[Int]()
        self.orig_start = orig_start
        self.orig_end = orig_end


@fieldwise_init
struct GeneratedMutant(Copyable, Movable):
    var number: Int
    var fid: Int
    var index: Int  # 1-based index within the function
    var mutation: Mutation


@fieldwise_init
struct GeneratedFunction(Copyable, Movable):
    var fid: Int
    var qualname: String
    var def_line: Int
    var mutants: List[GeneratedMutant]


@fieldwise_init
struct GeneratedFile(Copyable, Movable):
    var text: String
    var regions: List[Region]
    var functions: List[GeneratedFunction]


def _apply(lines: List[String], m: Mutation) -> List[String]:
    var result = lines.copy()
    ref line = lines[m.line]
    result[m.line] = String(line[byte = 0 : m.col]) + m.replacement + String(line[byte = m.end_col :])
    return result^


def _module_docstring_end(src: TokenizedSource) -> Int:
    """Physical line after which the runtime header may be inserted."""
    ref lls = src.logical_lines
    if len(lls) > 0 and lls[0].indent == 0 and lls[0].tokens[0].kind == STRING and len(lls[0].tokens) == 1:
        return lls[0].last_line + 1
    return 0


def _indented(depth: Int) -> String:
    var s = String("")
    for _ in range(depth):
        s += INDENT
    return s^


def _is_blank(line: String) -> Bool:
    return String(line.strip()).byte_length() == 0


def _copy_lines(
    mut out: List[String], lines: List[String], in_string_lines: Set[Int], start: Int, end: Int, depth: Int
):
    for i in range(start, end + 1):
        ref line = lines[i]
        if i in in_string_lines or _is_blank(line):
            out.append(line)
        else:
            out.append(_indented(depth) + line)


@fieldwise_init
struct _ActiveSite(Copyable, Movable):
    var site: Site
    var active: List[GeneratedMutant]
    var key: Int  # the number of the site's first mutant, for coverage


struct _Emitter:
    var in_string_lines: Set[Int]
    var lines: List[String]
    var out: List[String]  # one generated line per entry
    var regions: List[Region]
    var sites: List[_ActiveSite]  # of the function being emitted
    var fid: Int

    def __init__(out self, in_string_lines: Set[Int], lines: List[String]):
        self.in_string_lines = in_string_lines.copy()
        self.lines = lines.copy()
        self.out = List[String]()
        self.regions = List[Region]()
        self.sites = List[_ActiveSite]()
        self.fid = 0

    def mvar(self, site: Site) -> String:
        # a nested def can't capture despell_m_ unless it's a closure
        return "_despell_active(" + String(self.fid) + ")" if site.nested else String("despell_m_")

    def copy(mut self, lines: List[String], start: Int, end: Int, depth: Int):
        """Copy physical lines, indented `depth` levels deeper."""
        _copy_lines(self.out, lines, self.in_string_lines, start, end, depth)

    def copy_own(mut self, start: Int, end: Int, depth: Int):
        """`copy` of the source lines themselves."""
        _copy_lines(self.out, self.lines, self.in_string_lines, start, end, depth)

    def add_lines(mut self, text: String):
        """Add `text`, which may hold several lines, one line per entry."""
        for line in text.splitlines(keepends=True):
            self.out.append(String(line))

    def span(self, lines: List[String], sl: Int, sc: Int, el: Int, ec: Int, depth: Int) -> String:
        """The text from (sl, sc) to (el, ec), its later lines indented `depth`
        levels deeper: Mojo rejects a continuation line, even in brackets,
        that's dedented past the block it's in."""
        if sl == el:
            return String(lines[sl][byte=sc:ec])
        var text = String(lines[sl][byte=sc:])
        for i in range(sl + 1, el + 1):
            var line = lines[i] if i < el else String(lines[el][byte=0:ec])
            if i in self.in_string_lines or (i < el and _is_blank(line)):
                text += line
            else:
                text += _indented(depth) + line
        return text^

    def emit_range(mut self, start: Int, end: Int, depth: Int, indices: List[Int]):
        var pos = start
        for k in indices:
            var site = self.sites[k].site.copy()
            if site.first_line < pos or site.first_line > end:
                continue
            self.copy_own(pos, site.first_line - 1, depth)
            if site.hook:
                # coverage per statement: a test that doesn't run it can't
                # kill its mutants
                var ind = _indented(depth) + site.indent
                self.out.append(ind + "if " + self.mvar(site) + " == -1:\n")
                self.out.append(ind + INDENT + "_despell_site(" + String(self.sites[k].key) + ")\n")
            var others = List[Int]()
            for o in indices:
                if o != k:
                    others.append(o)
            if len(self.sites[k].active) == 0:
                # only here for its coverage hook
                if site.kind == DUP:
                    self.emit_range(site.first_line, site.last_line, depth, others)
                else:
                    self.copy_own(site.first_line, site.last_line, depth)
            elif site.kind == DUP:
                self.emit_dup(k, depth, others)
            elif site.kind == DECL:
                self.emit_decl(k, depth)
            else:
                self.emit_wrap(k, depth)
            pos = site.last_line + 1
        self.copy_own(pos, end, depth)

    def _site_region(mut self, start: Int, k: Int):
        ref site = self.sites[k].site
        var region = Region(start, len(self.out) - 1, self.fid, -1, site.first_line, site.last_line)
        for gm in self.sites[k].active:
            region.site.append(gm.number)
        self.regions.append(region^)

    def emit_dup(mut self, k: Int, depth: Int, others: List[Int]):
        var site = self.sites[k].site.copy()
        var active = self.sites[k].active.copy()
        var ind = _indented(depth) + site.indent
        var start = len(self.out)
        for j in range(len(active)):
            var keyword = String("if") if j == 0 else String("elif")
            self.out.append(ind + keyword + " " + self.mvar(site) + " == " + String(active[j].number) + ":\n")
            var first = len(self.out)
            self.copy(_apply(self.lines, active[j].mutation), site.first_line, site.last_line, depth + 1)
            self.regions.append(Region(first, len(self.out) - 1, self.fid, active[j].number, site.first_line, site.last_line))
        self.out.append(ind + "else:\n")
        # only one mutant is active at a time, so statements inside this one
        # need their own dispatch only in the original copy
        self.emit_range(site.first_line, site.last_line, depth + 1, others)
        self._site_region(start, k)

    def emit_decl(mut self, k: Int, depth: Int):
        var site = self.sites[k].site.copy()
        var active = self.sites[k].active.copy()
        var ind = _indented(depth) + site.indent
        var start = len(self.out)
        self.add_lines(ind + "var " + site.decl_name + ": " + site.decl_type + "\n")
        for j in range(len(active)):
            var keyword = String("if") if j == 0 else String("elif")
            self.out.append(ind + keyword + " " + self.mvar(site) + " == " + String(active[j].number) + ":\n")
            var first = len(self.out)
            self.copy(_assignment(_apply(self.lines, active[j].mutation), site), site.first_line, site.last_line, depth + 1)
            self.regions.append(Region(first, len(self.out) - 1, self.fid, active[j].number, site.first_line, site.last_line))
        self.out.append(ind + "else:\n")
        self.copy(_assignment(self.lines, site), site.first_line, site.last_line, depth + 1)
        self._site_region(start, k)

    def emit_wrap(mut self, k: Int, depth: Int):
        var site = self.sites[k].site.copy()
        var active = self.sites[k].active.copy()
        var sl = site.expr_line
        var sc = site.expr_col
        var el = site.expr_end_line
        var ec = site.expr_end_col
        var start = len(self.out)
        self.copy_own(site.first_line, sl - 1, depth)
        self.out.append(_indented(depth) + String(self.lines[sl][byte=0:sc]) + "(\n")
        var cont = _indented(depth + 2) + site.indent
        for gm in active:
            ref m = gm.mutation
            var mutated = _apply(self.lines, m)
            var m_ec = ec + m.replacement.byte_length() - (m.end_col - m.col) if m.line == el else ec
            var expr = self.span(mutated, sl, sc, el, m_ec, depth)
            var first = len(self.out)
            self.add_lines(cont + "(" + expr + ") if " + self.mvar(site) + " == " + String(gm.number) + " else\n")
            self.regions.append(Region(first, len(self.out) - 1, self.fid, gm.number, site.first_line, site.last_line))
        var tail = String(self.lines[el][byte=ec:])
        self.add_lines(cont + "(" + self.span(self.lines, sl, sc, el, ec, depth) + "))" + tail)
        self.copy_own(el + 1, site.last_line, depth)
        self._site_region(start, k)


def _assignment(lines: List[String], site: Site) -> List[String]:
    """`var x: T = e` turned into `x = e` (the mutation is after the `=`, so
    the columns still hold)."""
    var result = lines.copy()
    ref line = lines[site.first_line]
    result[site.first_line] = (
        String(line[byte = 0 : site.decl_var_col]) + site.decl_name + " " + String(line[byte = site.decl_eq_col :])
    )
    return result^


def _inline_decorator(lines: List[String], def_line: Int) -> Int:
    """The line of an inlining decorator on the function at `def_line`, or -1."""
    var i = def_line - 1
    while i >= 0 and String(lines[i].strip()).startswith("@"):
        if "inline" in lines[i]:
            return i
        i -= 1
    return -1


def generate(
    source: String,
    functions: List[Function],
    first_fid: Int,
    first_mutant: Int,
    n_functions_total: Int,
    n_mutants_total: Int = 0,
    enabled: Optional[Set[Int]] = None,
    disabled_functions: Set[Int] = Set[Int](),
    dispatch_only: Set[Int] = Set[Int](),
    no_inline: Bool = False,
    hooks_everywhere: Bool = False,
) raises -> GeneratedFile:
    """Emit the schemata version of a file.

    Mutant numbers and fids are assigned sequentially from `first_mutant` and
    `first_fid` regardless of `enabled` (None: all), so numbering is stable
    while mutants are dropped for not compiling. Functions in `dispatch_only`
    get their dispatch even without active mutants, to check that it
    compiles. With `hooks_everywhere`, every statement that holds mutants
    records coverage, active or not, so coverage doesn't depend on which
    mutants a build holds.
    """
    var src = tokenize(source)
    var lines = src.lines.copy()
    if len(lines) > 0 and not lines[len(lines) - 1].endswith("\n"):
        lines[len(lines) - 1] = lines[len(lines) - 1] + "\n"

    var em = _Emitter(src.in_string_lines, lines)
    var gen_functions = List[GeneratedFunction]()

    var insert_at = _module_docstring_end(src)
    for i in range(insert_at):
        em.out.append(lines[i])
    var header = String(RUNTIME_HEADER).replace("N_FUNCTIONS", String(max(n_functions_total, 1))).replace(
        "N_MUTANTS", String(max(n_mutants_total, 1))
    )
    em.add_lines(header)
    var pos = insert_at

    var fid = first_fid
    var number = first_mutant
    for f in functions:
        var gen_mutants = List[GeneratedMutant]()
        em.sites = List[_ActiveSite]()
        for site in f.sites:
            var key = number
            var active = List[GeneratedMutant]()
            for m in site.mutations:
                var gm = GeneratedMutant(number, fid, len(gen_mutants) + 1, m.copy())
                gen_mutants.append(gm.copy())
                if not enabled or number in enabled.value():
                    active.append(gm^)
                number += 1
            if len(active) > 0 or hooks_everywhere:
                em.sites.append(_ActiveSite(site.copy(), active^, key))
        gen_functions.append(GeneratedFunction(fid, f.qualname, f.def_line, gen_mutants^))

        for i in range(pos, f.def_line):
            em.out.append(lines[i])
        var has_active = False
        for a in em.sites:
            if len(a.active) > 0:
                has_active = True
        if no_inline and has_active and not (fid in disabled_functions):
            # Inlining functions that hold all their mutants into each other
            # multiplies code size along call chains, which can make LLVM take
            # many times longer than for the functions separately. A plain
            # `@always_inline` only affects speed, so it's replaced; any other
            # inline decorator is left alone.
            var decorator = _inline_decorator(lines, f.def_line)
            if decorator < 0:
                var def_text = lines[f.def_line]
                var def_indent = String(def_text[byte = 0 : def_text.byte_length() - String(def_text.lstrip()).byte_length()])
                em.out.append(def_indent + "@inline(.never)\n")
            elif String(lines[decorator].strip()) == "@always_inline":
                em.out[len(em.out) - (f.def_line - decorator)] = lines[decorator].replace("@always_inline", "@inline(.never)")
        var def_line_out = len(em.out)
        for i in range(f.def_line, f.body_start):
            em.out.append(lines[i])
        pos = f.body_end + 1
        if fid in disabled_functions or len(em.sites) == 0:
            if fid in dispatch_only and not (fid in disabled_functions):
                em.out.append(f.body_indent + "_ = _despell_active(" + String(fid) + ")\n")
                em.regions.append(Region(def_line_out, len(em.out) - 1, fid))
            for i in range(f.body_start, f.body_end + 1):
                em.out.append(lines[i])
            fid += 1
            continue

        em.fid = fid
        em.out.append(f.body_indent + "var despell_m_ = _despell_active(" + String(fid) + ")\n")
        var all_sites = List[Int]()
        for k in range(len(em.sites)):
            all_sites.append(k)
        em.emit_range(f.body_start, f.body_end, 0, all_sites)
        if f.has_result and has_active:
            # A mutant can make the end of the body reachable (`while True`
            # -> `while False`), which Mojo would reject for the whole function.
            em.out.append(f.body_indent + '_despell_abort("despell: a mutant fell off the end of ' + f.qualname + '")\n')
        # errors on the `def` line, like a missing return, belong to the function
        em.regions.append(Region(def_line_out, len(em.out) - 1, fid))
        fid += 1

    for i in range(pos, len(lines)):
        em.out.append(lines[i])
    var text = String("")
    for line in em.out:
        text += line
    var regions = List[Region]()
    swap(regions, em.regions)
    return GeneratedFile(text^, regions^, gen_functions^)
