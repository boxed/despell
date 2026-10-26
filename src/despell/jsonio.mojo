"""JSON values, parsing and encoding: for the state file and `--json` output."""

comptime J_NULL = 0
comptime J_BOOL = 1
comptime J_NUMBER = 2
comptime J_STRING = 3
comptime J_ARRAY = 4
comptime J_OBJECT = 5


struct Json(Copyable, Deinitable, Movable, Sized):
    """A JSON value. Objects keep their keys in insertion order."""

    var kind: Int
    var flag: Bool
    var number: Float64
    var text: String
    var items: List[Json]  # array elements, or object values
    var keys: List[String]  # object keys

    def __init__(out self):
        self.kind = J_NULL
        self.flag = False
        self.number = 0
        self.text = String("")
        self.items = List[Json]()
        self.keys = List[String]()

    def __deinit__(deinit self):
        # Empty, but needed: Json holds a List of itself, and without an
        # explicit __deinit__ Mojo can't prove List[Json] is Deinitable while
        # it's still working out whether Json is. The fields are destroyed
        # as usual after this.
        pass

    def __copyinit__(mut self, copy: Self):
        self.kind = copy.kind
        self.flag = copy.flag
        self.number = copy.number
        self.text = copy.text
        self.items = copy.items.copy()
        self.keys = copy.keys.copy()

    @staticmethod
    def of(value: Bool) -> Json:
        var j = Json()
        j.kind = J_BOOL
        j.flag = value
        return j^

    @staticmethod
    def of(value: Int) -> Json:
        var j = Json()
        j.kind = J_NUMBER
        j.number = Float64(value)
        return j^

    @staticmethod
    def of(value: Float64) -> Json:
        var j = Json()
        j.kind = J_NUMBER
        j.number = value
        return j^

    @staticmethod
    def of(value: String) -> Json:
        var j = Json()
        j.kind = J_STRING
        j.text = value
        return j^

    @staticmethod
    def of(value: Optional[String]) -> Json:
        return Json.of(value.value()) if value else Json()

    @staticmethod
    def of(value: Optional[Int]) -> Json:
        return Json.of(value.value()) if value else Json()

    @staticmethod
    def ints(values: List[Int]) -> Json:
        var j = Json.array()
        for v in values:
            j.append(Json.of(v))
        return j^

    @staticmethod
    def strings(values: List[String]) -> Json:
        var j = Json.array()
        for v in values:
            j.append(Json.of(v))
        return j^

    @staticmethod
    def array() -> Json:
        var j = Json()
        j.kind = J_ARRAY
        return j^

    @staticmethod
    def object() -> Json:
        var j = Json()
        j.kind = J_OBJECT
        return j^

    def is_null(self) -> Bool:
        return self.kind == J_NULL

    def append(mut self, var value: Json):
        self.items.append(value^)

    def set(mut self, key: String, var value: Json):
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.items[i] = value^
                return
        self.keys.append(key)
        self.items.append(value^)

    def has(self, key: String) -> Bool:
        for k in self.keys:
            if k == key:
                return True
        return False

    def get(self, key: String) -> Json:
        """The member `key`, or null."""
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                return self.items[i].copy()
        return Json()

    def __len__(self) -> Int:
        return len(self.items)

    def __getitem__(self, i: Int) -> Json:
        return self.items[i].copy()

    def as_int(self) -> Int:
        return Int(self.number)

    def as_float(self) -> Float64:
        return self.number

    def as_bool(self) -> Bool:
        return self.flag

    def as_string(self) -> String:
        return self.text

    def str_or(self, key: String, default: String) -> String:
        var v = self.get(key)
        return v.text if v.kind == J_STRING else default

    def opt_str(self, key: String) -> Optional[String]:
        var v = self.get(key)
        return Optional(v.text) if v.kind == J_STRING else None

    def int_or(self, key: String, default: Int) -> Int:
        var v = self.get(key)
        return v.as_int() if v.kind == J_NUMBER else default

    def opt_int(self, key: String) -> Optional[Int]:
        var v = self.get(key)
        return Optional(v.as_int()) if v.kind == J_NUMBER else None

    def float_or(self, key: String, default: Float64) -> Float64:
        var v = self.get(key)
        return v.number if v.kind == J_NUMBER else default

    def int_list(self, key: String) -> List[Int]:
        var v = self.get(key)
        var out = List[Int]()
        for item in v.items:
            out.append(item.as_int())
        return out^

    def str_list(self, key: String) -> List[String]:
        var v = self.get(key)
        var out = List[String]()
        for item in v.items:
            if item.kind == J_STRING:
                out.append(item.text)
        return out^


