"""Find functions in Mojo source, generate mutants, and emit mutation schemata.

Every mutated function body is replaced with a dispatch on the active mutant:

    def f(a: Int) -> Int:
        var despell_m_ = _despell_active(FID)
        if despell_m_ == 17:
            <body with mutation 17>
        elif despell_m_ == 18:
            <body with mutation 18>
        else:
            <original body>

Inlining the variants (instead of trampolining to renamed copies like mutmut)
means we never have to forward arguments, which in Mojo would mean dealing
with argument conventions, parameters, `out self` and so on.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .tokenizer import NAME, NUMBER, OP, STRING, LogicalLine, Token, TokenizedSource, tokenize

INDENT = "    "

KEYWORDS = {
    "and", "or", "not", "in", "is", "if", "elif", "else", "for", "while", "return",
    "raise", "def", "fn", "var", "ref", "comptime", "alias", "struct", "trait", "with",
    "as", "try", "except", "finally", "pass", "break", "continue", "from", "import",
    "out", "mut", "owned", "deinit", "read", "raises", "lambda", "yield", "assert",
}

PRAGMAS = ("pragma: no mutate", "despell: skip")

_BINARY_OPS = {
    "+": "-",
    "-": "+",
    "*": "/",
    "/": "*",
    "//": "*",  # Int `/` truncates too, so `//` -> `/` is mostly equivalent
    "%": "/",
    "**": "*",
    "<<": ">>",
    ">>": "<<",
    "&": "|",
    "|": "&",
    "^": "&",
}

_COMPARISON_OPS = {
    "<": "<=",
    "<=": "<",
    ">": ">=",
    ">=": ">",
    "==": "!=",
    "!=": "==",
}

_AUGMENTED_OPS = {
    "+=": "-=",
    "-=": "+=",
    "*=": "/=",
    "/=": "*=",
    "//=": "/=",
    "%=": "/=",
    "**=": "*=",
    "<<=": ">>=",
    ">>=": "<<=",
    "&=": "|=",
    "|=": "&=",
    "^=": "&=",
}

_NAME_SWAPS = {
    "True": "False",
    "False": "True",
    "and": "or",
    "or": "and",
    "break": "continue",
    "continue": "break",
}

_CALL_SWAPS = {"min": "max", "max": "min"}

_METHOD_SWAPS = {
    "lower": "upper",
    "upper": "lower",
    "lstrip": "rstrip",
    "rstrip": "lstrip",
    "find": "rfind",
    "rfind": "find",
    "ljust": "rjust",
    "rjust": "ljust",
    "removeprefix": "removesuffix",
    "removesuffix": "removeprefix",
    "startswith": "endswith",
    "endswith": "startswith",
}

# Strings in these contexts are messages for humans; mutating them mostly
# produces survivors nobody cares about.
_MESSAGE_CALLS = {"debug_assert", "abort", "print", "Error"}


@dataclass
class Mutation:
    line: int  # 0-based physical line
    col: int
    end_col: int
    original: str
    replacement: str

    def describe(self) -> str:
        if self.replacement == "":
            return f"remove `{self.original}`"
        return f"`{self.original}` -> `{self.replacement}`"


DUP = "dup"  # the statement is duplicated per mutant behind an if/elif chain
WRAP = "wrap"  # the expression becomes a chain of ternaries, one per mutant
# `var x: T = e` becomes `var x: T` plus a duplicated `x = e`: a ternary would
# lose the declared type as context (a list literal for an `Array`, say).
# Untyped declarations stay ternaries: initializing in branches would confine
# the origin of a reference (a `Span`, say) to the branch.
DECL = "decl"


@dataclass
class Site:
    """A statement holding mutations, and how the schemata switch between them.

    Only the statement is duplicated, never the whole function, so the
    generated code grows linearly with the number of mutants. Declarations
    (`var x = ...`) can't be duplicated, since each copy would declare its own
    `x` in its own scope, so their expression is wrapped instead. Block headers
    (`if`, `for`, ...) can't be wrapped (a ternary would copy a non-copyable
    `for` iterable), so the whole compound statement is duplicated.
    """

    kind: str
    first_line: int  # physical lines of the statement, including nested blocks for DUP
    last_line: int
    indent: str
    nested: bool  # inside a nested def, which can't see the function's despell_m_
    mutations: list[Mutation]
    expr: tuple[int, int, int, int] | None = None  # WRAP: (line, col, end_line, end_col)
    # DECL: the name, its type, and the columns of `var` and `=` on first_line
    decl: tuple[str, str, int, int] | None = None


@dataclass
class Function:
    qualname: str
    def_line: int  # 0-based physical line of `def`
    body_start: int  # 0-based first physical line of the mutable body
    body_end: int  # 0-based last physical line of the body (inclusive)
    body_indent: str
    # whether the function produces a value, so must not fall off its end
    has_result: bool = False
    sites: list[Site] = field(default_factory=list)

    @property
    def mutations(self) -> list[Mutation]:
        return [m for site in self.sites for m in site.mutations]


def _is_operand_end(tok: Token | None) -> bool:
    if tok is None:
        return False
    if tok.kind in (NUMBER, STRING):
        return True
    if tok.kind == NAME:
        return tok.text not in KEYWORDS
    return tok.kind == OP and tok.text in (")", "]", "}")


def _is_operand_start(tok: Token | None) -> bool:
    if tok is None:
        return False
    if tok.kind in (NUMBER, STRING):
        return True
    if tok.kind == NAME:
        return tok.text not in KEYWORDS or tok.text == "not"
    return tok.kind == OP and tok.text in ("(", "[", "{", "-", "+", "~")


def _mutate_number(text: str) -> str | None:
    clean = text.replace("_", "")
    try:
        if clean[:2].lower() in ("0x", "0b", "0o"):
            return str(int(clean, 0) + 1)
        if any(c in clean for c in ".eE"):
            return repr(float(clean) + 1)
        return str(int(clean, 10) + 1)
    except ValueError:
        return None


def _mutate_string(text: str) -> str | None:
    i = 0
    while text[i] not in "\"'":
        i += 1
    prefix, body = text[:i], text[i:]
    if body.startswith('"""') or body.startswith("'''"):
        return None
    return f"{prefix}{body[0]}XX{body[1:-1]}XX{body[-1]}"


