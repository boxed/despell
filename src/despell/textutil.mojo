"""Reading compiler and test output, and other text work."""

from std.collections import Set


def glob_match(pattern: String, text: String) -> Bool:
    """`fnmatch`-style matching: `*`, `?` and `[...]` (case-sensitive)."""
    return _glob(pattern.as_bytes(), 0, text.as_bytes(), 0)


def _glob(p: Span[UInt8, _], pi: Int, t: Span[UInt8, _], ti: Int) -> Bool:
    var i = pi
    var j = ti
    while i < len(p):
        var c = Int(p[i])
        if c == ord("*"):
            while i < len(p) and Int(p[i]) == ord("*"):
                i += 1
            if i == len(p):
                return True
            for k in range(j, len(t) + 1):
                if _glob(p, i, t, k):
                    return True
            return False
        if j >= len(t):
            return False
        if c == ord("?"):
            i += 1
            j += 1
            continue
        if c == ord("["):
            var close = i + 1
            while close < len(p) and Int(p[close]) != ord("]"):
                close += 1
            if close < len(p):
                var negate = i + 1 < close and Int(p[i + 1]) == ord("!")
                var k = i + 2 if negate else i + 1
                var hit = False
                while k < close:
                    if k + 2 < close and Int(p[k + 1]) == ord("-"):
                        if Int(t[j]) >= Int(p[k]) and Int(t[j]) <= Int(p[k + 2]):
                            hit = True
                        k += 3
                    else:
                        if Int(t[j]) == Int(p[k]):
                            hit = True
                        k += 1
                if hit == negate:
                    return False
                i = close + 1
                j += 1
                continue
        if c != Int(t[j]):
            return False
        i += 1
        j += 1
    return j == len(t)


@fieldwise_init
struct Diagnostic(Copyable, Movable):
    var path: String  # as printed: absolute, or relative to the build's directory
    var line: Int  # 0-based
    var is_error: Bool  # else a note
    var message: String


def _digits_end(text: String, start: Int) -> Int:
    var bytes = text.as_bytes()
    var i = start
    while i < len(bytes) and Int(bytes[i]) >= ord("0") and Int(bytes[i]) <= ord("9"):
        i += 1
    return i


def parse_diagnostics(output: String) -> List[Diagnostic]:
    """The `file.mojo:line:col: error|note: message` lines in compiler output."""
    var result = List[Diagnostic]()
    for raw in output.splitlines():
        var line = String(raw)
        var at = line.find(".mojo:")
        while at >= 0:
            var l_start = at + 6
            var l_end = _digits_end(line, l_start)
            var ok = l_end > l_start and line.byte_length() > l_end and String(line[byte=l_end : l_end + 1]) == ":"
            if ok:
                var c_end = _digits_end(line, l_end + 1)
                var rest = String(line[byte=c_end:])
                if c_end > l_end + 1 and (rest.startswith(": error: ") or rest.startswith(": note: ")):
                    var is_error = rest.startswith(": error: ")
                    var message = String(rest[byte = (9 if is_error else 8) :])
                    try:
                        var n = atol(String(line[byte=l_start:l_end]))
                        result.append(Diagnostic(String(line[byte = 0 : at + 5]), n - 1, is_error, message))
                    except:
                        pass
                    break
            at = line.find(".mojo:", at + 1)
    return result^


def link_references(output: String) -> List[String]:
    """Functions referencing an undefined symbol, in linker output:
    `    _pkg::mod::Struct::method(::String) in mojo_archive-a8b61e5.a`."""
    var result = List[String]()
    for raw in output.splitlines():
        var line = String(raw)
        if not (line.startswith(" ") or line.startswith("\t")):
            continue
        var stripped = String(line.lstrip())
        if not stripped.startswith("_") or not stripped.endswith(".a") or not (" in " in stripped):
            continue
        var paren = stripped.find("(")
        if paren > 1:
            result.append(String(stripped[byte=1:paren]))
    return result^


def numbers_after(output: String, prefix: String) -> List[Int]:
    """The numbers on lines that are `prefix` then a number, sorted, unique."""
    var seen = Set[Int]()
    var result = List[Int]()
    for raw in output.splitlines():
        var line = String(raw)
        if line.startswith(prefix):
            try:
                var n = atol(String(String(line[byte = prefix.byte_length() :]).strip()))
                if not (n in seen):
                    seen.add(n)
                    result.append(n)
            except:
                pass
    sort(result)
    return result^


def first_failed_test(output: String) -> String:
    """The name of the first failing test in TestSuite output, or ""."""
    for raw in output.splitlines():
        var line = String(String(raw).lstrip())
        if line.startswith("FAIL ["):
            var close = line.find("] ")
            if close > 0:
                var rest = String(String(line[byte = close + 2 :]).strip())
                var space = rest.find(" ")
                return String(rest[byte=0:space]) if space >= 0 else rest
    return String("")


def first_error(output: String) -> String:
    for raw in output.splitlines():
        var line = String(raw)
        var at = line.find(" error: ")
        if at >= 0 and not String(line.rstrip()).endswith("failed to run the pass manager"):
            return String(String(line[byte = at + 8 :]).strip())
    return String("build failed")


def without_warnings(output: String) -> String:
    """Compiler output without warning diagnostics (and their source excerpts)."""
    var kept = List[String]()
    var pending = List[String]()  # "Included from" lines that precede a diagnostic
    var keep = True
    for raw in output.splitlines():
        var line = String(raw)
        if line.startswith("Included from") or line.startswith("Imported from"):
            pending.append(line)
            continue
        var diags = parse_diagnostics(line)
        if line.find(": warning: ") >= 0 and ".mojo:" in line:
            keep = False
        elif len(diags) > 0:
            keep = True
        elif not line.startswith(" ") and String(line.strip()).byte_length() > 0:
            keep = True
        if keep:
            for p in pending:
                kept.append(p)
            kept.append(line)
        pending = List[String]()
    var out = String("")
    for i in range(len(kept)):
        if i:
            out += "\n"
        out += kept[i]
    return out^


def absolutize_imports(text: String, package: List[String]) -> String:
    """Rewrite `from .x import y` to `from pkg.x import y`, given the module's package."""
    var out = String("")
    for raw in text.splitlines(keepends=True):
        var line = String(raw)
        var stripped = String(line.lstrip())
        var indent = String(line[byte = 0 : line.byte_length() - stripped.byte_length()])
        if not stripped.startswith("from ") or not String(stripped[byte=5:]).lstrip().startswith("."):
            out += line
            continue
        var after = String(String(stripped[byte=5:]).lstrip())
        var dots = 0
        while dots < after.byte_length() and String(after[byte=dots : dots + 1]) == ".":
            dots += 1
        var space = after.find(" ")
        if space < 0:
            out += line
            continue
        var target_rest = String(after[byte=dots:space])
        var tail = String(after[byte=space:])
        if not String(tail.lstrip()).startswith("import"):
            out += line
            continue
        var up = dots - 1
        var parts = List[String]()
        for i in range(len(package) - up if up else len(package)):
            parts.append(package[i])
        if target_rest.byte_length():
            parts.append(target_rest)
        if len(parts) == 0:
            out += line
            continue
        var target = String("")
        for i in range(len(parts)):
            if i:
                target += "."
            target += parts[i]
        out += indent + "from " + target + tail
    return out^


def join_words(words: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(words)):
        if i:
            out += sep
        out += words[i]
    return out^


def format_seconds(s: Float64) -> String:
    """Seconds with one decimal."""
    var tenths = Int(s * 10 + 0.5)
    return String(tenths // 10) + "." + String(tenths % 10)
