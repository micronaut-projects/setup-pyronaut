#!/usr/bin/env bash
#
# Install the Pyronaut CLI into a dedicated CPython virtual environment and
# report the versions it bundles.
#
# The CLI lives in its own CPython environment rather than in the GraalPy one:
# Pyronaut looks for the project's `.venv` when it launches applications and
# tests, and keeping the orchestrator out of that environment stops the CLI's
# own dependencies from leaking into the runtime the tests see.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

readonly MINIMUM_PYTHON="3.10"

# Never build the environment with an interpreter that lives inside it.
#
# Using the action twice in one job leaves the first run's CLI venv on PATH,
# and that venv supplies `python`, `python3` and `python3.X` alike — so every
# name resolves into the directory this run is about to `rm -rf`, and `-m venv`
# then dies on a deleted interpreter. Skipping the offending PATH entries
# rather than the names is what finds the system interpreter behind them.
find_python() {
  local name dir candidate paths
  paths="$(printf '%s' "$PATH" | tr ':' '\n')"
  for name in python3.13 python3.12 python3.11 python3.10 python3 python; do
    while IFS= read -r dir; do
      [ -n "$dir" ] || continue
      case "$dir" in
        "$CLI_VENV_DIR" | "$CLI_VENV_DIR"/*) continue ;;
      esac
      candidate="$dir/$name"
      [ -x "$candidate" ] || continue
      # GraalPy would satisfy the version check but is not what the
      # orchestrator should run on, so require CPython explicitly.
      if "$candidate" -c 'import sys; raise SystemExit(0 if sys.implementation.name == "cpython" and sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
        printf '%s' "$candidate"
        return 0
      fi
    done <<EOF
$paths
EOF
  done
  return 1
}

python="$(find_python)" ||
  fail "No CPython ${MINIMUM_PYTHON}+ interpreter found on PATH. Add actions/setup-python before this action."
printf 'CLI interpreter: %s (%s)\n' "$python" "$("$python" --version 2>&1)"

# Resolve what to install before touching the virtual environment, so a bad
# input fails before anything is written.
requirement=""
if [ -n "${INPUT_PYRONAUT_WHEEL:-}" ]; then
  wheel="$INPUT_PYRONAUT_WHEEL"
  case "$wheel" in
    http://* | https://* | file://*)
      requirement="$wheel"
      ;;
    *)
      # Word-splitting on the glob expansion is exactly what is wanted here:
      # the input may name a pattern such as `build/wheel/dist/pyronaut-*.whl`.
      # shellcheck disable=SC2086
      set -- $wheel
      if [ "$#" -eq 0 ] || [ ! -e "$1" ]; then
        fail "pyronaut-wheel matched no file: $wheel"
      fi
      if [ "$#" -gt 1 ]; then
        fail "pyronaut-wheel matched $# files; it must match exactly one: $*"
      fi
      requirement="$(absolute_path "$1")"
      ;;
  esac
  printf 'Installing Pyronaut from wheel: %s\n' "$requirement"
else
  # Pyronaut is not on PyPI; its wheel is attached to each GitHub release, so
  # fetch it from there with the same token `pyronaut setup` uses.
  version="$(printf '%s' "${INPUT_PYRONAUT_VERSION:-latest}" | tr -d '[:space:]')"
  case "$version" in
    '='* | '>'* | '<'* | '!'* | '~'*)
      fail "pyronaut-version must be \`latest\` or an exact version such as 0.0.4, not a specifier: $version"
      ;;
  esac
  repository="${INPUT_PYRONAUT_REPOSITORY:-micronaut-projects/pyronaut}"
  wheel_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pyronaut-wheel"
  rm -rf "$wheel_dir"
  requirement="$("$python" "$(dirname "$0")/release-wheel.py" \
    --repository "$repository" --version "${version:-latest}" --dest "$wheel_dir")" ||
    fail "Could not download the Pyronaut wheel from releases of $repository"
  printf 'Installing Pyronaut from GitHub release wheel: %s\n' "$requirement"
fi

group "Creating CLI environment at $CLI_VENV_DIR"
rm -rf "$CLI_VENV_DIR"
"$python" -m venv "$CLI_VENV_DIR"
venv_python="$CLI_VENV_DIR/bin/python"
"$venv_python" -m pip install --disable-pip-version-check --quiet --upgrade pip
endgroup

group "Installing $requirement"
"$venv_python" -m pip install --disable-pip-version-check --upgrade "$requirement"
endgroup

pyronaut="$CLI_VENV_DIR/bin/pyronaut"
[ -x "$pyronaut" ] || fail "The installed wheel provides no 'pyronaut' executable in $CLI_VENV_DIR/bin"

report="$("$pyronaut" --version 2>&1)" || {
  printf '%s\n' "$report" >&2
  fail "'pyronaut --version' failed"
}
printf '%s\n' "$report"

pyronaut_version="$(version_field "$report" "Pyronaut")"
graalpy_version="$(version_field "$report" "GraalPy")"
# Newer CLIs name the pyenv interpreter outright. That matters because the
# GraalPy version and the interpreter's version suffix have diverged: 0.0.7
# reports GraalPy 25.4.4.1.1 but its interpreter is graalpy3.13-25.4.4, and
# only the latter is a pyenv identifier.
graalpy_interpreter="$(version_field "$report" "GraalPy Interpreter")"
micronaut_core_version="$(version_field "$report" "Micronaut Core")"
native_image_jdk="$(version_field "$report" "Native Image JDK")"

[ -n "$pyronaut_version" ] || fail "Could not read the Pyronaut version from 'pyronaut --version'"
case "$graalpy_version" in
  '' | unknown)
    graalpy_version=""
    warn "The installed Pyronaut CLI does not report a bundled GraalPy version; set the 'graalpy-version' input explicitly."
    ;;
esac

prepend_path "$CLI_VENV_DIR/bin"

set_output "pyronaut" "$pyronaut"
set_output "pyronaut-version" "$pyronaut_version"
set_output "graalpy-version" "$graalpy_version"
set_output "graalpy-interpreter" "$graalpy_interpreter"
set_output "micronaut-core-version" "$micronaut_core_version"
set_output "native-image-jdk" "$native_image_jdk"