def mutations_for_logical_line(ll: LogicalLine) -> list[Mutation]:
    toks = ll.tokens
    result: list[Mutation] = []

    def add(tok: Token, replacement: str, *, end_tok: Token | None = None):
        end = end_tok or tok
        assert end.end_line == tok.line
        result.append(Mutation(tok.line, tok.col, end.end_col, ll_text(tok, end), replacement))

    def ll_text(start: Token, end: Token) -> str:
        if start is end:
            return start.text
        return f"{start.text} {end.text}" if start.end_col < end.col else start.text + end.text

    message_line = toks[0].text in ("raise", "assert") or any(
        t.kind == NAME and t.text in _MESSAGE_CALLS for t in toks
    )

    # bracket depth at which a `for` is waiting for its `in`
    pending_for: set[int] = set()
    depth = 0
    skip_next = False
    for i, tok in enumerate(toks):
        prev = toks[i - 1] if i > 0 else None
        nxt = toks[i + 1] if i + 1 < len(toks) else None

        if tok.kind == OP and tok.text in "([{":
            depth += 1
        elif tok.kind == OP and tok.text in ")]}":
            pending_for.discard(depth)
            depth -= 1

        if skip_next:
            skip_next = False
            continue

        if tok.kind == NUMBER:
            if prev is not None and prev.text == "[" and nxt is not None and nxt.text == "]" and tok.text.isdigit():
                # `x[1]` -> `x[0]` rather than `x[2]`: on a tuple, going past
                # the last element is an error only lowering catches, slowly
                new = str(int(tok.text) - 1) if int(tok.text) > 0 else "1"
            else:
                new = _mutate_number(tok.text)
            if new is not None:
                add(tok, new)
        elif tok.kind == STRING:
            if not message_line:
                new = _mutate_string(tok.text)
                if new is not None and tok.line == tok.end_line:
                    add(tok, new)
        elif tok.kind == NAME:
            text = tok.text
            if text == "for":
                pending_for.add(depth)
            elif text == "in":
                if depth in pending_for:
                    pending_for.discard(depth)
                else:
                    add(tok, "not in")
            elif text == "not":
                if nxt is not None and nxt.text == "in":
                    add(tok, "in", end_tok=nxt)
                    skip_next = True
                else:
                    add(tok, "")
            elif text == "is":
                if nxt is not None and nxt.text == "not":
                    add(tok, "is", end_tok=nxt)
                    skip_next = True
                else:
                    add(tok, "is not")
            elif text in _NAME_SWAPS:
                add(tok, _NAME_SWAPS[text])
            elif text in _CALL_SWAPS and nxt is not None and nxt.text == "(" and (prev is None or prev.text != "."):
                add(tok, _CALL_SWAPS[text])
            elif text in _METHOD_SWAPS and prev is not None and prev.text == "." and nxt is not None and nxt.text == "(":
                add(tok, _METHOD_SWAPS[text])
        elif tok.kind == OP:
            text = tok.text
            if text in _COMPARISON_OPS:
                add(tok, _COMPARISON_OPS[text])
            elif text in _AUGMENTED_OPS and depth == 0:
                add(tok, _AUGMENTED_OPS[text])
                add(tok, "=")
            elif text in _BINARY_OPS:
                if _is_operand_end(prev):
                    if _is_operand_start(nxt):
                        add(tok, _BINARY_OPS[text])
                elif text == "-" and _is_operand_start(nxt):
                    add(tok, "")  # unary minus
            elif text == "~" and _is_operand_start(nxt):
                add(tok, "")
    return result


