# shellcheck shell=bash
#
# Helpers shared by the setup-pyronaut composite steps.
#
# Sourced, never executed: every caller starts with `set -euo pipefail` of its own.
#
# macOS runners still provide bash 3.2, so nothing here may use bash 4 features
# (`local -n`, associative arrays, `mapfile`, `${var,,}`).

# Emit a step output. Always uses the heredoc form so values containing newlines,
# quotes or `=` survive intact.
set_output() {
  _write_delimited "${GITHUB_OUTPUT:-/dev/stdout}" "$1" "${2-}"
}

# Export an environment variable to the steps that follow this action.
export_env() {
  _write_delimited "${GITHUB_ENV:-/dev/stdout}" "$1" "${2-}"
  export "$1=${2-}"
}

_write_delimited() {
  local file="$1" name="$2" value="${3-}" delimiter
  delimiter="ghadelim_$(random_token)"
  {
    printf '%s<<%s\n' "$name" "$delimiter"
    printf '%s\n' "$value"
    printf '%s\n' "$delimiter"
  } >>"$file"
}

# Prepend a directory to PATH for the steps that follow this action.
prepend_path() {
  printf '%s\n' "$1" >>"${GITHUB_PATH:-/dev/stdout}"
  PATH="$1:$PATH"
  export PATH
}

random_token() {
  if [ -r /dev/urandom ]; then
    # A fixed-size read, hexdumped. Feeding `tr` straight from /dev/urandom
    # into a `head` makes `head` exit first and leaves `tr` writing to a closed
    # pipe, which printed "tr: write error: Broken pipe" into the log of every
    # step that set an output.
    head -c 8 /dev/urandom | od -An -tx1 | LC_ALL=C tr -d ' \n'
  else
    printf '%s%s' "$$" "${RANDOM:-0}"
  fi
}

group() { printf '::group::%s\n' "$*"; }
endgroup() { printf '::endgroup::\n'; }
notice() { printf '::notice::%s\n' "$*"; }
warn() { printf '::warning::%s\n' "$*"; }

fail() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

# Hash stdin into a short, key-safe digest.
short_hash() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum | cut -d' ' -f1)"
  else
    digest="$(shasum -a 256 | cut -d' ' -f1)"
  fi
  printf '%s' "$(printf '%s' "$digest" | cut -c1-16)"
}

# Reduce a value to characters that are safe inside a cache key.
sanitize_key() {
  printf '%s' "${1-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-'
}

# Resolve a path to an absolute, canonical one. The leaf need not exist yet.
absolute_path() {
  local path="$1" dir base
  # The patterns below match a literal tilde on purpose: that is what an
  # unexpanded `~` in an action input looks like by the time it reaches here.
  # shellcheck disable=SC2088
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#\~/}" ;;
  esac
  case "$path" in
    /*) ;;
    *) path="$PWD/$path" ;;
  esac
  if [ -d "$path" ]; then
    (cd "$path" && pwd -P)
    return 0
  fi
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [ -d "$dir" ]; then
    printf '%s/%s' "$(cd "$dir" && pwd -P)" "$base"
  else
    printf '%s' "$path"
  fi
}

# Read one field from the `pyronaut --version` report, e.g. `GraalPy: 25.3.4.1`.
version_field() {
  printf '%s\n' "$1" |
    awk -v label="$2" -F': *' '$1 == label { print $2; exit }' |
    tr -d '[:space:]'
}

# Print the meaningful lines of a multi-line input: trimmed, with blank lines
# and `#` comments dropped. Callers consume it with `while IFS= read -r`.
meaningful_lines() {
  printf '%s\n' "${1-}" | awk '
    { sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    /^$/ { next }
    /^#/ { next }
    { print }
  '
}

is_true() {
  case "$(printf '%s' "${1-}" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}