# ---- encoding ----------------------------------------------------------------


def encode(value: Json, indent: Int = -1) -> String:
    """`value` as JSON text; with `indent` >= 0, one item per line."""
    var out = String("")
    _encode(value, indent, 0, out)
    return out^


def _newline(indent: Int, level: Int, mut out: String):
    if indent >= 0:
        out += "\n"
        for _ in range(indent * level):
            out += " "


def _encode(value: Json, indent: Int, level: Int, mut out: String):
    if value.kind == J_NULL:
        out += "null"
    elif value.kind == J_BOOL:
        out += "true" if value.flag else "false"
    elif value.kind == J_NUMBER:
        if value.number == Float64(Int(value.number)) and abs(value.number) < 1e15:
            out += String(Int(value.number))
        else:
            out += String(value.number)
    elif value.kind == J_STRING:
        encode_string(value.text, out)
    elif value.kind == J_ARRAY:
        if len(value.items) == 0:
            out += "[]"
            return
        out += "["
        for i in range(len(value.items)):
            if i:
                out += ","
            _newline(indent, level + 1, out)
            _encode(value.items[i], indent, level + 1, out)
        _newline(indent, level, out)
        out += "]"
    else:
        if len(value.items) == 0:
            out += "{}"
            return
        out += "{"
        for i in range(len(value.items)):
            if i:
                out += ","
            _newline(indent, level + 1, out)
            encode_string(value.keys[i], out)
            out += ": " if indent >= 0 else ":"
            _encode(value.items[i], indent, level + 1, out)
        _newline(indent, level, out)
        out += "}"


def encode_string(s: String, mut out: String):
    var hex = String("0123456789abcdef")
    out += '"'
    var start = 0
    var bytes = s.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var b = Int(bytes[i])
        var escape: String
        if b == ord('"'):
            escape = String('\\"')
        elif b == ord("\\"):
            escape = String("\\\\")
        elif b == ord("\n"):
            escape = String("\\n")
        elif b == ord("\t"):
            escape = String("\\t")
        elif b == ord("\r"):
            escape = String("\\r")
        elif b < 0x20:
            escape = String("\\u00") + String(hex[byte=b >> 4]) + String(hex[byte=b & 0xF])
        else:
            continue
        out += String(s[byte=start:i])
        out += escape
        start = i + 1
    out += String(s[byte=start:n])
    out += '"'


# ---- parsing -----------------------------------------------------------------


def _bad(pos: Int, what: String) -> Error:
    return Error("bad JSON at byte " + String(pos) + ": " + what)


