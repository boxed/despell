"""Processes, environment, clocks and locks, straight from libc.

Tests and compilers run as child processes, many at once: `ProcessPool`
starts them with `posix_spawnp`, collects their output (stdout and stderr
together) through pipes, and reaps them as they finish or time out, all from
one thread with `poll`.
"""

from std.ffi import external_call
from std.sys.info import CompilationTarget


def alloc_zero(n: Int) -> List[UInt8]:
    var buf = List[UInt8](capacity=n)
    for _ in range(n):
        buf.append(0)
    return buf^


def c_string(s: String) -> String:
    return s + String("\0")


def string_at(addr: Int) -> String:
    """Copy the NUL-terminated C string at `addr`."""
    if addr == 0:
        return String("")
    var n = external_call["strlen", Int](addr)
    if n <= 0:
        return String("")
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=addr)
    return String(StringSpan(unsafe_from_utf8=Span(unsafe_ptr=p, length=n)))


def string_from_bytes(bytes: List[UInt8]) -> String:
    """Bytes as a String, with invalid UTF-8 replaced (compiler and test
    output isn't guaranteed to be clean)."""
    return String(from_utf8_lossy=Span(bytes))


def executable_path() raises -> String:
    """The path of the running program."""
    var buf = alloc_zero(4096)
    comptime if CompilationTarget.is_macos():
        var size = UInt32(4096)
        if external_call["_NSGetExecutablePath", Int32](buf.unsafe_ptr(), Pointer(to=size)) != 0:
            raise Error("can't find despell's executable")
    else:
        var link = c_string("/proc/self/exe")
        var n = external_call["readlink", Int](link.unsafe_ptr(), buf.unsafe_ptr(), 4095)
        if n <= 0:
            raise Error("can't find despell's executable")
    var n = 0
    while n < len(buf) and buf[n] != 0:
        n += 1
    return String(StringSpan(unsafe_from_utf8=Span(buf)[0:n]))


# ---- environment -------------------------------------------------------------


def environment() -> List[String]:
    """This process's environment, as `NAME=value` strings."""
    var addr: Int
    comptime if CompilationTarget.is_macos():
        # _NSGetEnviron() returns char ***: the address of `environ`
        addr = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=external_call["_NSGetEnviron", Int]())[]
    else:
        var name = c_string("environ")
        var environ_ptr = external_call["dlsym", Int](0, name.unsafe_ptr())
        addr = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=environ_ptr)[]
    var result = List[String]()
    if addr == 0:
        return result^
    var i = 0
    while True:
        var entry = Pointer[Int, MutUntrackedOrigin](unsafe_from_address=addr + 8 * i)[]
        if entry == 0:
            break
        result.append(string_at(entry))
        i += 1
    return result^


def with_env(base: List[String], overrides: List[String]) -> List[String]:
    """`base` (`NAME=value` strings) with `overrides` replacing or adding."""
    var result = List[String]()
    for entry in base:
        var name = _env_name(entry)
        var replaced = False
        for o in overrides:
            if _env_name(o) == name:
                replaced = True
                break
        if not replaced:
            result.append(entry)
    for o in overrides:
        result.append(o)
    return result^


def _env_name(entry: String) -> String:
    var eq = entry.find("=")
    return String(entry[byte=0:eq]) if eq >= 0 else entry


def env_value(env: List[String], name: String) -> String:
    var prefix = name + "="
    for entry in env:
        if entry.startswith(prefix):
            return String(entry[byte=prefix.byte_length():])
    return String("")


# ---- time and processes ------------------------------------------------------


def monotonic_ns() -> Int:
    var clock_id: Int32
    comptime if CompilationTarget.is_macos():
        clock_id = 6  # CLOCK_MONOTONIC
    else:
        clock_id = 1
    var ts = alloc_zero(16)
    _ = external_call["clock_gettime", Int32](clock_id, ts.unsafe_ptr())
    var p = ts.unsafe_ptr().unsafe_bitcast[Int]()
    return p[unsafe_offset=0] * 1_000_000_000 + p[unsafe_offset=1]


def seconds_since(start_ns: Int) -> Float64:
    return Float64(monotonic_ns() - start_ns) / 1e9


def getpid() -> Int:
    return Int(external_call["getpid", Int32]())


def pid_alive(pid: Int) -> Bool:
    return Int(external_call["kill", Int32](Int32(pid), Int32(0))) == 0


