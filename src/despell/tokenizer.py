"""A small Mojo tokenizer.

Mojo's surface syntax is close enough to Python that a hand-rolled tokenizer is
all we need: we never build an AST. Mutations are token replacements, and
function bodies are located from logical lines and indentation.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

NAME = "name"
NUMBER = "number"
STRING = "string"
OP = "op"
NEWLINE = "newline"  # end of a logical line
COMMENT = "comment"

OPERATORS = sorted(
    [
        "**=", "//=", ">>=", "<<=", "...",
        "->", "**", "//", "<<", ">>", "<=", ">=", "==", "!=", ":=",
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "@=",
        "+", "-", "*", "/", "%", "&", "|", "^", "~", "<", ">", "(", ")",
        "[", "]", "{", "}", ",", ":", ".", ";", "@", "=", "!",
    ],
    key=len,
    reverse=True,
)

_NUMBER_RE = re.compile(
    r"""
    0[xX][0-9a-fA-F_]+
    | 0[bB][01_]+
    | 0[oO][0-7_]+
    | (?: [0-9][0-9_]*\.?[0-9_]* | \.[0-9][0-9_]* ) (?:[eE][+-]?[0-9_]+)?
    """,
    re.VERBOSE,
)
_NAME_RE = re.compile(r"[^\W\d]\w*|`[^`\n]+`")
_STRING_START_RE = re.compile(r"""([rRbBtTfFuU]{0,2})('''|\"\"\"|'|")""")


@dataclass
class Token:
    kind: str
    text: str
    line: int  # 0-based physical line where the token starts
    col: int  # 0-based column where the token starts
    end_line: int
    end_col: int


@dataclass
class LogicalLine:
    tokens: list[Token]
    first_line: int  # physical line of the first token
    last_line: int  # physical line of the last token
    indent: int  # indentation width of the first physical line

    @property
    def first(self) -> Token:
        return self.tokens[0]


@dataclass
class TokenizedSource:
    lines: list[str]
    tokens: list[Token]
    logical_lines: list[LogicalLine]
    # physical lines that start inside a multi-line string literal; these must
    # never be re-indented since that would change the string's value
    in_string_lines: set[int] = field(default_factory=set)


class TokenizeError(Exception):
    pass


def tokenize(source: str) -> TokenizedSource:
    lines = source.splitlines(keepends=True)
    tokens: list[Token] = []
    in_string_lines: set[int] = set()
    depth = 0

    line_no = 0
    col = 0
    n_lines = len(lines)
    while line_no < n_lines:
        text = lines[line_no]
        if col >= len(text):
            line_no += 1
            col = 0
            continue
        c = text[col]

        if c in " \t\f\r":
            col += 1
            continue
        if c == "\n":
            if depth == 0 and tokens and tokens[-1].kind != NEWLINE:
                tokens.append(Token(NEWLINE, "\n", line_no, col, line_no, col + 1))
            line_no += 1
            col = 0
            continue
        if c == "\\" and text[col + 1 : col + 2] in ("\n", "\r\n", ""):
            # explicit line continuation
            line_no += 1
            col = 0
            continue
        if c == "#":
            end = len(text.rstrip("\r\n"))
            tokens.append(Token(COMMENT, text[col:end], line_no, col, line_no, end))
            col = end
            continue

        m = _STRING_START_RE.match(text, col)
        if m and (m.group(1) == "" or _is_string_prefix(text, col, m)):
            line_no, col = _read_string(lines, line_no, col, m, tokens, in_string_lines)
            continue

        m = _NAME_RE.match(text, col)
        if m:
            tokens.append(Token(NAME, m.group(), line_no, col, line_no, m.end()))
            col = m.end()
            continue

        if c.isdigit() or (c == "." and text[col + 1 : col + 2].isdigit()):
            m = _NUMBER_RE.match(text, col)
            assert m
            end = m.end()
            tokens.append(Token(NUMBER, m.group(), line_no, col, line_no, end))
            col = end
            continue

        for op in OPERATORS:
            if text.startswith(op, col):
                if op in "([{":
                    depth += 1
                elif op in ")]}":
                    depth = max(0, depth - 1)
                tokens.append(Token(OP, op, line_no, col, line_no, col + len(op)))
                col += len(op)
                break
        else:
            raise TokenizeError(f"unexpected character {c!r} at line {line_no + 1}, column {col + 1}")

    if tokens and tokens[-1].kind != NEWLINE:
        last = tokens[-1]
        tokens.append(Token(NEWLINE, "", last.end_line, last.end_col, last.end_line, last.end_col))

    return TokenizedSource(
        lines=lines,
        tokens=tokens,
        logical_lines=_logical_lines(lines, tokens),
        in_string_lines=in_string_lines,
    )


def _is_string_prefix(text: str, col: int, m: re.Match) -> bool:
    # `r"..."` is a string with a prefix, but the `r` must not be the tail of a
    # longer identifier
    return col == 0 or not (text[col - 1].isalnum() or text[col - 1] == "_")


def _read_string(lines, line_no, col, m, tokens, in_string_lines):
    quote = m.group(2)
    start_line, start_col = line_no, col
    pos = m.end()
    triple = len(quote) == 3
    while True:
        text = lines[line_no]
        while pos < len(text):
            ch = text[pos]
            if ch == "\\":
                pos += 2
                continue
            if text.startswith(quote, pos):
                pos += len(quote)
                parts = [lines[i] for i in range(start_line, line_no + 1)]
                if start_line == line_no:
                    value = text[start_col:pos]
                else:
                    value = parts[0][start_col:] + "".join(parts[1:-1]) + text[:pos]
                tokens.append(Token(STRING, value, start_line, start_col, line_no, pos))
                return line_no, pos
            if ch == "\n" and not triple:
                raise TokenizeError(f"unterminated string at line {start_line + 1}")
            pos += 1
        if not triple:
            raise TokenizeError(f"unterminated string at line {start_line + 1}")
        line_no += 1
        pos = 0
        if line_no >= len(lines):
            raise TokenizeError(f"unterminated string at line {start_line + 1}")
        in_string_lines.add(line_no)


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def _logical_lines(lines: list[str], tokens: list[Token]) -> list[LogicalLine]:
    result = []
    current: list[Token] = []
    for tok in tokens:
        if tok.kind == COMMENT:
            continue
        if tok.kind == NEWLINE:
            if current:
                result.append(
                    LogicalLine(
                        tokens=current,
                        first_line=current[0].line,
                        last_line=current[-1].end_line,
                        indent=_indent_of(lines[current[0].line]),
                    )
                )
            current = []
            continue
        current.append(tok)
    return result