def _has_pragma(src: TokenizedSource, line: int) -> bool:
    text = src.lines[line]
    return "#" in text and any(p in text for p in PRAGMAS)


def _skip_body(body: list[LogicalLine]) -> bool:
    return len(body) == 1 and len(body[0].tokens) == 1 and body[0].first.text in ("...", "pass")


def _has_result(header: LogicalLine) -> bool:
    depth = 0
    toks = header.tokens
    for i, tok in enumerate(toks):
        if tok.text in ("(", "[", "{"):
            depth += 1
        elif tok.text in (")", "]", "}"):
            depth -= 1
        elif depth == 0 and tok.text == "->":
            return not (toks[i + 1].text == "None" and toks[i + 2].text == ":")
    return False


# Lines that are never mutated: compile-time code, declarations of nested
# things, and statements whose strings are messages.
_UNMUTATED_STARTS = {
    "comptime", "alias", "@", "def", "fn", "struct", "trait", "raise", "else", "try",
    "except", "finally", "match", "case", "pass",
}
_COMPOUND = {"if": ("elif", "else"), "for": ("else",), "while": ("else",), "with": ()}


def _statement_end(body: list[LogicalLine], i: int) -> int:
    """Index of the last logical line of the compound statement starting at i."""
    header = body[i]

    def block_end(j: int) -> int:
        while j < len(body) and body[j].indent > header.indent:
            j += 1
        return j

    j = block_end(i + 1)
    continuations = _COMPOUND[header.first.text]
    while j < len(body) and body[j].indent == header.indent and body[j].first.text in continuations:
        j = block_end(j + 1)
    return j - 1


def _depth0_index(toks: list[Token], text: str) -> int | None:
    depth = 0
    for i, tok in enumerate(toks):
        if tok.text in ("(", "[", "{"):
            depth += 1
        elif tok.text in (")", "]", "}"):
            depth -= 1
        elif depth == 0 and tok.text == text:
            return i
    return None


