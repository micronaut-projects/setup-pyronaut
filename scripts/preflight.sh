#!/usr/bin/env bash
#
# Validate the runner and settle every path and cache-key component that the
# later steps depend on. Runs before anything is downloaded so an unsupported
# runner fails in seconds rather than after a GraalVM install.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

case "${RUNNER_OS:-}" in
  Linux | macOS) ;;
  Windows)
    fail "Pyronaut supports macOS and Linux only; this job runs on Windows. Use a ubuntu-* or macos-* runner."
    ;;
  *)
    warn "Unrecognized runner OS '${RUNNER_OS:-}'. Continuing, but only macOS and Linux are supported."
    ;;
esac

# Normalize the boolean inputs to exactly `true` or `false` and publish them as
# outputs. The `if:` conditions in action.yml compare against the string
# `'true'` and have no notion of `yes` or `on`, so a step guarded by an input
# would disagree with a script that reads the same input through `is_true`.
# Deciding it once, here, keeps the two in step — and rejects a typo outright
# instead of quietly treating it as off.
#
# `fail` inside a command substitution would only exit that subshell, so each
# value goes through a plain assignment: `set -e` propagates the failure from
# those.
normalize_boolean() {
  local name="$1" value="${2-}"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    true | 1 | yes | on) printf 'true' ;;
    false | 0 | no | off) printf 'false' ;;
    *) fail "Input '$name' must be true or false, but was '$value'" ;;
  esac
}

graalvm="$(normalize_boolean graalvm "${INPUT_GRAALVM:-}")"
graalpy="$(normalize_boolean graalpy "${INPUT_GRAALPY:-}")"
activate_venv="$(normalize_boolean activate-venv "${INPUT_ACTIVATE_VENV:-}")"
run_setup="$(normalize_boolean run-setup "${INPUT_RUN_SETUP:-}")"
run_doctor="$(normalize_boolean run-doctor "${INPUT_RUN_DOCTOR:-}")"
cache="$(normalize_boolean cache "${INPUT_CACHE:-}")"
cache_maven="$(normalize_boolean cache-maven "${INPUT_CACHE_MAVEN:-}")"

set_output "graalvm" "$graalvm"
set_output "graalpy" "$graalpy"
set_output "activate-venv" "$activate_venv"
set_output "run-setup" "$run_setup"
set_output "run-doctor" "$run_doctor"
set_output "cache" "$cache"
set_output "cache-maven" "$cache_maven"

project_dir="$(absolute_path "${INPUT_PROJECT_DIR:-.}")"
[ -d "$project_dir" ] || fail "project-dir does not exist: $project_dir"

pyronaut_home="$HOME/.pyronaut"
pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"

if [ -n "${INPUT_LOCAL_REPOSITORY:-}" ]; then
  local_repository="$(absolute_path "$INPUT_LOCAL_REPOSITORY")"
else
  local_repository="$HOME/.m2/repository"
fi

if [ -n "${INPUT_CLI_VENV_DIR:-}" ]; then
  cli_venv_dir="$(absolute_path "$INPUT_CLI_VENV_DIR")"
else
  cli_venv_dir="${RUNNER_TEMP:-$HOME}/pyronaut-cli-venv"
fi

# `uname -m` is the architecture Pyronaut itself keys its per-platform state on
# (`~/.pyronaut/setup/<version>/<os>-<arch>`), so caches must be keyed the same
# way or a restored manifest would point at binaries for the wrong platform.
arch="$(uname -m)"
case "$arch" in
  arm64 | aarch64) arch="aarch64" ;;
  x86_64 | amd64) arch="x64" ;;
esac

cache_key_base="$(sanitize_key "${INPUT_CACHE_KEY_PREFIX:-setup-pyronaut-v2}")-$(sanitize_key "${RUNNER_OS:-unknown}")-$(sanitize_key "$arch")"
if [ -n "${INPUT_CACHE_KEY_SUFFIX:-}" ]; then
  cache_key_base="$cache_key_base-$(sanitize_key "$INPUT_CACHE_KEY_SUFFIX")"
fi

mkdir -p "$pyronaut_home" "$local_repository"

set_output "project-dir" "$project_dir"
set_output "pyronaut-home" "$pyronaut_home"
set_output "pyenv-root" "$pyenv_root"
set_output "local-repository" "$local_repository"
set_output "cli-venv-dir" "$cli_venv_dir"
set_output "arch" "$arch"
set_output "cache-key-base" "$cache_key_base"

printf 'Runner:            %s %s\n' "${RUNNER_OS:-unknown}" "$arch"
printf 'Project directory: %s\n' "$project_dir"
printf 'Pyronaut home:     %s\n' "$pyronaut_home"
printf 'Maven repository:  %s\n' "$local_repository"
printf 'Cache key base:    %s\n' "$cache_key_base"
