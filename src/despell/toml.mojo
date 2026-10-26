"""Just enough TOML to read despell's settings.

Settings live in one table: the top of `despell.toml`, or `[tool.despell]` in
`pixi.toml`/`pyproject.toml`. Only that table's `key = value` lines are
parsed, so whatever else those files hold doesn't need to be understood.
Values: strings (basic and literal), integers, floats, booleans, and arrays
of those, which may span lines.
"""

from .jsonio import Json


def read_table(text: String, path: String) raises -> Optional[Json]:
    """The table at dotted `path` ("" for the top level) as a JSON object, or
    None if the file doesn't have it."""
    var lines = text.splitlines()
    var current = String("")
    var found = path.byte_length() == 0
    var table = Json.object()
    var i = 0
    while i < len(lines):
        var line = String(_strip_comment(String(lines[i])).strip())
        i += 1
        if line.byte_length() == 0:
            continue
        if line.startswith("["):
            var name = String(line.strip("[]").strip())
            current = _normalize_key(name)
            if current == path:
                found = True
            continue
        if current != path:
            continue
        var eq = line.find("=")
        if eq < 0:
            raise Error("can't read TOML line: " + line)
        var key = _unquote_key(String(String(line[byte=0:eq]).strip()))
        var value_text = String(String(line[byte=eq + 1 :]).strip())
        # an array can span lines: read until its brackets balance
        while _open_brackets(value_text) > 0 and i < len(lines):
            value_text += " " + String(_strip_comment(String(lines[i])).strip())
            i += 1
        var p = _ValueParser(value_text)
        table.set(key, p.value())
    if not found:
        return None
    return table^


def _normalize_key(name: String) -> String:
    var parts = name.split(".")
    var out = String("")
    for i in range(len(parts)):
        if i:
            out += "."
        out += _unquote_key(String(String(parts[i]).strip()))
    return out^


def _unquote_key(key: String) -> String:
    if key.byte_length() >= 2 and (key.startswith('"') or key.startswith("'")):
        return String(key[byte=1 : key.byte_length() - 1])
    return key


def _strip_comment(line: String) -> String:
    """`line` without a trailing `# comment` (outside of strings)."""
    var bytes = line.as_bytes()
    var quote = 0
    for i in range(len(bytes)):
        var b = Int(bytes[i])
        if quote:
            if b == ord("\\") and quote == ord('"'):
                continue
            if b == quote:
                quote = 0
        elif b == ord('"') or b == ord("'"):
            quote = b
        elif b == ord("#"):
            return String(line[byte=0:i])
    return line


def _open_brackets(text: String) -> Int:
    var depth = 0
    var quote = 0
    for byte in text.as_bytes():
        var b = Int(byte)
        if quote:
            if b == quote:
                quote = 0
        elif b == ord('"') or b == ord("'"):
            quote = b
        elif b == ord("["):
            depth += 1
        elif b == ord("]"):
            depth -= 1
    return depth


struct _ValueParser:
    var text: String
    var pos: Int

    def __init__(out self, text: String):
        self.text = text
        self.pos = 0

    def byte(self) -> Int:
        var bytes = self.text.as_bytes()
        return Int(bytes[self.pos]) if self.pos < len(bytes) else 0

    def skip_space(mut self):
        while self.byte() == ord(" ") or self.byte() == ord("\t"):
            self.pos += 1

    def value(mut self) raises -> Json:
        self.skip_space()
        var b = self.byte()
        if b == ord("["):
            self.pos += 1
            var arr = Json.array()
            while True:
                self.skip_space()
                if self.byte() == ord("]"):
                    self.pos += 1
                    return arr^
                arr.append(self.value())
                self.skip_space()
                if self.byte() == ord(","):
                    self.pos += 1
        if b == ord('"') or b == ord("'"):
            return Json.of(self.string(b))
        var start = self.pos
        var bytes = self.text.as_bytes()
        while self.pos < len(bytes) and Int(bytes[self.pos]) != ord(",") and Int(bytes[self.pos]) != ord("]"):
            self.pos += 1
        var word = String(String(self.text[byte=start : self.pos]).strip())
        if word == "true":
            return Json.of(True)
        if word == "false":
            return Json.of(False)
        var digits = word.replace("_", "")
        if "." in digits or "e" in digits or "E" in digits:
            return Json.of(atof(digits))
        return Json.of(atol(digits))

    def string(mut self, quote: Int) raises -> String:
        self.pos += 1
        var bytes = self.text.as_bytes()
        var out = String("")
        var start = self.pos
        while self.pos < len(bytes):
            var b = Int(bytes[self.pos])
            if b == quote:
                out += String(self.text[byte=start : self.pos])
                self.pos += 1
                return out^
            if b == ord("\\") and quote == ord('"'):
                out += String(self.text[byte=start : self.pos])
                var e = Int(bytes[self.pos + 1])
                if e == ord("n"):
                    out += "\n"
                elif e == ord("t"):
                    out += "\t"
                else:
                    out += String(chr(Int(e)))
                self.pos += 2
                start = self.pos
                continue
            self.pos += 1
        raise Error("unterminated string in TOML: " + self.text)
