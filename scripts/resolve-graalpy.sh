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
  set_output "requirements-files" ""
  set_output "install-project" "false"
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

# -- the project's own Python dependencies -----------------------------------
#
# Pyronaut resolves Java dependencies itself, but Python packages come only
# from the project environment — `pyronaut doctor` fails a project whose
# `[project].dependencies` are not importable from `.venv`, and its suggested
# fix is `graalpy -m venv .venv && .venv/bin/python -m pip install -e .`.
# Installing pytest alone would leave every such project broken, so the project
# is installed here too. requirements.txt is not something Pyronaut reads, but
# it is common enough in Python projects to be worth honouring.

pyproject="$PROJECT_DIR/pyproject.toml"

# The distribution names in `[project].dependencies`, ignoring requirements
# that only apply to an extra — the same rule the CLI's own reader uses.
#
# This reads the common TOML shapes rather than parsing TOML properly, because
# there is no TOML reader to rely on: tomllib only arrives in Python 3.11 and
# the CLI supports 3.10. An unrecognized shape degrades gracefully — `auto`
# just does not install, and `install-project: true` forces it.
declared_dependencies() {
  [ -f "$pyproject" ] || return 0
  awk '
    /^[[:space:]]*\[/ { in_project = ($0 ~ /^[[:space:]]*\[project\][[:space:]]*$/); in_deps = 0 }
    in_project && /^[[:space:]]*dependencies[[:space:]]*=/ { in_deps = 1 }
    in_deps {
      if ($0 ~ /\]/) { print; in_deps = 0; next }
      print
    }
  ' "$pyproject" |
    grep -o '"[^"]*"' |
    tr -d '"' |
    awk '{ if (index($0, ";") > 0) { marker = substr($0, index($0, ";")) } else { marker = "" } }
         marker !~ /extra/ { print }'
}

install_project="$(printf '%s' "${INPUT_INSTALL_PROJECT:-auto}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$install_project" in
  auto)
    if [ -n "$(declared_dependencies)" ]; then
      install_project=true
    else
      # Nothing declared, so an editable install would only risk failing on a
      # project that never asked for one.
      install_project=false
    fi
    ;;
  true | 1 | yes | on)
    [ -f "$pyproject" ] || fail "install-project is set but there is no pyproject.toml in $PROJECT_DIR"
    install_project=true
    ;;
  false | 0 | no | off) install_project=false ;;
  *) fail "Input 'install-project' must be auto, true or false, but was '${INPUT_INSTALL_PROJECT:-}'" ;;
esac

requirements_input="$(printf '%s' "${INPUT_REQUIREMENTS:-auto}" | tr -d '[:space:]')"
requirements_files=""
case "$(printf '%s' "$requirements_input" | tr '[:upper:]' '[:lower:]')" in
  auto)
    if [ -f "$PROJECT_DIR/requirements.txt" ]; then
      requirements_files="$PROJECT_DIR/requirements.txt"
    fi
    ;;
  '' | false | 0 | no | off) ;;
  *)
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      resolved="$(absolute_path "$candidate")"
      [ -f "$resolved" ] || fail "requirements file does not exist: $resolved"
      requirements_files="${requirements_files:+$requirements_files
}$resolved"
    done <<EOF
$(meaningful_lines "${INPUT_REQUIREMENTS:-}")
EOF
    ;;
esac

# The marker is written into the environment and compared on a cache hit, so a
# restored-but-mismatched environment is rebuilt instead of silently used. The
# requirement files and the project metadata go in by content hash: editing a
# dependency has to rebuild the environment, not reuse a cached one.
extra_packages="$(meaningful_lines "${INPUT_PYTHON_PACKAGES:-}")"
venv_marker="$pyenv_version $pytest_requirement"
if [ -n "$extra_packages" ]; then
  venv_marker="$venv_marker $(printf '%s' "$extra_packages" | tr '\n' ' ')"
fi
while IFS= read -r file; do
  [ -n "$file" ] || continue
  venv_marker="$venv_marker -r:$(short_hash <"$file")"
done <<EOF
$requirements_files
EOF
if [ "$install_project" = true ]; then
  venv_marker="$venv_marker -e:$(short_hash <"$pyproject")"
fi

cache_key="$CACHE_KEY_BASE-graalpy-$(sanitize_key "$pyenv_version")-$(printf '%s' "$venv_marker" | short_hash)"

set_output "graalpy-version" "$graalpy_version"
set_output "pyenv-version" "$pyenv_version"
set_output "pytest-requirement" "$pytest_requirement"
set_output "requirements-files" "$requirements_files"
set_output "install-project" "$install_project"
set_output "venv-marker" "$venv_marker"
set_output "cache-key" "$cache_key"

printf 'GraalPy:      %s (pyenv %s)\n' "$graalpy_version" "$pyenv_version"
printf 'Environment:  %s\n' "$venv_dir"
printf 'Requirements: %s\n' "$venv_marker"
if [ -n "$requirements_files" ]; then
  printf 'Requirement files:\n'
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '  %s\n' "$file"
  done <<EOF
$requirements_files
EOF
fi
printf 'Install project (pip install -e .): %s\n' "$install_project"
printf 'Cache key:    %s\n' "$cache_key"