def _make_site(
    src: TokenizedSource, body: list[LogicalLine], i: int, mutations: list[Mutation], nested: bool
) -> Site | None:
    ll = body[i]
    toks = ll.tokens
    first = toks[0].text
    indent = src.lines[ll.first_line][: ll.indent]
    if first in _UNMUTATED_STARTS:
        return None
    if _depth0_index(toks, ";") is not None:
        return None  # several statements on one line
    if i > 0 and body[i - 1].first.text == "@":
        return None  # e.g. `@parameter if`: compile-time
    ends_block = toks[-1].text == ":"

    if first in _COMPOUND:
        if not ends_block:
            return None  # body on the same line
        end_index = _statement_end(body, i)
        if any(b.first.text in ("def", "fn", "struct") for b in body[i + 1 : end_index + 1]):
            return None  # a copy would declare them again
        return Site(DUP, ll.first_line, body[end_index].last_line, indent, nested, mutations)

    if first == "elif":
        if not ends_block:
            return None
        expr = toks[1:-1]
    elif first in ("var", "ref"):
        eq = _depth0_index(toks, "=")
        if eq is None or eq + 1 >= len(toks):
            return None
        expr = toks[eq + 1 :]
    elif ends_block:
        return None
    else:
        return Site(DUP, ll.first_line, ll.last_line, indent, nested, mutations)

    span = (expr[0].line, expr[0].col, expr[-1].end_line, expr[-1].end_col)
    inside = [m for m in mutations if span[:2] <= (m.line, m.col) and (m.line, m.end_col) <= span[2:]]
    if not inside:
        return None
    if first == "var" and toks[1].kind == NAME and toks[eq].line == toks[0].line:
        eq_tok = toks[eq]
        type_text = None
        if toks[2].text == ":":
            type_text = src.lines[ll.first_line][toks[2].end_col : eq_tok.col].strip()
        if type_text is not None:
            decl = (toks[1].text, type_text, toks[0].col, eq_tok.col)
            return Site(DECL, ll.first_line, ll.last_line, indent, nested, inside, decl=decl)
    return Site(WRAP, ll.first_line, ll.last_line, indent, nested, inside, expr=span)


def find_functions(src: TokenizedSource) -> list[Function]:
    lls = src.logical_lines
    functions = []
    # (indent, name, kind)
    stack: list[tuple[int, str, str]] = []
    for idx, ll in enumerate(lls):
        while stack and stack[-1][0] >= ll.indent:
            stack.pop()
        first = ll.first
        if first.kind != NAME or len(ll.tokens) < 2:
            continue
        if first.text in ("struct", "trait"):
            stack.append((ll.indent, ll.tokens[1].text, first.text))
            continue
        if first.text not in ("def", "fn"):
            continue
        name = ll.tokens[1].text
        nested = any(kind == "def" for _, _, kind in stack)
        qualname = ".".join([n for _, n, _ in stack] + [name])
        stack.append((ll.indent, name, "def"))
        if nested:
            continue
        if ll.tokens[-1].text != ":":
            continue  # declaration without body, or a body on the same line
        if any(_has_pragma(src, line) for line in range(ll.first_line, ll.last_line + 1)):
            continue

        body = []
        for other in lls[idx + 1 :]:
            if other.indent <= ll.indent:
                break
            body.append(other)
        if not body:
            continue
        if body[0].first.kind == STRING and len(body[0].tokens) == 1:
            body = body[1:]  # docstring stays above the dispatch
        if not body or _skip_body(body):
            continue

        f = Function(
            qualname=qualname,
            def_line=ll.first_line,
            body_start=body[0].first_line,
            body_end=body[-1].last_line,
            body_indent=src.lines[body[0].first_line][: body[0].indent],
            has_result=_has_result(ll),
        )
        nested_defs: list[int] = []  # indents of enclosing nested defs
        for i, b in enumerate(body):
            while nested_defs and b.indent <= nested_defs[-1]:
                nested_defs.pop()
            if b.first.text in ("def", "fn"):
                nested_defs.append(b.indent)
                continue
            if any(_has_pragma(src, line) for line in range(b.first_line, b.last_line + 1)):
                continue
            mutations = mutations_for_logical_line(b)
            if mutations:
                site = _make_site(src, body, i, mutations, bool(nested_defs))
                if site:
                    f.sites.append(site)
        if f.sites:
            functions.append(f)
    return functions


