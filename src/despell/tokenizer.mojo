"""A small Mojo tokenizer.

Mojo's surface syntax is close enough to Python that a hand-rolled tokenizer is
all we need: we never build an AST. Mutations are token replacements, and
function bodies are located from logical lines and indentation. Columns are
byte offsets.
"""

from std.collections import Set

comptime NAME = 0
comptime NUMBER = 1
comptime STRING = 2
comptime OP = 3
comptime NEWLINE = 4  # end of a logical line
comptime COMMENT = 5


@fieldwise_init
struct Token(Copyable, Movable):
    var kind: Int
    var text: String
    var line: Int  # 0-based physical line where the token starts
    var col: Int  # 0-based byte column where the token starts
    var end_line: Int
    var end_col: Int


@fieldwise_init
struct LogicalLine(Copyable, Movable):
    var tokens: List[Token]  # without comments
    var first_line: Int  # physical line of the first token
    var last_line: Int  # physical line of the last token
    var indent: Int  # indentation width of the first physical line

    def first(self) -> ref[self.tokens] Token:
        return self.tokens[0]


struct TokenizedSource(Movable):
    var lines: List[String]  # physical lines, with their line endings
    var tokens: List[Token]
    var logical_lines: List[LogicalLine]
    # physical lines that start inside a multi-line string literal; these must
    # never be re-indented since that would change the string's value
    var in_string_lines: Set[Int]

    def __init__(out self, var lines: List[String], var tokens: List[Token], var in_string_lines: Set[Int]):
        self.logical_lines = _logical_lines(lines, tokens)
        self.lines = lines^
        self.tokens = tokens^
        self.in_string_lines = in_string_lines^


def split_lines(source: String) -> List[String]:
    """Lines of `source`, each keeping its line ending."""
    var lines = List[String]()
    var bytes = source.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        if Int(bytes[i]) == ord("\n"):
            lines.append(String(source[byte=start : i + 1]))
            start = i + 1
    if start < len(bytes):
        lines.append(String(source[byte=start:]))
    return lines^


# operators by length, space separated (and padded, for `find`)
comptime _OPS3 = " **= //= >>= <<= ... "
comptime _OPS2 = " -> ** // << >> <= >= == != <> := += -= *= /= %= &= |= ^= @= "
comptime _OPS1 = " + - * / % & | ^ ~ < > ( ) [ ] { } , : . ; @ = ! "


def _is_digit(b: Int) -> Bool:
    return b >= ord("0") and b <= ord("9")


def _is_name_start(b: Int) -> Bool:
    return (b >= ord("a") and b <= ord("z")) or (b >= ord("A") and b <= ord("Z")) or b == ord("_") or b >= 0x80


def _is_name_char(b: Int) -> Bool:
    return _is_name_start(b) or _is_digit(b)


def _is_hex(b: Int) -> Bool:
    return _is_digit(b) or (b >= ord("a") and b <= ord("f")) or (b >= ord("A") and b <= ord("F"))


def _at(text: String, i: Int) -> Int:
    var bytes = text.as_bytes()
    return Int(bytes[i]) if i < len(bytes) else 0


def _is_prefix_char(b: Int) -> Bool:
    for c in "rRbBtTfFuU".as_bytes():
        if b == Int(c):
            return True
    return False


