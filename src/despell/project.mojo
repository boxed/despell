"""Project configuration and locating a working `mojo`."""

from std.ffi import external_call
from std.os.path import isdir, isfile

from .fsutil import join, parent, read_text, real_path, path_exists
from .jsonio import Json
from .sysutil import c_string, env_value, environment, run_command, with_env
from .toml import read_table

comptime MUTANTS_DIR = "mutants"
comptime _KNOWN_KEYS = (
    " paths_to_mutate tests_dir include_dirs also_copy do_not_mutate build_args mojo"
    " timeout_multiplier timeout_floor "
)


struct Config(Copyable, Movable):
    var root: String  # absolute
    var paths_to_mutate: List[String]
    var tests_dir: String
    var include_dirs: List[String]
    var also_copy: List[String]
    var do_not_mutate: List[String]
    var build_args: List[String]
    var mojo: List[String]  # empty: find one
    var timeout_multiplier: Float64
    var timeout_floor: Float64

    def __init__(out self, root: String, var paths_to_mutate: List[String], tests_dir: String, var include_dirs: List[String]):
        self.root = root
        self.paths_to_mutate = paths_to_mutate^
        self.tests_dir = tests_dir
        self.include_dirs = include_dirs^
        self.also_copy = List[String]()
        self.do_not_mutate = List[String]()
        self.build_args = List[String]()
        self.mojo = List[String]()
        self.timeout_multiplier = 10.0
        self.timeout_floor = 2.0

    def mutants_dir(self) -> String:
        return join(self.root, MUTANTS_DIR)


def _section(path: String, table: String) raises -> Optional[Json]:
    if not isfile(path):
        return None
    return read_table(read_text(path), table)


def split_words(text: String) -> List[String]:
    var out = List[String]()
    for w in text.split(" "):
        if String(w).byte_length():
            out.append(String(w))
    return out^


def load_config(root: String) raises -> Config:
    var raw = _section(join(root, "despell.toml"), "")
    if not raw:
        raw = _section(join(root, "pixi.toml"), "tool.despell")
    if not raw:
        raw = _section(join(root, "pyproject.toml"), "tool.despell")
    var settings = raw.value().copy() if raw else Json.object()
    for key in settings.keys:
        if not (String(_KNOWN_KEYS).find(" " + key + " ") >= 0):
            raise Error("unknown config key: " + key)

    var paths = settings.str_list("paths_to_mutate")
    if not settings.has("paths_to_mutate"):
        paths = [String("src")] if isdir(join(root, "src")) else [String(".")]
    var tests_dir = settings.str_or("tests_dir", "")
    if tests_dir.byte_length() == 0:
        if isdir(join(root, "tests")):
            tests_dir = "tests"
        elif isdir(join(root, "test")):
            tests_dir = "test"
        else:
            raise Error("no tests directory found; set tests_dir in despell.toml")
    var include_dirs = settings.str_list("include_dirs")
    if not settings.has("include_dirs"):
        include_dirs = List[String]()
        for p in paths:
            if isdir(join(root, p)):
                include_dirs.append(p)
    var config = Config(root, paths^, tests_dir, include_dirs^)
    config.also_copy = settings.str_list("also_copy")
    config.do_not_mutate = settings.str_list("do_not_mutate")
    config.build_args = settings.str_list("build_args")
    var mojo = settings.get("mojo")
    if mojo.kind == 3:  # a string
        config.mojo = split_words(mojo.as_string())
    else:
        config.mojo = settings.str_list("mojo")
    config.timeout_multiplier = settings.float_or("timeout_multiplier", 10.0)
    config.timeout_floor = settings.float_or("timeout_floor", 2.0)
    return config^


struct MojoEnv(Copyable, Movable):
    var command: List[String]
    var env: List[String]  # NAME=value

    def __init__(out self, var command: List[String], var env: List[String]):
        self.command = command^
        self.env = env^


def which(name: String, path_var: String) -> String:
    """The executable `name` on `path_var` (a PATH value), or ""."""
    if "/" in name:
        return name if isfile(name) else String("")
    for d in path_var.split(":"):
        var candidate = join(String(d), name)
        var c = c_string(candidate)
        if isfile(candidate) and external_call["access", Int32](c.unsafe_ptr(), Int32(1)) == 0:
            return candidate
    return String("")


def _env_for(mojo: String, env: List[String]) -> List[String]:
    """The environment a `mojo` inside a conda/pixi env needs to find `std`."""
    var bin = parent(mojo)
    var prefix = parent(bin)
    if bin.endswith("/bin") and isdir(join(prefix, "share/max")):
        return with_env(
            env,
            [
                "CONDA_PREFIX=" + prefix,
                "MODULAR_HOME=" + join(prefix, "share/max"),
                "PATH=" + bin + ":" + env_value(env, "PATH"),
            ],
        )
    return env.copy()


def _find_pixi_manifest(start: String) -> String:
    var d = start
    while True:
        if isfile(join(d, "pixi.toml")):
            return join(d, "pixi.toml")
        var up = parent(d)
        if up == d or up.byte_length() == 0:
            return String("")
        d = up


def find_mojo(config: Config) raises -> MojoEnv:
    """Find a `mojo` that can compile, plus the environment it needs.

    Running `mojo` from a pixi env without activation fails to find `std`, so
    when `mojo` is not already on PATH we capture the activated environment
    from `pixi run` once and reuse it for every build.
    """
    var env = environment()
    var override = env_value(env, "DESPELL_MOJO")
    if override.byte_length():
        return MojoEnv(split_words(override), env^)
    if len(config.mojo) > 0:
        var e = _env_for(config.mojo[0], env)
        return MojoEnv(config.mojo.copy(), e^)
    var path = env_value(env, "PATH")
    if which("mojo", path).byte_length():
        return MojoEnv([String("mojo")], env^)

    var manifest = _find_pixi_manifest(config.root)
    var pixi = which("pixi", path)
    if manifest.byte_length() and pixi.byte_length():
        var result = run_command([pixi, String("run"), String("--manifest-path"), manifest, String("env"), String("-0")], config.root, env)
        if result.code == 0:
            var pixi_env = List[String]()
            for entry in result.output.split("\0"):
                if "=" in entry:
                    pixi_env.append(String(entry))
            var mojo = which("mojo", env_value(pixi_env, "PATH"))
            if mojo.byte_length():
                return MojoEnv([mojo], pixi_env^)
    raise Error("could not find mojo: put it on PATH, set DESPELL_MOJO, or set `mojo` in despell.toml")