RUNTIME_HEADER = '''\
from std.ffi import _Global as _DespellGlobal
from std.os import getenv as _despell_getenv
from std.os import abort as _despell_abort


def _despell_init_mutant() -> Int:
    try:
        return Int(_despell_getenv("DESPELL_MUTANT", "0"))
    except:
        return 0


def _despell_init_hits() -> List[Bool]:
    return List[Bool](length={n_functions}, fill=False)


comptime _despell_mutant = _DespellGlobal["despell_mutant", _despell_init_mutant]
comptime _despell_hits = _DespellGlobal["despell_hits", _despell_init_hits]


def _despell_active(fid: Int) -> Int:
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

'''


@dataclass
class Region:
    """Maps a range of generated lines back to what produced them."""

    start: int  # 0-based, inclusive
    end: int  # 0-based, inclusive
    fid: int
    mutant: int | None = None  # the lines of one mutant
    site: tuple[int, ...] = ()  # the lines of a statement holding these mutants
    orig: tuple[int, int] | None = None  # the source lines of that statement
    # with neither: the function's own dispatch lines


@dataclass
class GeneratedMutant:
    number: int
    fid: int
    index: int  # 1-based index within the function
    mutation: Mutation


@dataclass
class GeneratedFunction:
    fid: int
    qualname: str
    def_line: int
    mutants: list[GeneratedMutant]


@dataclass
class GeneratedFile:
    text: str
    regions: list[Region]
    functions: list[GeneratedFunction]


def _apply(lines: list[str], m: Mutation) -> list[str]:
    result = list(lines)
    line = result[m.line]
    result[m.line] = line[: m.col] + m.replacement + line[m.end_col :]
    return result


def _module_docstring_end(src: TokenizedSource) -> int:
    """Physical line after which the runtime header may be inserted."""
    lls = src.logical_lines
    if lls and lls[0].indent == 0 and lls[0].first.kind == STRING and len(lls[0].tokens) == 1:
        return lls[0].last_line + 1
    return 0