def tokenize(source: String) raises -> TokenizedSource:
    var lines = split_lines(source)
    var offsets = List[Int]()  # of each line in `source`
    var at = 0
    for l in lines:
        offsets.append(at)
        at += l.byte_length()
    var tokens = List[Token]()
    var in_string_lines = Set[Int]()
    var depth = 0
    var line_no = 0
    var col = 0
    var n_lines = len(lines)
    while line_no < n_lines:
        var text = lines[line_no]
        var n = text.byte_length()
        if col >= n:
            line_no += 1
            col = 0
            continue
        var c = _at(text, col)

        if c == ord(" ") or c == ord("\t") or c == 0x0C or c == ord("\r"):
            col += 1
            continue
        if c == ord("\n"):
            if depth == 0 and len(tokens) > 0 and tokens[len(tokens) - 1].kind != NEWLINE:
                tokens.append(Token(NEWLINE, String("\n"), line_no, col, line_no, col + 1))
            line_no += 1
            col = 0
            continue
        if c == ord("\\") and (col + 1 >= n or _at(text, col + 1) == ord("\n") or _at(text, col + 1) == ord("\r")):
            # explicit line continuation
            line_no += 1
            col = 0
            continue
        if c == ord("#"):
            var end = String(text.rstrip("\r\n")).byte_length()
            tokens.append(Token(COMMENT, String(text[byte=col:end]), line_no, col, line_no, end))
            col = end
            continue

        # a string, maybe with a prefix (`r"..."`) that isn't the tail of a name
        var q = col
        while q < n and q - col < 2 and _is_prefix_char(_at(text, q)):
            q += 1
        var qc = _at(text, q)
        if (qc == ord('"') or qc == ord("'")) and (
            q == col or col == 0 or not _is_name_char(_at(text, col - 1))
        ):
            var end = _read_string(source, offsets, lines, line_no, col, q, tokens, in_string_lines)
            line_no = end[0]
            col = end[1]
            continue

        if _is_name_start(c):
            var end = col + 1
            while end < n and _is_name_char(_at(text, end)):
                end += 1
            tokens.append(Token(NAME, String(text[byte=col:end]), line_no, col, line_no, end))
            col = end
            continue
        if c == ord("`"):
            var end = col + 1
            while end < n and _at(text, end) != ord("`") and _at(text, end) != ord("\n"):
                end += 1
            if end < n and _at(text, end) == ord("`"):
                tokens.append(Token(NAME, String(text[byte=col : end + 1]), line_no, col, line_no, end + 1))
                col = end + 1
                continue

        if _is_digit(c) or (c == ord(".") and _is_digit(_at(text, col + 1))):
            var end = _number_end(text, col)
            tokens.append(Token(NUMBER, String(text[byte=col:end]), line_no, col, line_no, end))
            col = end
            continue

        var op = _operator_at(text, col)
        if op.byte_length() == 0:
            raise Error(
                "unexpected character " + String(text[byte=col : col + 1]) + " at line "
                + String(line_no + 1) + ", column " + String(col + 1)
            )
        if op == "(" or op == "[" or op == "{":
            depth += 1
        elif op == ")" or op == "]" or op == "}":
            depth = max(0, depth - 1)
        tokens.append(Token(OP, op, line_no, col, line_no, col + op.byte_length()))
        col += op.byte_length()

    if len(tokens) > 0 and tokens[len(tokens) - 1].kind != NEWLINE:
        var last_line = tokens[len(tokens) - 1].end_line
        var last_col = tokens[len(tokens) - 1].end_col
        tokens.append(Token(NEWLINE, String(""), last_line, last_col, last_line, last_col))
    return TokenizedSource(lines^, tokens^, in_string_lines^)


def _operator_at(text: String, col: Int) -> String:
    var n = text.byte_length()
    for length in range(3, 0, -1):
        if col + length > n:
            continue
        var ascii = True
        for i in range(col, col + length):
            if _at(text, i) >= 0x80 or _at(text, i) <= ord(" "):
                ascii = False
        if not ascii:
            continue
        var candidate = String(text[byte=col : col + length])
        var ops = String(_OPS3) if length == 3 else (String(_OPS2) if length == 2 else String(_OPS1))
        if ops.find(" " + candidate + " ") >= 0:
            return candidate
    return String("")


def _number_end(text: String, col: Int) -> Int:
    var n = text.byte_length()
    var i = col
    if _at(text, i) == ord("0") and i + 1 < n:
        var p = _at(text, i + 1)
        if p == ord("x") or p == ord("X"):
            i += 2
            while i < n and (_is_hex(_at(text, i)) or _at(text, i) == ord("_")):
                i += 1
            return i
        if p == ord("b") or p == ord("B") or p == ord("o") or p == ord("O"):
            i += 2
            while i < n and (_is_digit(_at(text, i)) or _at(text, i) == ord("_")):
                i += 1
            return i
    while i < n and (_is_digit(_at(text, i)) or _at(text, i) == ord("_")):
        i += 1
    if i < n and _at(text, i) == ord("."):
        i += 1
        while i < n and (_is_digit(_at(text, i)) or _at(text, i) == ord("_")):
            i += 1
    if i < n and (_at(text, i) == ord("e") or _at(text, i) == ord("E")):
        var j = i + 1
        if j < n and (_at(text, j) == ord("+") or _at(text, j) == ord("-")):
            j += 1
        if j < n and _is_digit(_at(text, j)):
            i = j
            while i < n and (_is_digit(_at(text, i)) or _at(text, i) == ord("_")):
                i += 1
    return i


