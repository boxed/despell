"""Project configuration and locating a working `mojo`."""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

MUTANTS_DIR = "mutants"


@dataclass
class Config:
    root: Path
    paths_to_mutate: list[str]
    tests_dir: str
    include_dirs: list[str]
    also_copy: list[str] = field(default_factory=list)
    do_not_mutate: list[str] = field(default_factory=list)
    build_args: list[str] = field(default_factory=list)
    mojo: list[str] | None = None
    timeout_multiplier: float = 10.0
    timeout_floor: float = 2.0

    @property
    def mutants_dir(self) -> Path:
        return self.root / MUTANTS_DIR


class ConfigError(Exception):
    pass


def _read_toml_section(path: Path, *keys: str) -> dict | None:
    if not path.exists():
        return None
    data = tomllib.loads(path.read_text())
    for k in keys:
        if not isinstance(data, dict) or k not in data:
            return None
        data = data[k]
    return data


def load_config(root: Path) -> Config:
    raw = (
        _read_toml_section(root / "despell.toml")
        or _read_toml_section(root / "pixi.toml", "tool", "despell")
        or _read_toml_section(root / "pyproject.toml", "tool", "despell")
        or {}
    )
    known = {
        "paths_to_mutate", "tests_dir", "include_dirs", "also_copy", "do_not_mutate",
        "build_args", "mojo", "timeout_multiplier", "timeout_floor",
    }
    unknown = set(raw) - known
    if unknown:
        raise ConfigError(f"unknown config keys: {', '.join(sorted(unknown))}")

    paths = raw.get("paths_to_mutate")
    if paths is None:
        paths = ["src"] if (root / "src").is_dir() else ["."]
    tests_dir = raw.get("tests_dir")
    if tests_dir is None:
        tests_dir = next((d for d in ("tests", "test") if (root / d).is_dir()), None)
        if tests_dir is None:
            raise ConfigError("no tests directory found; set tests_dir in despell.toml")
    include_dirs = raw.get("include_dirs")
    if include_dirs is None:
        include_dirs = [p for p in paths if (root / p).is_dir()]
    mojo = raw.get("mojo")
    if isinstance(mojo, str):
        mojo = shlex.split(mojo)

    return Config(
        root=root,
        paths_to_mutate=list(paths),
        tests_dir=tests_dir,
        include_dirs=list(include_dirs),
        also_copy=list(raw.get("also_copy", [])),
        do_not_mutate=list(raw.get("do_not_mutate", [])),
        build_args=list(raw.get("build_args", [])),
        mojo=mojo,
        timeout_multiplier=float(raw.get("timeout_multiplier", 10.0)),
        timeout_floor=float(raw.get("timeout_floor", 2.0)),
    )


@dataclass
class MojoEnv:
    command: list[str]
    env: dict[str, str]


def _find_pixi_manifest(start: Path) -> Path | None:
    for d in [start, *start.parents]:
        if (d / "pixi.toml").exists():
            return d / "pixi.toml"
    return None


def find_mojo(config: Config) -> MojoEnv:
    """Find a `mojo` that can compile, plus the environment it needs.

    Running `mojo` from a pixi env without activation fails to find `std`, so
    when `mojo` is not already on PATH we capture the activated environment
    from `pixi run` once and reuse it for every build.
    """
    env = dict(os.environ)
    if override := os.environ.get("DESPELL_MOJO"):
        return MojoEnv(shlex.split(override), env)
    if config.mojo:
        return MojoEnv(config.mojo, env)
    if shutil.which("mojo"):
        return MojoEnv(["mojo"], env)

    manifest = _find_pixi_manifest(config.root)
    pixi = shutil.which("pixi")
    if manifest and pixi:
        out = subprocess.run(
            [pixi, "run", "--manifest-path", str(manifest), sys.executable, "-c",
             "import json, os; print(json.dumps(dict(os.environ)))"],
            capture_output=True, text=True, cwd=config.root,
        )
        if out.returncode == 0:
            pixi_env = json.loads(out.stdout.strip().splitlines()[-1])
            path = shutil.which("mojo", path=pixi_env.get("PATH"))
            if path:
                return MojoEnv([path], pixi_env)
    raise ConfigError(
        "could not find mojo: put it on PATH, set DESPELL_MOJO, or set `mojo` in despell.toml"
    )