class _Emitter:
    def __init__(self, src: TokenizedSource, lines: list[str]):
        self.src = src
        self.lines = lines
        self.out: list[str] = []
        self.regions: list[Region] = []

    def copy(self, lines: list[str], start: int, end: int, depth: int):
        """Copy physical lines, indented `depth` levels deeper."""
        for i in range(start, end + 1):
            line = lines[i]
            if i in self.src.in_string_lines or not line.strip():
                self.out.append(line)
            else:
                self.out.append(INDENT * depth + line)

    def emit_range(self, start: int, end: int, depth: int, sites: list[tuple[Site, list[GeneratedMutant]]], ctx):
        pos = start
        for site, active in sites:
            if site.first_line < pos or site.first_line > end:
                continue
            self.copy(self.lines, pos, site.first_line - 1, depth)
            if site.kind == DUP:
                self.emit_dup(site, active, depth, [s for s in sites if s[0] is not site], ctx)
            elif site.kind == DECL:
                self.emit_decl(site, active, depth, ctx)
            else:
                self.emit_wrap(site, active, depth, ctx)
            pos = site.last_line + 1
        self.copy(self.lines, pos, end, depth)

    def emit_dup(self, site: Site, active, depth: int, other_sites, ctx):
        fid, mvar = ctx(site)
        orig = (site.first_line, site.last_line)
        ind = INDENT * depth + site.indent
        start = len(self.out)
        for k, gm in enumerate(active):
            self.out.append(f"{ind}{'if' if k == 0 else 'elif'} {mvar} == {gm.number}:\n")
            first = len(self.out)
            self.copy(_apply(self.lines, gm.mutation), site.first_line, site.last_line, depth + 1)
            self.regions.append(Region(first, len(self.out) - 1, fid, mutant=gm.number, orig=orig))
        self.out.append(f"{ind}else:\n")
        # only one mutant is active at a time, so statements inside this one
        # need their own dispatch only in the original copy
        self.emit_range(site.first_line, site.last_line, depth + 1, other_sites, ctx)
        self.regions.append(Region(start, len(self.out) - 1, fid, site=tuple(gm.number for gm in active), orig=orig))

    def emit_decl(self, site: Site, active, depth: int, ctx):
        fid, mvar = ctx(site)
        orig = (site.first_line, site.last_line)
        name, type_text, var_col, eq_col = site.decl
        ind = INDENT * depth + site.indent
        start = len(self.out)
        # the type can span lines (`type_of` of a multi-line expression), and
        # regions count lines, so it must go in line by line
        self.out.extend(f"{ind}var {name}: {type_text}\n".splitlines(keepends=True))

        def assignment(lines: list[str]) -> list[str]:
            # the mutation is after the `=`, so these columns still hold
            result = list(lines)
            line = result[site.first_line]
            result[site.first_line] = line[:var_col] + f"{name} " + line[eq_col:]
            return result

        for k, gm in enumerate(active):
            self.out.append(f"{ind}{'if' if k == 0 else 'elif'} {mvar} == {gm.number}:\n")
            first = len(self.out)
            self.copy(assignment(_apply(self.lines, gm.mutation)), site.first_line, site.last_line, depth + 1)
            self.regions.append(Region(first, len(self.out) - 1, fid, mutant=gm.number, orig=orig))
        self.out.append(f"{ind}else:\n")
        self.copy(assignment(self.lines), site.first_line, site.last_line, depth + 1)
        self.regions.append(Region(start, len(self.out) - 1, fid, site=tuple(gm.number for gm in active), orig=orig))

    def emit_wrap(self, site: Site, active, depth: int, ctx):
        fid, mvar = ctx(site)
        orig = (site.first_line, site.last_line)
        sl, sc, el, ec = site.expr
        start = len(self.out)
        self.copy(self.lines, site.first_line, sl - 1, depth)
        first_line = self.lines[sl]
        self.out.append(INDENT * depth + first_line[:sc] + "(\n")
        cont = INDENT * (depth + 2) + site.indent
        for gm in active:
            m = gm.mutation
            mutated = _apply(self.lines, m)
            m_ec = ec + len(m.replacement) - (m.end_col - m.col) if m.line == el else ec
            expr = _span_text(mutated, sl, sc, el, m_ec)
            first = len(self.out)
            self.out.extend(f"{cont}({expr}) if {mvar} == {gm.number} else\n".splitlines(keepends=True))
            self.regions.append(Region(first, len(self.out) - 1, fid, mutant=gm.number, orig=orig))
        tail = self.lines[el][ec:]
        self.out.extend(f"{cont}({_span_text(self.lines, sl, sc, el, ec)})){tail}".splitlines(keepends=True))
        self.copy(self.lines, el + 1, site.last_line, depth)
        self.regions.append(Region(start, len(self.out) - 1, fid, site=tuple(gm.number for gm in active), orig=orig))


def _span_text(lines: list[str], sl: int, sc: int, el: int, ec: int) -> str:
    if sl == el:
        return lines[sl][sc:ec]
    return lines[sl][sc:] + "".join(lines[sl + 1 : el]) + lines[el][:ec]


def _inline_decorator(lines: list[str], def_line: int) -> int | None:
    """The line of an inlining decorator on the function at `def_line`, if any."""
    i = def_line - 1
    while i >= 0 and lines[i].strip().startswith("@"):
        if "inline" in lines[i]:
            return i
        i -= 1
    return None