# ---- signals -----------------------------------------------------------------
#
# Children run in process groups of their own (so a timeout can kill whatever
# a test started), which also keeps the terminal's Ctrl-C from reaching them.
# So despell blocks SIGINT and SIGTERM, notices them pending while it waits
# for children (`interrupted`), and then cleans up: kills its children and
# saves what's done.

comptime _SIGINT: Int32 = 2
comptime _SIGTERM: Int32 = 15
comptime _SIG_BLOCK: Int32 = 1
comptime _POSIX_SPAWN_SETSIGMASK: Int16 = 0x0008


def _signal_set(include_ours: Bool) -> List[UInt8]:
    var set = alloc_zero(128)  # sigset_t: 4 bytes on macOS, 128 on Linux
    _ = external_call["sigemptyset", Int32](set.unsafe_ptr())
    if include_ours:
        _ = external_call["sigaddset", Int32](set.unsafe_ptr(), _SIGINT)
        _ = external_call["sigaddset", Int32](set.unsafe_ptr(), _SIGTERM)
    return set^


def block_signals():
    var set = _signal_set(True)
    var old = alloc_zero(128)
    _ = external_call["sigprocmask", Int32](_SIG_BLOCK, set.unsafe_ptr(), old.unsafe_ptr())


def interrupted() -> Bool:
    """Whether a blocked SIGINT or SIGTERM is waiting."""
    var set = alloc_zero(128)
    _ = external_call["sigpending", Int32](set.unsafe_ptr())
    return (
        external_call["sigismember", Int32](set.unsafe_ptr(), _SIGINT) == 1
        or external_call["sigismember", Int32](set.unsafe_ptr(), _SIGTERM) == 1
    )


# ---- locks -------------------------------------------------------------------

comptime _LOCK_EX: Int32 = 2
comptime _LOCK_NB: Int32 = 4


def lock_file(path: String, wait: Bool) -> Int:
    """Take an exclusive `flock` on `path` (created if missing). Returns the
    fd that holds it, or -1 if `wait` is False and someone else holds it.
    Closing the fd (`unlock_file`) releases it."""
    # through the stdlib's `open`: declaring libc's `open` ourselves would
    # clash with its declaration. The lock belongs to the open file, so it
    # lives on in the duplicated descriptor.
    var fd: Int32
    try:
        var f = open(path, "a")
        fd = external_call["dup", Int32](Int32(f._get_raw_fd()))
        f.close()
    except:
        return -1
    if fd < 0:
        return -1
    var op = _LOCK_EX if wait else _LOCK_EX | _LOCK_NB
    if external_call["flock", Int32](fd, op) != 0:
        _ = external_call["close", Int32](fd)
        return -1
    return Int(fd)


def unlock_file(fd: Int):
    if fd >= 0:
        _ = external_call["close", Int32](Int32(fd))


# ---- child processes ---------------------------------------------------------

comptime _SIGKILL: Int32 = 9
comptime _WNOHANG: Int32 = 1
comptime _POLLIN: Int16 = 0x0001
comptime _POSIX_SPAWN_SETPGROUP: Int16 = 0x0002
comptime _O_RDONLY: Int32 = 0


struct _CStrings(Movable):
    """A NULL-terminated array of C strings, kept alive with its bytes."""

    var blob: List[UInt8]
    var pointers: List[UInt8]

    def __init__(out self, strings: List[String]):
        self.blob = List[UInt8]()
        var offsets = List[Int]()
        for s in strings:
            offsets.append(len(self.blob))
            for b in s.as_bytes():
                self.blob.append(b)
            self.blob.append(0)
        self.pointers = alloc_zero((len(strings) + 1) * 8)
        var pp = self.pointers.unsafe_ptr().unsafe_bitcast[Int]()
        for i in range(len(strings)):
            pp[unsafe_offset=i] = Int(self.blob.unsafe_ptr()) + offsets[i]
        pp[unsafe_offset=len(strings)] = 0


@fieldwise_init
struct Finished(Movable):
    """A child that's done: `tag` is the caller's, `code` the exit code
    (128 + signal if it died of one), meaningless if it `timed_out`."""

    var tag: Int
    var code: Int
    var timed_out: Bool
    var output: String
    var seconds: Float64


struct _Child(Movable):
    var pid: Int32
    var fd: Int32  # read end of its stdout+stderr pipe, -1 at EOF
    var tag: Int
    var output: List[UInt8]
    var start_ns: Int
    var deadline_ns: Int  # 0: none

    def __init__(out self, pid: Int32, fd: Int32, tag: Int, start_ns: Int, deadline_ns: Int):
        self.pid = pid
        self.fd = fd
        self.tag = tag
        self.output = List[UInt8]()
        self.start_ns = start_ns
        self.deadline_ns = deadline_ns


