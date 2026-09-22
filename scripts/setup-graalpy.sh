#!/usr/bin/env bash
#
# Install GraalPy through pyenv and build the project's GraalPy virtual
# environment with pytest in it.
#
# `pyronaut test` runs pytest on the embedded GraalPy runtime, and a CPython
# environment cannot supply packages to it — so the environment the project
# points at has to be created by GraalPy itself.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

export PYENV_ROOT
PATH="$PYENV_ROOT/bin:$PATH"
export PATH

marker_file="$VENV_DIR/.setup-pyronaut-marker"

group "Installing GraalPy $PYENV_GRAALPY_VERSION"
if [ ! -x "$PYENV_ROOT/bin/pyenv" ]; then
  printf 'Cloning pyenv into %s\n' "$PYENV_ROOT"
  rm -rf "$PYENV_ROOT"
  git clone --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
fi

# GraalPy is distributed as a prebuilt archive, so `pyenv install` only
# downloads and unpacks it — no compiler toolchain is involved.
if ! pyenv install --skip-existing "$PYENV_GRAALPY_VERSION"; then
  printf '::error::pyenv could not install %s. Run `pyenv install --list | grep graalpy` to see the available identifiers.\n' \
    "$PYENV_GRAALPY_VERSION" >&2
  exit 1
fi
pyenv rehash
endgroup

graalpy_home="$PYENV_ROOT/versions/$PYENV_GRAALPY_VERSION"
graalpy=""
for candidate in "$graalpy_home/bin/graalpy" "$graalpy_home/bin/python"; do
  if [ -x "$candidate" ]; then
    graalpy="$candidate"
    break
  fi
done
[ -n "$graalpy" ] || fail "pyenv reported $PYENV_GRAALPY_VERSION as installed but $graalpy_home/bin has no interpreter"

# Collect everything that must be present in the environment.
requirements=("$PYTEST_REQUIREMENT")
while IFS= read -r package; do
  [ -n "$package" ] || continue
  requirements+=("$package")
done <<EOF
$(meaningful_lines "${INPUT_PYTHON_PACKAGES:-}")
EOF

venv_python="$VENV_DIR/bin/python"
if [ -x "$venv_python" ] &&
  [ -f "$marker_file" ] &&
  [ "$(cat "$marker_file")" = "$VENV_MARKER" ] &&
  "$venv_python" -c 'import sys' >/dev/null 2>&1; then
  printf 'Reusing the cached GraalPy environment at %s\n' "$VENV_DIR"
else
  group "Creating the GraalPy environment at $VENV_DIR"
  # A restored environment that fails any of the checks above is stale or was
  # built for a different path; rebuilding is cheaper than debugging it.
  rm -rf "$VENV_DIR"
  "$graalpy" -m venv "$VENV_DIR"
  "$venv_python" -m pip install --disable-pip-version-check --quiet --upgrade pip
  # `--no-compile` keeps the cached environment small; GraalPy compiles on first
  # import anyway.
  "$venv_python" -m pip install --disable-pip-version-check --no-compile "${requirements[@]}"
  printf '%s' "$VENV_MARKER" >"$marker_file"
  endgroup
fi

group "Verifying the GraalPy environment"
"$venv_python" -c 'import sys; assert "graal" in sys.version.lower(), sys.version; print(sys.version)'
"$venv_python" -c 'import pytest; print("pytest", pytest.__version__)'
endgroup

# Pyronaut falls back to a pyenv-selected GraalPy when a project has no `.venv`;
# exporting these makes `pyronaut doctor` agree with what this action installed,
# without putting pyenv shims on PATH where they would shadow the runner Python.
export_env "PYENV_ROOT" "$PYENV_ROOT"
export_env "PYENV_VERSION" "$PYENV_GRAALPY_VERSION"

if is_true "${INPUT_ACTIVATE_VENV:-false}"; then
  export_env "VIRTUAL_ENV" "$VENV_DIR"
  prepend_path "$VENV_DIR/bin"
  printf 'Activated %s; `python` is now GraalPy for the rest of this job.\n' "$VENV_DIR"
fi

set_output "python" "$venv_python"
set_output "graalpy-home" "$graalpy_home"