def _read_string(
    source: String, offsets: List[Int], lines: List[String], start_line: Int, start_col: Int, quote_col: Int,
    mut tokens: List[Token], mut in_string_lines: Set[Int],
) raises -> Tuple[Int, Int]:
    """Read the string literal at `start_col` (its prefix) of `start_line`,
    the way Mojo's lexer does (`Lexer.cpp`): escapes, a backslash-newline
    continuing a single-quoted string, and in a t-string the interpolations,
    which can hold strings of their own. Returns where it ends."""
    var b = source.as_bytes()
    var first = lines[start_line]
    var t_string = False
    for i in range(start_col, quote_col):
        var p = _at(first, i)
        if p == ord("t") or p == ord("T"):
            t_string = True
    var qpos = offsets[start_line] + quote_col
    var qc = Int(b[qpos])
    var triple = _triple_at(b, qpos, qc)
    var stop = _skip_body(b, qpos + (3 if triple else 1), qc, triple, t_string, 0)
    if stop < 0:
        raise Error("unterminated string at line " + String(start_line + 1))
    # back to a line and column
    var line_no = start_line
    while line_no + 1 < len(offsets) and offsets[line_no + 1] <= stop - 1:
        line_no += 1
        in_string_lines.add(line_no)
    var col = stop - offsets[line_no]
    var start = offsets[start_line] + start_col
    tokens.append(Token(STRING, String(source[byte=start:stop]), start_line, start_col, line_no, col))
    return (line_no, col)


def _triple_at(b: Span[UInt8, _], pos: Int, qc: Int) -> Bool:
    return pos + 2 < len(b) and Int(b[pos + 1]) == qc and Int(b[pos + 2]) == qc


def _skip_body(b: Span[UInt8, _], start: Int, qc: Int, triple: Bool, t_string: Bool, depth: Int) -> Int:
    """The offset just past the closing quote of a string body starting at
    `start`, or -1 (Mojo's `skipTStringBody`, and `consumeStringBody` for
    other strings)."""
    var pos = start
    var n = len(b)
    while pos < n:
        var c = Int(b[pos])
        if c == ord("\\"):
            pos += 2
            continue
        if t_string and (c == ord("{") or c == ord("}")):
            if pos + 1 < n and Int(b[pos + 1]) == c:
                pos += 2  # {{ and }} are literal braces
                continue
            if c == ord("{"):
                pos = _interpolation_end(b, pos, depth)
                if pos < 0:
                    return -1
                continue
            pos += 1
            continue
        if c == qc and (not triple or _triple_at(b, pos, qc)):
            return pos + (3 if triple else 1)
        if (c == ord("\n") or c == ord("\r")) and not triple:
            return -1
        pos += 1
    return -1


def _interpolation_end(b: Span[UInt8, _], start: Int, depth: Int) -> Int:
    """The offset just past the `}` closing the t-string interpolation at
    `start` (Mojo's `findTStringInterpolationEnd`), or -1."""
    if depth > 20:
        return -1
    var pos = start + 1
    var n = len(b)
    var braces = 1
    while pos < n:
        var c = Int(b[pos])
        if c == ord("{"):
            braces += 1
            pos += 1
        elif c == ord("}"):
            braces -= 1
            pos += 1
            if braces == 0:
                return pos
        elif c == ord("\\"):
            pos += 2
        elif c == ord("'") or c == ord('"'):
            var triple = _triple_at(b, pos, c)
            pos = _skip_body(b, pos + (3 if triple else 1), c, triple, False, depth + 1)
            if pos < 0:
                return -1
        elif _is_prefix_char(c) and (pos == 0 or not _is_name_char(Int(b[pos - 1]))):
            # r"..", t"..", rt"..", tr"..": a string after its prefix
            var q = pos
            var t = False
            while q < n and q - pos < 2 and _is_prefix_char(Int(b[q])):
                if Int(b[q]) == ord("t") or Int(b[q]) == ord("T"):
                    t = True
                q += 1
            if q < n and (Int(b[q]) == ord("'") or Int(b[q]) == ord('"')):
                var qc = Int(b[q])
                var triple = _triple_at(b, q, qc)
                pos = _skip_body(b, q + (3 if triple else 1), qc, triple, t, depth + 1)
                if pos < 0:
                    return -1
            else:
                pos = q
        else:
            pos += 1
    return -1


def indent_of(line: String) -> Int:
    var i = 0
    var n = line.byte_length()
    while i < n and (_at(line, i) == ord(" ") or _at(line, i) == ord("\t")):
        i += 1
    return i


def _logical_lines(lines: List[String], tokens: List[Token]) -> List[LogicalLine]:
    var result = List[LogicalLine]()
    var current = List[Token]()
    for tok in tokens:
        if tok.kind == COMMENT:
            continue
        if tok.kind == NEWLINE:
            if len(current) > 0:
                var first_line = current[0].line
                result.append(LogicalLine(current.copy(), first_line, current[len(current) - 1].end_line, indent_of(lines[first_line])))
            current = List[Token]()
            continue
        current.append(tok.copy())
    return result^