def generate(
    source: str,
    functions: list[Function],
    *,
    first_fid: int,
    first_mutant: int,
    n_functions_total: int,
    enabled: set[int] | None = None,
    disabled_functions: set[int] = frozenset(),
    dispatch_only: set[int] = frozenset(),
    no_inline: bool = False,
) -> GeneratedFile:
    """Emit the schemata version of a file.

    Mutant numbers and fids are assigned sequentially from `first_mutant` and
    `first_fid` regardless of `enabled`, so numbering is stable while mutants
    are dropped for not compiling. Functions in `dispatch_only` get their
    dispatch even without active mutants, to check that it compiles.
    """
    src = tokenize(source)
    lines = src.lines
    if lines and not lines[-1].endswith("\n"):
        lines = lines[:-1] + [lines[-1] + "\n"]

    em = _Emitter(src, lines)
    out = em.out
    gen_functions: list[GeneratedFunction] = []

    insert_at = _module_docstring_end(src)
    out.extend(lines[:insert_at])
    out.extend((RUNTIME_HEADER.format(n_functions=max(n_functions_total, 1))).splitlines(keepends=True))
    pos = insert_at

    fid = first_fid
    number = first_mutant
    for f in functions:
        gen_mutants = []
        active_sites = []
        for site in f.sites:
            active = []
            for m in site.mutations:
                gm = GeneratedMutant(number=number, fid=fid, index=len(gen_mutants) + 1, mutation=m)
                gen_mutants.append(gm)
                if enabled is None or number in enabled:
                    active.append(gm)
                number += 1
            if active:
                active_sites.append((site, active))
        gen_functions.append(GeneratedFunction(fid=fid, qualname=f.qualname, def_line=f.def_line, mutants=gen_mutants))

        out.extend(lines[pos : f.def_line])
        if no_inline and active_sites and fid not in disabled_functions:
            # Inlining functions that hold all their mutants into each other
            # multiplies code size along call chains, which can make LLVM take
            # many times longer than for the functions separately. A plain
            # `@always_inline` only affects speed, so it's replaced; any other
            # inline decorator is left alone.
            decorator = _inline_decorator(lines, f.def_line)
            if decorator is None:
                def_indent = lines[f.def_line][: len(lines[f.def_line]) - len(lines[f.def_line].lstrip())]
                out.append(f"{def_indent}@inline(.never)\n")
            elif lines[decorator].strip() == "@always_inline":
                out[len(out) - (f.def_line - decorator)] = lines[decorator].replace("@always_inline", "@inline(.never)")
        def_line_out = len(out)
        out.extend(lines[f.def_line : f.body_start])
        pos = f.body_end + 1
        if fid in disabled_functions or not active_sites:
            if fid in dispatch_only and fid not in disabled_functions:
                out.append(f"{f.body_indent}_ = _despell_active({fid})\n")
                em.regions.append(Region(def_line_out, len(out) - 1, fid))
            out.extend(lines[f.body_start : f.body_end + 1])
            fid += 1
            continue

        def ctx(site: Site, fid=fid):
            # a nested def can't capture despell_m_ unless it's a closure
            return fid, (f"_despell_active({fid})" if site.nested else "despell_m_")

        out.append(f"{f.body_indent}var despell_m_ = _despell_active({fid})\n")
        em.emit_range(f.body_start, f.body_end, 0, active_sites, ctx)
        if f.has_result:
            # A mutant can make the end of the body reachable (`while True`
            # -> `while False`), which Mojo would reject for the whole function.
            out.append(f'{f.body_indent}_despell_abort("despell: a mutant fell off the end of {f.qualname}")\n')
        # errors on the `def` line, like a missing return, belong to the function
        em.regions.append(Region(def_line_out, len(out) - 1, fid))
        fid += 1

    out.extend(lines[pos:])
    return GeneratedFile(text="".join(out), regions=em.regions, functions=gen_functions)


def analyze(source: str) -> list[Function]:
    return find_functions(tokenize(source))