def _set_pollfd(mut buf: List[UInt8], i: Int, fd: Int32):
    """Fill entry `i` of a `struct pollfd` array: `int fd; short events;
    short revents`, written as two Int32s (events is the low half)."""
    var p = buf.unsafe_ptr().unsafe_bitcast[Int32]()
    p[unsafe_offset=2 * i] = fd
    p[unsafe_offset=2 * i + 1] = Int32(_POLLIN)


def _exit_code(status: Int32) -> Int:
    var s = Int(status)
    var sig = s & 0x7F
    if sig != 0:
        return 128 + sig
    return (s >> 8) & 0xFF


struct ProcessPool(Movable, Sized):
    """Children running at once; `wait_any` returns them as they finish."""

    var children: List[_Child]

    def __init__(out self):
        self.children = List[_Child]()

    def __len__(self) -> Int:
        return len(self.children)

    def start(
        mut self, tag: Int, argv: List[String], cwd: String, env: List[String], timeout: Float64 = 0
    ) raises:
        """Start `argv` in `cwd` with environment `env`; `timeout` in seconds
        (0: none). The child gets its own process group, so a timeout kills
        whatever it started too."""
        var fds = alloc_zero(8)
        if external_call["pipe", Int32](fds.unsafe_ptr()) != 0:
            raise Error("pipe() failed")
        var fp = fds.unsafe_ptr().unsafe_bitcast[Int32]()
        var read_fd = fp[unsafe_offset=0]
        var write_fd = fp[unsafe_offset=1]

        var actions = alloc_zero(256)
        _ = external_call["posix_spawn_file_actions_init", Int32](actions.unsafe_ptr())
        var devnull = c_string("/dev/null")
        _ = external_call["posix_spawn_file_actions_addopen", Int32](
            actions.unsafe_ptr(), Int32(0), devnull.unsafe_ptr(), _O_RDONLY, UInt16(0)
        )
        _ = external_call["posix_spawn_file_actions_adddup2", Int32](actions.unsafe_ptr(), write_fd, Int32(1))
        _ = external_call["posix_spawn_file_actions_adddup2", Int32](actions.unsafe_ptr(), write_fd, Int32(2))
        _ = external_call["posix_spawn_file_actions_addclose", Int32](actions.unsafe_ptr(), read_fd)
        _ = external_call["posix_spawn_file_actions_addclose", Int32](actions.unsafe_ptr(), write_fd)
        # the other children's pipes: a child holding one open would keep its
        # sibling from ever reaching EOF
        for i in range(len(self.children)):
            if self.children[i].fd >= 0:
                _ = external_call["posix_spawn_file_actions_addclose", Int32](actions.unsafe_ptr(), self.children[i].fd)
        var c_cwd = c_string(cwd)
        _ = external_call["posix_spawn_file_actions_addchdir_np", Int32](actions.unsafe_ptr(), c_cwd.unsafe_ptr())

        var attr = alloc_zero(256)
        _ = external_call["posix_spawnattr_init", Int32](attr.unsafe_ptr())
        _ = external_call["posix_spawnattr_setflags", Int32](
            attr.unsafe_ptr(), _POSIX_SPAWN_SETPGROUP | _POSIX_SPAWN_SETSIGMASK
        )
        _ = external_call["posix_spawnattr_setpgroup", Int32](attr.unsafe_ptr(), Int32(0))
        # despell blocks SIGINT and SIGTERM for itself; the child shouldn't
        var no_signals = _signal_set(False)
        _ = external_call["posix_spawnattr_setsigmask", Int32](attr.unsafe_ptr(), no_signals.unsafe_ptr())

        var c_argv = _CStrings(argv)
        var c_env = _CStrings(env)
        var program = c_string(argv[0])
        var pid_buf = alloc_zero(8)
        var rc = external_call["posix_spawnp", Int32](
            pid_buf.unsafe_ptr(),
            program.unsafe_ptr(),
            actions.unsafe_ptr(),
            attr.unsafe_ptr(),
            c_argv.pointers.unsafe_ptr(),
            c_env.pointers.unsafe_ptr(),
        )
        _ = external_call["posix_spawn_file_actions_destroy", Int32](actions.unsafe_ptr())
        _ = external_call["posix_spawnattr_destroy", Int32](attr.unsafe_ptr())
        _ = external_call["close", Int32](write_fd)
        if rc != 0:
            _ = external_call["close", Int32](read_fd)
            raise Error("can't start " + argv[0] + " (posix_spawnp error " + String(rc) + ")")
        var pid = pid_buf.unsafe_ptr().unsafe_bitcast[Int32]()[unsafe_offset=0]
        var now = monotonic_ns()
        var deadline = now + Int(timeout * 1e9) if timeout > 0 else 0
        self.children.append(_Child(pid, read_fd, tag, now, deadline))

    def wait_any(mut self) raises -> Finished:
        """Wait for one child to finish, and return it."""
        if len(self.children) == 0:
            raise Error("wait_any() with no children")
        while True:
            if interrupted():
                self.kill_all()
                raise Error("interrupted")
            var now = monotonic_ns()
            for i in range(len(self.children)):
                var pid = self.children[i].pid
                var deadline = self.children[i].deadline_ns
                if deadline != 0 and now > deadline:
                    _ = external_call["kill", Int32](-pid, _SIGKILL)
                    _ = external_call["kill", Int32](pid, _SIGKILL)
                    var status = alloc_zero(4)
                    _ = external_call["waitpid", Int32](pid, status.unsafe_ptr(), Int32(0))
                    return self._finish(i, 0, True)
                var status = alloc_zero(4)
                var rc = external_call["waitpid", Int32](pid, status.unsafe_ptr(), _WNOHANG)
                if rc == pid:
                    # exited: take what's left in the pipe (a grandchild may
                    # hold it open, so don't wait for EOF)
                    self._drain(i)
                    var code = _exit_code(status.unsafe_ptr().unsafe_bitcast[Int32]()[unsafe_offset=0])
                    return self._finish(i, code, False)
            # wait for output, a timeout or (polled) an exit
            var n = len(self.children)
            var pollfds = alloc_zero(8 * n)
            var watched = 0
            for i in range(n):
                var fd = self.children[i].fd
                if fd >= 0:
                    _set_pollfd(pollfds, watched, fd)
                    watched += 1
            var wait_ms = 20
            if watched > 0:
                _ = external_call["poll", Int32](pollfds.unsafe_ptr(), Int32(watched), Int32(wait_ms))
                for i in range(n):
                    if self.children[i].fd >= 0:
                        self._read_some(i)
            else:
                _ = external_call["usleep", Int32](UInt32(wait_ms * 1000))

    def kill_all(mut self):
        """Kill every child (and what it started), and reap them."""
        for i in range(len(self.children)):
            var pid = self.children[i].pid
            _ = external_call["kill", Int32](-pid, _SIGKILL)
            _ = external_call["kill", Int32](pid, _SIGKILL)
            var status = alloc_zero(4)
            _ = external_call["waitpid", Int32](pid, status.unsafe_ptr(), Int32(0))
            if self.children[i].fd >= 0:
                _ = external_call["close", Int32](self.children[i].fd)
        self.children = List[_Child]()

    def _read_some(mut self, i: Int):
        """Read what's available on child `i`'s pipe without blocking."""
        var fd = self.children[i].fd
        var pfd = alloc_zero(8)
        _set_pollfd(pfd, 0, fd)
        while True:
            if external_call["poll", Int32](pfd.unsafe_ptr(), Int32(1), Int32(0)) <= 0:
                return
            var buf = alloc_zero(65536)
            var got = external_call["read", Int](fd, buf.unsafe_ptr(), 65536)
            if got <= 0:
                _ = external_call["close", Int32](fd)
                self.children[i].fd = -1
                return
            for k in range(got):
                self.children[i].output.append(buf[k])

    def _drain(mut self, i: Int):
        if self.children[i].fd >= 0:
            self._read_some(i)
            if self.children[i].fd >= 0:
                _ = external_call["close", Int32](self.children[i].fd)
                self.children[i].fd = -1

    def _finish(mut self, i: Int, code: Int, timed_out: Bool) -> Finished:
        if self.children[i].fd >= 0:
            _ = external_call["close", Int32](self.children[i].fd)
            self.children[i].fd = -1
        var child = self.children.pop(i)
        return Finished(child.tag, code, timed_out, string_from_bytes(child.output), seconds_since(child.start_ns))


def run_command(argv: List[String], cwd: String, env: List[String], timeout: Float64 = 0) raises -> Finished:
    """Run one command to completion."""
    var pool = ProcessPool()
    pool.start(0, argv, cwd, env, timeout)
    return pool.wait_any()
