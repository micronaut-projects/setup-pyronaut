#!/usr/bin/env bash
#
# Decide which GraalPy to install, where its virtual environment goes, and what
# cache key covers both. Kept separate from the install step so the cache can be
# restored before any download happens.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

if [ -n "${INPUT_VENV_DIR:-}" ]; then
  venv_dir="$(absolute_path "$INPUT_VENV_DIR")"
else
  # Pyronaut uses a project-local `.venv` for both `run` and `test` when one is
  # present, so that is where the GraalPy environment belongs by default.
  venv_dir="$PROJECT_DIR/.venv"
fi
set_output "venv-dir" "$venv_dir"

if ! is_true "${INPUT_GRAALPY:-true}"; then
  printf 'GraalPy setup disabled; `pyronaut test` will not run without a GraalPy environment.\n'
  set_output "graalpy-version" ""
  set_output "pyenv-version" ""
  set_output "venv-marker" ""
  set_output "cache-key" ""
  exit 0
fi

requested="$(printf '%s' "${INPUT_GRAALPY_VERSION:-}" | tr -d '[:space:]')"
if [ -z "$requested" ]; then
  requested="$(printf '%s' "${CLI_GRAALPY_VERSION:-}" | tr -d '[:space:]')"
  [ -n "$requested" ] || fail \
    "Could not determine which GraalPy to install. Set the 'graalpy-version' input, or use a Pyronaut CLI that reports its bundled GraalPy version."
  printf 'Using the GraalPy version bundled with the Pyronaut CLI: %s\n' "$requested"
fi

case "$requested" in
  graalpy*)
    # Already a pyenv identifier, e.g. `graalpy3.13-25.3.4.1`.
    pyenv_version="$requested"
    graalpy_version="${requested##*-}"
    ;;
  *)
    python_version="$(printf '%s' "${INPUT_GRAALPY_PYTHON_VERSION:-3.13}" | tr -d '[:space:]')"
    pyenv_version="graalpy${python_version}-${requested}"
    graalpy_version="$requested"
    ;;
esac

pytest_version="$(printf '%s' "${INPUT_PYTEST_VERSION:-latest}" | tr -d '[:space:]')"
case "$pytest_version" in
  '' | latest) pytest_requirement="pytest" ;;
  '='* | '>'* | '<'* | '!'* | '~'*) pytest_requirement="pytest$pytest_version" ;;
  *) pytest_requirement="pytest==$pytest_version" ;;
esac

# The marker is written into the environment and compared on a cache hit, so a
# restored-but-mismatched environment is rebuilt instead of silently used.
extra_packages="$(meaningful_lines "${INPUT_PYTHON_PACKAGES:-}")"
venv_marker="$pyenv_version $pytest_requirement"
if [ -n "$extra_packages" ]; then
  venv_marker="$venv_marker $(printf '%s' "$extra_packages" | tr '\n' ' ')"
fi

cache_key="$CACHE_KEY_BASE-graalpy-$(sanitize_key "$pyenv_version")-$(printf '%s' "$venv_marker" | short_hash)"

set_output "graalpy-version" "$graalpy_version"
set_output "pyenv-version" "$pyenv_version"
set_output "pytest-requirement" "$pytest_requirement"
set_output "venv-marker" "$venv_marker"
set_output "cache-key" "$cache_key"

printf 'GraalPy:      %s (pyenv %s)\n' "$graalpy_version" "$pyenv_version"
printf 'Environment:  %s\n' "$venv_dir"
printf 'Requirements: %s\n' "$venv_marker"
printf 'Cache key:    %s\n' "$cache_key"
