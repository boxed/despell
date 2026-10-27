"""Prints the tokens despell's tokenizer makes of a file, in the form of
`dump` (Mojo's own lexer): category, start and end byte offsets, and the
indentation of a token that starts a logical line (-1 otherwise)."""

from std.collections import Dict, Set
from std.sys import argv

from despell.fsutil import read_text
from despell.tokenizer import COMMENT, NAME, NEWLINE, NUMBER, OP, STRING, tokenize


def main() raises:
    var source = read_text(argv()[1])
    var src = tokenize(source)
    var offsets = List[Int]()  # of each physical line
    var at = 0
    for line in src.lines:
        offsets.append(at)
        at += line.byte_length()
    var starts = Set[Int]()  # offsets of the tokens that start a logical line
    var indents = Dict[Int, Int]()
    for ll in src.logical_lines:
        ref t = ll.tokens[0]
        var o = offsets[t.line] + t.col
        starts.add(o)
        indents[o] = ll.indent
    for t in src.tokens:
        if t.kind == NEWLINE or t.kind == COMMENT:
            continue
        var kind = String("name") if t.kind == NAME else (
            String("number") if t.kind == NUMBER else (String("string") if t.kind == STRING else String("op"))
        )
        var start = offsets[t.line] + t.col
        var end = offsets[t.end_line] + t.end_col
        print(kind, start, end, indents.get(start, -1) if start in starts else -1)
