#!/usr/bin/env bash
#
# Record what was provisioned in the job summary, so a cache miss is visible
# without reading through the step logs.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

cache_state() {
  case "${1:-}" in
    true) printf 'hit' ;;
    false) printf 'miss' ;;
    *) printf 'disabled' ;;
  esac
}

row() {
  [ -n "${2:-}" ] || return 0
  printf '| %s | `%s` |\n' "$1" "$2"
}

{
  printf '### Pyronaut\n\n'
  printf '| | |\n| --- | --- |\n'
  row "Pyronaut" "${PYRONAUT_VERSION:-}"
  row "Micronaut Core" "${MICRONAUT_CORE_VERSION:-}"
  row "GraalVM" "${GRAALVM_LABEL:-}"
  row "JAVA_HOME" "${JAVA_HOME_USED:-}"
  row "GraalPy" "${GRAALPY_PYENV_VERSION:-not installed}"
  # Without GraalPy there is no environment, only the path one would have gone
  # to, which would read as if something had been created there.
  if [ -n "${GRAALPY_PYENV_VERSION:-}" ]; then
    row "GraalPy environment" "${VENV_DIR:-}"
  fi
  row "Pyronaut home" "${PYRONAUT_HOME:-}"
  row "Maven repository" "${LOCAL_REPOSITORY:-}"
  case "${NATIVE_LAUNCHERS:-}" in
    true) row "Native launchers" "downloaded during setup" ;;
    false) row "Native launchers" "on first use" ;;
  esac
  row "SDK cache" "$(cache_state "${SDK_CACHE_HIT:-}")"
  # The launchers are only cached when the job provisions them; for a JVM-only
  # job the row would only ever say `disabled`, which reads as a misconfiguration.
  if [ "${NATIVE_LAUNCHERS:-}" = true ]; then
    row "Launcher cache" "$(cache_state "${LAUNCHERS_CACHE_HIT:-}")"
  fi
  row "GraalPy cache" "$(cache_state "${GRAALPY_CACHE_HIT:-}")"
  printf '\n'
} >>"${GITHUB_STEP_SUMMARY:-/dev/stdout}"
