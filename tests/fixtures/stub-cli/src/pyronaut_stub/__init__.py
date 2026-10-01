"""A stand-in for the Pyronaut CLI, used to test this action end to end.

The real CLI lives in `micronaut-projects/pyronaut` and provisions a GraalVM
toolchain, native launchers and an SDK classpath from its own GitHub releases.
None of that is this action's responsibility, and depending on it would make the
action's own CI need read access to a private repository.

What this stub does reproduce is everything the action actually contracts on:

* the `pyronaut --version` report the action parses to learn which GraalPy to
  install,
* a `setup` command that writes the manifest below `~/.pyronaut` and honours
  `--local-repository`, `--progress` and the other flags the action passes,
* a `doctor` command that exits non-zero when the environment is incomplete.
"""

from __future__ import annotations

import json
import os
import platform
import sys
from pathlib import Path

PYRONAUT_VERSION = "0.0.0.dev0"
MICRONAUT_CORE_VERSION = "5.2.3"
MICRONAUT_PLATFORM_VERSION = "5.1.0"
GRAALPY_VERSION = "25.4.4.1.1"
# The pyenv identifier, which the real CLI reports separately because it does
# not track the GraalPy version: 0.0.7 bundles GraalPy 25.4.4.1.1 but its
# interpreter is graalpy3.13-25.4.4.
GRAALPY_INTERPRETER = "graalpy3.13-25.4.4"
NATIVE_IMAGE_JDK = "25"

USAGE = "Usage: pyronaut [--version] <setup|doctor> [args...]\n"


def _platform() -> str:
    system = {"Darwin": "macos", "Linux": "linux"}.get(platform.system(), platform.system().lower())
    machine = {"arm64": "aarch64", "x86_64": "x64", "amd64": "x64"}.get(
        platform.machine().lower(), platform.machine().lower()
    )
    return f"{system}-{machine}"


def _print_version() -> int:
    print(f"Pyronaut: {PYRONAUT_VERSION}")
    print(f"Micronaut Core: {MICRONAUT_CORE_VERSION}")
    print(f"Micronaut Platform: {MICRONAUT_PLATFORM_VERSION}")
    print(f"GraalPy: {GRAALPY_VERSION}")
    print(f"GraalPy Interpreter: {GRAALPY_INTERPRETER}")
    print(f"Native Image JDK: {NATIVE_IMAGE_JDK}")
    return 0


def _option(argv: list[str], name: str) -> str | None:
    if name in argv:
        index = argv.index(name)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def _setup(argv: list[str]) -> int:
    java_home = os.environ.get("JAVA_HOME")
    if not java_home or not (Path(java_home) / "bin" / "java").exists():
        print("Unable to locate or provision a compatible GraalVM JDK (requires JDK 25+)", file=sys.stderr)
        return 3

    local_repository = _option(argv, "--local-repository") or str(Path.home() / ".m2" / "repository")
    manifest = Path.home() / ".pyronaut" / "setup" / PYRONAUT_VERSION / _platform() / "setup.json"
    manifest.parent.mkdir(parents=True, exist_ok=True)

    if manifest.is_file() and "--refresh" not in argv:
        print(f"Pyronaut setup is ready at {manifest}")
        return 0

    manifest.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "sdkVersion": PYRONAUT_VERSION,
                "platform": _platform(),
                "javaHome": str(Path(java_home).resolve()),
                "localRepository": local_repository,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"Pyronaut setup completed at {manifest}")
    return 0


def _doctor(argv: list[str]) -> int:
    del argv
    manifest_dir = Path.home() / ".pyronaut" / "setup" / PYRONAUT_VERSION / _platform()
    checks = [
        ("python", sys.version_info >= (3, 10), f"Python {platform.python_version()}"),
        ("java", bool(os.environ.get("JAVA_HOME")), os.environ.get("JAVA_HOME") or "JAVA_HOME is not set"),
        ("setup", (manifest_dir / "setup.json").is_file(), str(manifest_dir / "setup.json")),
    ]
    failures = 0
    for name, ok, detail in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {name:<8} {detail}")
        failures += 0 if ok else 1
    return 0 if failures == 0 else 1


def main() -> int:
    argv = sys.argv[1:]
    if not argv:
        sys.stderr.write(USAGE)
        return 2
    if argv[0] in {"-V", "--version"}:
        return _print_version()
    if argv[0] in {"-h", "--help"}:
        sys.stdout.write(USAGE)
        return 0
    if argv[0] == "setup":
        return _setup(argv[1:])
    if argv[0] == "doctor":
        return _doctor(argv[1:])
    sys.stderr.write(f"Unsupported command: {argv[0]}\n")
    sys.stderr.write(USAGE)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
