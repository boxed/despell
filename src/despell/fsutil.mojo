"""Files and directories: reading, writing, walking, copying, removing."""

from std.ffi import external_call
from std.os import listdir, makedirs, remove, rmdir, stat
from std.os.path import exists, isdir, isfile, islink
from std.pathlib import Path

from .sysutil import c_string


def read_text(path: String) raises -> String:
    return Path(path).read_text()


def write_text(path: String, text: String) raises:
    Path(path).write_text(text)


def read_bytes(path: String) raises -> List[UInt8]:
    return Path(path).read_bytes()


def path_exists(path: String) -> Bool:
    return exists(path) or islink(path)


def is_dir(path: String) -> Bool:
    return isdir(path) and not islink(path)


def is_file(path: String) -> Bool:
    return isfile(path)


def join(a: String, b: String) -> String:
    if a.byte_length() == 0 or b.startswith("/"):
        return b
    if a.endswith("/"):
        return a + b
    return a + "/" + b


def parent(path: String) -> String:
    var i = path.rfind("/")
    if i < 0:
        return String("")
    if i == 0:
        return String("/")
    return String(path[byte=0:i])


def basename(path: String) -> String:
    var i = path.rfind("/")
    return String(path[byte=i + 1 :]) if i >= 0 else path


def relative_to(path: String, root: String) -> String:
    """`path` relative to `root`, which must contain it."""
    if path == root:
        return String("")
    var prefix = root if root.endswith("/") else root + "/"
    if path.startswith(prefix):
        return String(path[byte=prefix.byte_length() :])
    return path


def real_path(path: String) raises -> String:
    var buf = List[UInt8](capacity=4096)
    for _ in range(4096):
        buf.append(0)
    var c_path = c_string(path)
    var rc = external_call["realpath", Int](c_path.unsafe_ptr(), buf.unsafe_ptr())
    if rc == 0:
        raise Error("can't resolve " + path)
    var n = 0
    while buf[n] != 0:
        n += 1
    return String(StringSpan(unsafe_from_utf8=Span(buf)[0:n]))


def rename_file(src: String, dst: String) raises:
    var c_src = c_string(src)
    var c_dst = c_string(dst)
    if external_call["rename", Int32](c_src.unsafe_ptr(), c_dst.unsafe_ptr()) != 0:
        raise Error("can't rename " + src + " to " + dst)


def mkdirs(path: String) raises:
    if not isdir(path):
        makedirs(path, exist_ok=True)


def remove_file(path: String):
    try:
        remove(path)
    except:
        pass


def rmtree(path: String):
    """Remove `path` and everything under it, ignoring errors (something
    else may be writing into it)."""
    if islink(path) or isfile(path):
        remove_file(path)
        return
    if not isdir(path):
        return
    try:
        for name in listdir(path):
            rmtree(join(path, name))
        rmdir(path)
    except:
        pass


def list_dir(path: String) -> List[String]:
    """Names in directory `path`, sorted; empty if it can't be read."""
    try:
        var names = listdir(path)
        sort(names)
        return names^
    except:
        return List[String]()


def walk_files(root: String, skip: List[String]) -> List[String]:
    """Every file under `root`, as paths relative to it, sorted, leaving out
    anything whose name is in `skip`."""
    var result = List[String]()
    _walk(root, String(""), skip, result)
    return result^


def _walk(root: String, rel: String, skip: List[String], mut result: List[String]):
    var here = join(root, rel) if rel.byte_length() else root
    for name in list_dir(here):
        if name in skip:
            continue
        var child_rel = join(rel, name) if rel.byte_length() else name
        var child = join(root, child_rel)
        if is_dir(child):
            _walk(root, child_rel, skip, result)
        elif isfile(child):
            result.append(child_rel)


def copy_file(src: String, dst: String) raises:
    var data = Path(src).read_bytes()
    Path(dst).write_bytes(data)
    var mode = stat(src).st_mode & 0o7777
    var c_dst = c_string(dst)
    _ = external_call["chmod", Int32](c_dst.unsafe_ptr(), UInt16(mode))


def copy_tree(src: String, dst: String, skip: List[String]) raises:
    """Copy directory `src` to `dst` (merging into it), leaving out anything
    whose name is in `skip`. Symlinks are followed."""
    mkdirs(dst)
    for name in list_dir(src):
        if name in skip:
            continue
        var s = join(src, name)
        var d = join(dst, name)
        if isdir(s):
            copy_tree(s, d, skip)
        elif isfile(s):
            copy_file(s, d)


# ---- hashing -----------------------------------------------------------------


struct Hasher(Movable):
    """64-bit FNV-1a: stable between runs and platforms, which is all the
    fingerprints and snapshots need."""

    var state: UInt64

    def __init__(out self):
        self.state = 0xCBF29CE484222325

    def update(mut self, bytes: Span[UInt8, _]):
        for b in bytes:
            self.state = (self.state ^ UInt64(b)) * 0x100000001B3

    def update(mut self, text: String):
        self.update(text.as_bytes())
        # a separator, so ("ab", "c") and ("a", "bc") differ
        self.state = (self.state ^ 0xFF) * 0x100000001B3

    def hex(self) -> String:
        var digits = String("0123456789abcdef")
        var out = String("")
        for i in range(16):
            var nibble = Int((self.state >> UInt64(4 * (15 - i))) & 0xF)
            out += String(digits[byte=nibble])
        return out^


def hash_text(text: String) -> String:
    var h = Hasher()
    h.update(text)
    return h.hex()


def hash_bytes(bytes: List[UInt8]) -> String:
    var h = Hasher()
    h.update(Span(bytes))
    return h.hex()