struct _Parser:
    var text: String
    var pos: Int

    def __init__(out self, text: String):
        self.text = text
        self.pos = 0

    def byte(self) -> Int:
        var bytes = self.text.as_bytes()
        return Int(bytes[self.pos]) if self.pos < len(bytes) else 0

    def skip_space(mut self):
        var bytes = self.text.as_bytes()
        while self.pos < len(bytes) and (
            Int(bytes[self.pos]) == ord(" ") or Int(bytes[self.pos]) == ord("\n")
            or Int(bytes[self.pos]) == ord("\t") or Int(bytes[self.pos]) == ord("\r")
        ):
            self.pos += 1


    def expect(mut self, word: String) raises:
        var bytes = self.text.as_bytes()
        var w = word.as_bytes()
        if self.pos + len(w) > len(bytes):
            raise _bad(self.pos, "expected " + word)
        for i in range(len(w)):
            if bytes[self.pos + i] != w[i]:
                raise _bad(self.pos, "expected " + word)
        self.pos += word.byte_length()

    def value(mut self) raises -> Json:
        self.skip_space()
        var b = self.byte()
        if b == ord("{"):
            self.pos += 1
            var obj = Json.object()
            self.skip_space()
            if self.byte() == ord("}"):
                self.pos += 1
                return obj^
            while True:
                self.skip_space()
                var key = self.string()
                self.skip_space()
                self.expect(":")
                obj.keys.append(key)
                obj.items.append(self.value())
                self.skip_space()
                if self.byte() == ord(","):
                    self.pos += 1
                    continue
                self.expect("}")
                return obj^
        if b == ord("["):
            self.pos += 1
            var arr = Json.array()
            self.skip_space()
            if self.byte() == ord("]"):
                self.pos += 1
                return arr^
            while True:
                arr.items.append(self.value())
                self.skip_space()
                if self.byte() == ord(","):
                    self.pos += 1
                    continue
                self.expect("]")
                return arr^
        if b == ord('"'):
            return Json.of(self.string())
        if b == ord("t"):
            self.expect("true")
            return Json.of(True)
        if b == ord("f"):
            self.expect("false")
            return Json.of(False)
        if b == ord("n"):
            self.expect("null")
            return Json()
        return self.number()

    def number(mut self) raises -> Json:
        var bytes = self.text.as_bytes()
        var start = self.pos
        while self.pos < len(bytes) and (
            (Int(bytes[self.pos]) >= ord("0") and Int(bytes[self.pos]) <= ord("9"))
            or Int(bytes[self.pos]) == ord("-") or Int(bytes[self.pos]) == ord("+")
            or Int(bytes[self.pos]) == ord(".") or Int(bytes[self.pos]) == ord("e") or Int(bytes[self.pos]) == ord("E")
        ):
            self.pos += 1
        if self.pos == start:
            raise _bad(self.pos, "unexpected character")
        var s = String(self.text[byte=start : self.pos])
        if "." in s or "e" in s or "E" in s:
            return Json.of(atof(s))
        return Json.of(atol(s))

    def string(mut self) raises -> String:
        if self.byte() != ord('"'):
            raise _bad(self.pos, "expected a string")
        self.pos += 1
        var bytes = self.text.as_bytes()
        var out = String("")
        var start = self.pos
        while True:
            if self.pos >= len(bytes):
                raise _bad(self.pos, "unterminated string")
            var b = Int(bytes[self.pos])
            if b == ord('"'):
                out += String(self.text[byte=start : self.pos])
                self.pos += 1
                return out^
            if b != ord("\\"):
                self.pos += 1
                continue
            out += String(self.text[byte=start : self.pos])
            var e = Int(bytes[self.pos + 1])
            self.pos += 2
            if e == ord("n"):
                out += "\n"
            elif e == ord("t"):
                out += "\t"
            elif e == ord("r"):
                out += "\r"
            elif e == ord("b"):
                out += "\x08"
            elif e == ord("f"):
                out += "\x0c"
            elif e == ord("u"):
                var code = Int(atol(String(self.text[byte=self.pos : self.pos + 4]), 16))
                self.pos += 4
                if code >= 0xD800 and code < 0xDC00 and String(self.text[byte=self.pos : min(self.pos + 2, len(bytes))]) == "\\u":
                    var low = Int(atol(String(self.text[byte=self.pos + 2 : self.pos + 6]), 16))
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    self.pos += 6
                out += String(Codepoint(unsafe_unchecked_codepoint=UInt32(code)))
            else:
                out += String(chr(Int(e)))
            start = self.pos


def parse(text: String) raises -> Json:
    var p = _Parser(text)
    var v = p.value()
    p.skip_space()
    if p.pos < text.byte_length():
        raise _bad(p.pos, "trailing characters")
    return v^
