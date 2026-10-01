#!/usr/bin/env bash
#
# Exercise the action's scripts outside of a runner.
#
# Everything that decides paths, versions and cache keys is covered here; the
# steps that download a JDK, GraalPy or the Pyronaut SDK are covered by the
# end-to-end workflow in .github/workflows instead.
#
# Usage: tests/run-tests.sh [name-filter]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPTS="$ROOT/scripts"
FILTER="${1:-}"

passed=0
failed=0

# -- harness -----------------------------------------------------------------

begin() {
  WORK="$(mktemp -d)"
  # Canonicalize it, because the scripts do. On macOS `mktemp -d` returns a
  # path under /var, which is a symlink to /private/var, while `absolute_path`
  # resolves with `pwd -P` and yields the /private/var form. Comparing a
  # script's output against the raw path would fail there for a difference
  # that is not a difference — and the canonicalization is deliberate, since
  # Pyronaut records these paths in its setup manifest and re-validates them.
  WORK="$(cd "$WORK" && pwd -P)"
  export GITHUB_OUTPUT="$WORK/outputs"
  export GITHUB_ENV="$WORK/env"
  export GITHUB_PATH="$WORK/path"
  export GITHUB_STEP_SUMMARY="$WORK/summary"
  export RUNNER_TEMP="$WORK/runner-temp"
  export HOME="$WORK/home"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_ENV"
  : >"$GITHUB_PATH"
  : >"$GITHUB_STEP_SUMMARY"
  mkdir -p "$RUNNER_TEMP" "$HOME"
}

end() {
  rm -rf "$WORK"
}

skip_test() {
  [ -z "$FILTER" ] && return 1
  case "$1" in
    *"$FILTER"*) return 1 ;;
    *) return 0 ;;
  esac
}

check() {
  local description="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    passed=$((passed + 1))
    printf '  ok   %s\n' "$description"
  else
    failed=$((failed + 1))
    printf '  FAIL %s\n' "$description"
    printf '         expected: %s\n' "$expected"
    printf '         actual:   %s\n' "$actual"
  fi
}

check_contains() {
  local description="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*)
      passed=$((passed + 1))
      printf '  ok   %s\n' "$description"
      ;;
    *)
      failed=$((failed + 1))
      printf '  FAIL %s\n' "$description"
      printf '         expected to contain: %s\n' "$needle"
      printf '         actual:              %s\n' "$haystack"
      ;;
  esac
}

# Read one value back out of the GITHUB_OUTPUT file, which uses the heredoc
# form `name<<delimiter ... delimiter`.
output() {
  awk -v name="$1" '
    index($0, name "<<") == 1 { delimiter = substr($0, length(name) + 3); collecting = 1; next }
    collecting && $0 == delimiter { exit }
    collecting { print }
  ' "$GITHUB_OUTPUT"
}

env_value() {
  awk -v name="$1" '
    index($0, name "<<") == 1 { delimiter = substr($0, length(name) + 3); collecting = 1; next }
    collecting && $0 == delimiter { exit }
    collecting { print }
  ' "$GITHUB_ENV"
}

test_case() {
  skip_test "$1" && return 0
  printf '%s\n' "$1"
  begin "$1"
  "$2"
  end
}

# -- fixtures ----------------------------------------------------------------

# Write a stub `java` that reports the given `java -version` banner.
stub_java_home() {
  local home="$1" banner="$2"
  mkdir -p "$home/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cat >&2 <<'"'"'BANNER'"'"'\n'
    printf '%s\n' "$banner"
    printf 'BANNER\n'
  } >"$home/bin/java"
  chmod +x "$home/bin/java"
}

readonly ORACLE_GRAALVM_25='java version "25.0.1" 2025-10-21
Java(TM) SE Runtime Environment Oracle GraalVM 25.0.1+8.1 (build 25.0.1+8-LTS-jvmci-b01)
Java HotSpot(TM) 64-Bit Server VM Oracle GraalVM 25.0.1+8.1 (build 25.0.1+8-LTS-jvmci-b01, mixed mode, sharing)'

readonly COMMUNITY_GRAALVM_25='openjdk version "25.0.1" 2025-10-21
OpenJDK Runtime Environment GraalVM CE 25.0.1+8.1 (build 25.0.1+8-jvmci-b01)
OpenJDK 64-Bit Server VM GraalVM CE 25.0.1+8.1 (build 25.0.1+8-jvmci-b01, mixed mode, sharing)'

readonly TEMURIN_21='openjdk version "21.0.5" 2024-10-15 LTS
OpenJDK Runtime Environment Temurin-21.0.5+11 (build 21.0.5+11-LTS)
OpenJDK 64-Bit Server VM Temurin-21.0.5+11 (build 21.0.5+11-LTS, mixed mode, sharing)'

# Build a pyenv root whose `pyenv` and GraalPy are stubs, so the reuse and
# rebuild branches of setup-graalpy.sh can be exercised without downloading a
# real GraalPy (the real install is covered by the end-to-end workflow).
stub_pyenv_root() {
  local root="$1" version="$2"
  mkdir -p "$root/bin" "$root/versions/$version/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$root/bin/pyenv"
  chmod +x "$root/bin/pyenv"
  # `graalpy -m venv <dir>` lays down just enough of an environment for the
  # script's own checks, and records that it was called.
  cat >"$root/versions/$version/bin/graalpy" <<'GRAALPY'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "venv" ]; then
  mkdir -p "$3/bin"
  printf '%s\n' "$3" >>"${STUB_VENV_LOG:?}"
  cp "$0" "$3/bin/python"
  exit 0
fi
if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pip" ]; then
  printf '%s\n' "$*" >>"${STUB_PIP_LOG:?}"
  exit 0
fi
printf 'GraalPy stub 3.13.14 (Graal, Oracle GraalVM)\n'
exit 0
GRAALPY
  chmod +x "$root/versions/$version/bin/graalpy"
}

run_setup_graalpy() {
  PYENV_ROOT="$WORK/pyenv" \
    PYENV_GRAALPY_VERSION="${PYENV_GRAALPY_VERSION:-graalpy3.13-25.3.4.1}" \
    PYTEST_REQUIREMENT="${PYTEST_REQUIREMENT:-pytest}" \
    VENV_DIR="$WORK/venv" \
    VENV_MARKER="${VENV_MARKER:-graalpy3.13-25.3.4.1 pytest}" \
    INPUT_PYTHON_PACKAGES="${INPUT_PYTHON_PACKAGES:-}" \
    INPUT_ACTIVATE_VENV="${INPUT_ACTIVATE_VENV:-false}" \
    REQUIREMENTS_FILES="${REQUIREMENTS_FILES:-}" \
    INSTALL_PROJECT="${INSTALL_PROJECT:-false}" \
    PROJECT_DIR="${PROJECT_DIR:-$WORK/project}" \
    STUB_VENV_LOG="$WORK/venv-created" \
    STUB_PIP_LOG="$WORK/pip-calls" \
    "$SCRIPTS/setup-graalpy.sh" 2>&1
}

# Lay down an environment that looks like one a cache restore produced.
stub_restored_venv() {
  mkdir -p "$WORK/venv/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/venv/bin/python"
  chmod +x "$WORK/venv/bin/python"
  printf '%s' "$1" >"$WORK/venv/.setup-pyronaut-marker"
}

# A `pyronaut` that records the arguments it was called with, so the argument
# assembly in run-setup.sh can be asserted on.
stub_pyronaut() {
  local exit_code="${1:-0}"
  mkdir -p "$WORK/bin"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >"%s/setup-args"\n' "$WORK"
    printf 'exit %s\n' "$exit_code"
  } >"$WORK/bin/pyronaut"
  chmod +x "$WORK/bin/pyronaut"
}

run_setup() {
  PYRONAUT="$WORK/bin/pyronaut" \
    INPUT_SETUP_ARGS="${INPUT_SETUP_ARGS:-}" \
    INPUT_LOCAL_REPOSITORY="${INPUT_LOCAL_REPOSITORY:-}" \
    LOCAL_REPOSITORY="${LOCAL_REPOSITORY:-$HOME/.m2/repository}" \
    PROJECT_DIR="${PROJECT_DIR:-$WORK}" \
    "$SCRIPTS/run-setup.sh" 2>&1
}

run_preflight() {
  INPUT_PROJECT_DIR="${INPUT_PROJECT_DIR:-.}" \
    INPUT_LOCAL_REPOSITORY="${INPUT_LOCAL_REPOSITORY:-}" \
    INPUT_CLI_VENV_DIR="${INPUT_CLI_VENV_DIR:-}" \
    INPUT_CACHE_KEY_PREFIX="${INPUT_CACHE_KEY_PREFIX:-setup-pyronaut-v1}" \
    INPUT_CACHE_KEY_SUFFIX="${INPUT_CACHE_KEY_SUFFIX:-}" \
    INPUT_GRAALVM="${INPUT_GRAALVM:-true}" \
    INPUT_GRAALPY="${INPUT_GRAALPY:-true}" \
    INPUT_ACTIVATE_VENV="${INPUT_ACTIVATE_VENV:-false}" \
    INPUT_RUN_SETUP="${INPUT_RUN_SETUP:-true}" \
    INPUT_RUN_DOCTOR="${INPUT_RUN_DOCTOR:-false}" \
    INPUT_CACHE="${INPUT_CACHE:-true}" \
    INPUT_CACHE_MAVEN="${INPUT_CACHE_MAVEN:-true}" \
    "$SCRIPTS/preflight.sh" 2>&1
}

# -- preflight ---------------------------------------------------------------

preflight_defaults() {
  mkdir -p "$WORK/project"
  local out
  out="$(cd "$WORK/project" && RUNNER_OS=Linux INPUT_PROJECT_DIR=. run_preflight 2>&1)"
  check "exits 0" "$?" "0"
  check "project-dir is absolute" "$(output project-dir)" "$(cd "$WORK/project" && pwd -P)"
  check "pyronaut-home under HOME" "$(output pyronaut-home)" "$HOME/.pyronaut"
  check "maven repository defaults to ~/.m2" "$(output local-repository)" "$HOME/.m2/repository"
  check "cli venv goes to RUNNER_TEMP" "$(output cli-venv-dir)" "$RUNNER_TEMP/pyronaut-cli-venv"
  check "creates the pyronaut home" "$([ -d "$HOME/.pyronaut" ] && echo yes)" "yes"
  check_contains "cache key names the OS" "$(output cache-key-base)" "setup-pyronaut-v1-Linux-"
  check_contains "logs the runner" "$out" "Runner:"
}

preflight_overrides() {
  mkdir -p "$WORK/project"
  RUNNER_OS=macOS INPUT_PROJECT_DIR="$WORK/project" INPUT_LOCAL_REPOSITORY="$WORK/m2" \
    INPUT_CLI_VENV_DIR="$WORK/cli" INPUT_CACHE_KEY_PREFIX="my prefix" INPUT_CACHE_KEY_SUFFIX="jdk/25" \
    run_preflight >/dev/null 2>&1
  check "honours local-repository" "$(output local-repository)" "$WORK/m2"
  check "honours cli-venv-dir" "$(output cli-venv-dir)" "$WORK/cli"
  check_contains "sanitizes the key prefix" "$(output cache-key-base)" "my-prefix-macOS-"
  check_contains "sanitizes the key suffix" "$(output cache-key-base)" "-jdk-25"
}

preflight_rejects_windows() {
  local out status
  out="$(RUNNER_OS=Windows INPUT_PROJECT_DIR=. run_preflight 2>&1)"
  status=$?
  check "fails on Windows" "$status" "1"
  check_contains "explains why" "$out" "macOS and Linux only"
}

preflight_rejects_missing_project() {
  local out status
  out="$(RUNNER_OS=Linux INPUT_PROJECT_DIR="$WORK/nope" run_preflight 2>&1)"
  status=$?
  check "fails on a missing project-dir" "$status" "1"
  check_contains "names the directory" "$out" "project-dir does not exist"
}

preflight_normalizes_booleans() {
  mkdir -p "$WORK/project"
  INPUT_PROJECT_DIR="$WORK/project" RUNNER_OS=Linux \
    INPUT_GRAALPY=yes INPUT_CACHE=Off INPUT_RUN_DOCTOR=1 INPUT_CACHE_MAVEN=NO \
    run_preflight >/dev/null
  check "accepts yes" "$(output graalpy)" "true"
  check "accepts Off" "$(output cache)" "false"
  check "accepts 1" "$(output run-doctor)" "true"
  check "accepts NO" "$(output cache-maven)" "false"
  check "passes true through" "$(output graalvm)" "true"
  check "passes false through" "$(output activate-venv)" "false"
}

preflight_rejects_a_bad_boolean() {
  mkdir -p "$WORK/project"
  local out status
  out="$(INPUT_PROJECT_DIR="$WORK/project" RUNNER_OS=Linux INPUT_GRAALPY=maybe run_preflight)"
  status=$?
  check "fails" "$status" "1"
  check_contains "names the input and the value" "$out" "Input 'graalpy' must be true or false, but was 'maybe'"
}

# -- verify-graalvm ----------------------------------------------------------

graalvm_accepts_oracle() {
  stub_java_home "$WORK/graalvm" "$ORACLE_GRAALVM_25"
  JAVA_HOME="$WORK/graalvm" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" >/dev/null 2>&1
  check "exits 0" "$?" "0"
  check "reports the java home" "$(output java-home)" "$WORK/graalvm"
  check "reads the feature version" "$(output java-feature-version)" "25"
  check "labels the distribution" "$(output graalvm-label)" "Oracle GraalVM 25.0.1+8.1"
  check_contains "derives an id from the label" "$(output graalvm-id)" "Oracle-GraalVM-25.0.1-8.1-"
}

graalvm_accepts_community() {
  stub_java_home "$WORK/graalvm" "$COMMUNITY_GRAALVM_25"
  JAVA_HOME="$WORK/graalvm" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" >/dev/null 2>&1
  check "exits 0" "$?" "0"
  check "labels the distribution" "$(output graalvm-label)" "GraalVM CE 25.0.1+8.1"
}

graalvm_id_tracks_the_jdk() {
  stub_java_home "$WORK/a" "$ORACLE_GRAALVM_25"
  stub_java_home "$WORK/b" "$ORACLE_GRAALVM_25"
  JAVA_HOME="$WORK/a" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" >/dev/null 2>&1
  local first
  first="$(output graalvm-id)"
  : >"$GITHUB_OUTPUT"
  JAVA_HOME="$WORK/b" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" >/dev/null 2>&1
  local second
  second="$(output graalvm-id)"
  check "a different install yields a different id" "$([ "$first" != "$second" ] && echo differs)" "differs"

  : >"$GITHUB_OUTPUT"
  JAVA_HOME="$WORK/a" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" >/dev/null 2>&1
  check "the same install yields a stable id" "$(output graalvm-id)" "$first"
}

graalvm_rejects_non_graalvm() {
  stub_java_home "$WORK/temurin" "$TEMURIN_21"
  local out status
  out="$(JAVA_HOME="$WORK/temurin" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" 2>&1)"
  status=$?
  check "fails" "$status" "1"
  check_contains "says it is not GraalVM" "$out" "not a GraalVM installation"
}

graalvm_rejects_old_jdk() {
  stub_java_home "$WORK/old" 'openjdk version "21.0.5" 2024-10-15
OpenJDK Runtime Environment GraalVM CE 21.0.5+11 (build 21.0.5+11)'
  local out status
  out="$(JAVA_HOME="$WORK/old" INPUT_JAVA_VERSION=25 "$SCRIPTS/verify-graalvm.sh" 2>&1)"
  status=$?
  check "fails below JDK 25" "$status" "1"
  check_contains "names the requirement" "$out" "requires JDK 25 or later"
}

graalvm_rejects_missing_java_home() {
  local out status
  out="$(env -u JAVA_HOME "$SCRIPTS/verify-graalvm.sh" 2>&1)"
  status=$?
  check "fails without JAVA_HOME" "$status" "1"
  check_contains "points at the graalvm input" "$out" "'graalvm' input"
}

graalvm_warns_on_version_mismatch() {
  stub_java_home "$WORK/graalvm" "$ORACLE_GRAALVM_25"
  local out
  out="$(JAVA_HOME="$WORK/graalvm" INPUT_JAVA_VERSION=26 "$SCRIPTS/verify-graalvm.sh" 2>&1)"
  check "still succeeds" "$?" "0"
  check_contains "warns about the mismatch" "$out" "::warning::Requested Java 26"
}

# -- resolve-graalpy ---------------------------------------------------------

run_resolve_graalpy() {
  INPUT_GRAALPY="${INPUT_GRAALPY:-true}" \
    INPUT_GRAALPY_VERSION="${INPUT_GRAALPY_VERSION:-}" \
    INPUT_GRAALPY_PYTHON_VERSION="${INPUT_GRAALPY_PYTHON_VERSION:-3.13}" \
    INPUT_PYTEST_VERSION="${INPUT_PYTEST_VERSION:-latest}" \
    INPUT_PYTHON_PACKAGES="${INPUT_PYTHON_PACKAGES:-}" \
    INPUT_INSTALL_PROJECT="${INPUT_INSTALL_PROJECT:-auto}" \
    INPUT_REQUIREMENTS="${INPUT_REQUIREMENTS:-auto}" \
    INPUT_VENV_DIR="${INPUT_VENV_DIR:-}" \
    PROJECT_DIR="${PROJECT_DIR:-$WORK/project}" \
    CLI_GRAALPY_VERSION="${CLI_GRAALPY_VERSION:-}" \
    CLI_GRAALPY_INTERPRETER="${CLI_GRAALPY_INTERPRETER:-}" \
    CACHE_KEY_BASE="${CACHE_KEY_BASE:-base-Linux-x64}" \
    "$SCRIPTS/resolve-graalpy.sh" 2>&1
}

graalpy_derives_from_the_cli() {
  mkdir -p "$WORK/project"
  CLI_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "builds a pyenv identifier" "$(output pyenv-version)" "graalpy3.13-25.3.4.1"
  check "keeps the bare version" "$(output graalpy-version)" "25.3.4.1"
  check "defaults the environment to the project .venv" "$(output venv-dir)" "$WORK/project/.venv"
  check "defaults pytest to the newest release" "$(output pytest-requirement)" "pytest"
}

graalpy_input_wins_over_the_cli() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=24.2.1 CLI_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "uses the input" "$(output pyenv-version)" "graalpy3.13-24.2.1"
}

graalpy_accepts_a_pyenv_identifier() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=graalpy-community-24.1.2 run_resolve_graalpy >/dev/null
  check "passes the identifier through" "$(output pyenv-version)" "graalpy-community-24.1.2"
  check "extracts the version" "$(output graalpy-version)" "24.1.2"
}

graalpy_honours_the_python_feature_version() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_GRAALPY_PYTHON_VERSION=3.11 run_resolve_graalpy >/dev/null
  check "uses the given feature version" "$(output pyenv-version)" "graalpy3.11-25.3.4.1"
}

graalpy_pins_pytest() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION=9.0.3 run_resolve_graalpy >/dev/null
  check "pins an exact version" "$(output pytest-requirement)" "pytest==9.0.3"
  : >"$GITHUB_OUTPUT"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION='>=9,<10' run_resolve_graalpy >/dev/null
  check "passes a specifier through" "$(output pytest-requirement)" "pytest>=9,<10"
}

graalpy_cache_key_tracks_requirements() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION=9.0.3 run_resolve_graalpy >/dev/null
  local base
  base="$(output cache-key)"
  check_contains "names the pyenv version" "$base" "graalpy-graalpy3.13-25.3.4.1-"

  : >"$GITHUB_OUTPUT"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION=9.0.3 run_resolve_graalpy >/dev/null
  check "is stable for identical inputs" "$(output cache-key)" "$base"

  : >"$GITHUB_OUTPUT"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION=9.0.2 run_resolve_graalpy >/dev/null
  check "changes when pytest changes" "$([ "$(output cache-key)" != "$base" ] && echo differs)" "differs"

  : >"$GITHUB_OUTPUT"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION=9.0.3 INPUT_PYTHON_PACKAGES='requests' \
    run_resolve_graalpy >/dev/null
  check "changes when extra packages change" "$([ "$(output cache-key)" != "$base" ] && echo differs)" "differs"
}

graalpy_marker_lists_every_requirement() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_PYTEST_VERSION=9.0.3 \
    INPUT_PYTHON_PACKAGES='
      # a comment
      pytest-xdist==3.6.1

      requests
    ' run_resolve_graalpy >/dev/null
  check "drops blanks and comments" "$(output venv-marker)" \
    "graalpy3.13-25.3.4.1 pytest==9.0.3 pytest-xdist==3.6.1 requests"
}

graalpy_can_be_disabled() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY=false run_resolve_graalpy >/dev/null
  check "exits 0 without a version" "$?" "0"
  check "reports no pyenv version" "$(output pyenv-version)" ""
  check "still reports the venv directory" "$(output venv-dir)" "$WORK/project/.venv"
}

# -- setup-graalpy -----------------------------------------------------------

graalpy_reuses_a_matching_environment() {
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  stub_restored_venv "graalpy3.13-25.3.4.1 pytest"
  : >"$WORK/venv-created"
  local out
  out="$(run_setup_graalpy)"
  check "exits 0" "$?" "0"
  check_contains "says it reused the environment" "$out" "Reusing the cached GraalPy environment"
  check "creates no new environment" "$(wc -l <"$WORK/venv-created" | tr -d ' ')" "0"
  check "reports the interpreter" "$(output python)" "$WORK/venv/bin/python"
}

graalpy_rebuilds_on_a_marker_mismatch() {
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  # The restored environment was built for a different pytest.
  stub_restored_venv "graalpy3.13-25.3.4.1 pytest==8.0.0"
  : >"$WORK/venv-created"
  local out
  out="$(run_setup_graalpy)"
  check_contains "rebuilds instead of reusing" "$out" "Creating the GraalPy environment"
  check "recreates the environment" "$(wc -l <"$WORK/venv-created" | tr -d ' ')" "1"
  check "rewrites the marker" "$(cat "$WORK/venv/.setup-pyronaut-marker")" "graalpy3.13-25.3.4.1 pytest"
}

graalpy_rebuilds_a_broken_environment() {
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  stub_restored_venv "graalpy3.13-25.3.4.1 pytest"
  # A cached environment whose interpreter no longer starts, as happens when it
  # was created under a path this run does not have.
  printf '#!/usr/bin/env bash\nexit 1\n' >"$WORK/venv/bin/python"
  : >"$WORK/venv-created"
  local out
  out="$(run_setup_graalpy)"
  check_contains "rebuilds it" "$out" "Creating the GraalPy environment"
  check "recreates the environment" "$(wc -l <"$WORK/venv-created" | tr -d ' ')" "1"
}

graalpy_exports_the_pyenv_selection() {
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  stub_restored_venv "graalpy3.13-25.3.4.1 pytest"
  : >"$WORK/venv-created"
  run_setup_graalpy >/dev/null
  check "exports PYENV_ROOT" "$(env_value PYENV_ROOT)" "$WORK/pyenv"
  check "exports PYENV_VERSION" "$(env_value PYENV_VERSION)" "graalpy3.13-25.3.4.1"
  check "leaves PATH alone by default" "$(cat "$GITHUB_PATH")" ""
  check "does not export VIRTUAL_ENV" "$(env_value VIRTUAL_ENV)" ""
}

graalpy_can_activate_the_environment() {
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  stub_restored_venv "graalpy3.13-25.3.4.1 pytest"
  : >"$WORK/venv-created"
  INPUT_ACTIVATE_VENV=true run_setup_graalpy >/dev/null
  check "exports VIRTUAL_ENV" "$(env_value VIRTUAL_ENV)" "$WORK/venv"
  check "puts the environment on PATH" "$(cat "$GITHUB_PATH")" "$WORK/venv/bin"
}

# -- run-setup ---------------------------------------------------------------

setup_silences_progress() {
  stub_pyronaut 0
  run_setup >/dev/null
  check "exits 0" "$?" "0"
  check "turns spinners off" "$(cat "$WORK/setup-args")" "setup --progress off"
}

setup_passes_the_local_repository() {
  stub_pyronaut 0
  INPUT_LOCAL_REPOSITORY="$WORK/m2" LOCAL_REPOSITORY="$WORK/m2" run_setup >/dev/null
  check "passes the repository the action resolved" "$(cat "$WORK/setup-args")" \
    "setup --local-repository $WORK/m2 --progress off"
}

setup_appends_extra_arguments() {
  stub_pyronaut 0
  INPUT_SETUP_ARGS='
    --refresh
    # rebuild from scratch
    --offline
  ' run_setup >/dev/null
  check "appends them in order" "$(cat "$WORK/setup-args")" "setup --refresh --offline --progress off"
}

setup_lets_the_workflow_keep_progress() {
  stub_pyronaut 0
  # One argument per line, which is how a value option has to be written.
  INPUT_SETUP_ARGS='--progress
on' run_setup >/dev/null
  check "does not add a second --progress" "$(cat "$WORK/setup-args")" "setup --progress on"
  : >"$GITHUB_OUTPUT"
  INPUT_SETUP_ARGS='--progress=on' run_setup >/dev/null
  check "recognises the --option=value form" "$(cat "$WORK/setup-args")" "setup --progress=on"
}

setup_warns_about_a_packed_argument() {
  stub_pyronaut 0
  local out
  out="$(INPUT_SETUP_ARGS='--progress on' run_setup)"
  check_contains "warns that it needs its own line" "$out" "::warning::setup-args entry '--progress on' contains a space"
  check "still suppresses the second --progress" "$(cat "$WORK/setup-args")" "setup --progress on"
}

setup_reports_a_failure() {
  stub_pyronaut 3
  local out status
  out="$(run_setup)"
  status=$?
  check "propagates the failure" "$status" "1"
  check_contains "points at the doctor" "$out" "run-doctor: true"
  check_contains "points at the token" "$out" "github-token"
}

# -- the GraalPy interpreter the CLI names -----------------------------------
#
# The GraalPy version and the pyenv interpreter do not track each other:
# Pyronaut 0.0.7 reports GraalPy 25.4.4.1.1 but its interpreter is
# graalpy3.13-25.4.4, and only the latter is a pyenv identifier. They matched up
# to 0.0.3, which is why deriving one from the other looked sufficient.

interpreter_from_the_cli_is_preferred() {
  mkdir -p "$WORK/project"
  CLI_GRAALPY_VERSION=25.4.4.1.1 CLI_GRAALPY_INTERPRETER=graalpy3.13-25.4.4 \
    run_resolve_graalpy >/dev/null
  check "uses the identifier the CLI names" "$(output pyenv-version)" "graalpy3.13-25.4.4"
  check "keeps the CLI's more precise version" "$(output graalpy-version)" "25.4.4.1.1"
}

interpreter_falls_back_to_deriving() {
  mkdir -p "$WORK/project"
  # A CLI old enough not to report the interpreter, e.g. 0.0.3.
  CLI_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "derives it from the version" "$(output pyenv-version)" "graalpy3.13-25.3.4.1"
  check "reports that version" "$(output graalpy-version)" "25.3.4.1"
}

interpreter_input_overrides_the_cli() {
  mkdir -p "$WORK/project"
  INPUT_GRAALPY_VERSION=graalpy3.13-25.3.4.1 CLI_GRAALPY_VERSION=25.4.4.1.1 \
    CLI_GRAALPY_INTERPRETER=graalpy3.13-25.4.4 run_resolve_graalpy >/dev/null
  check "the input wins" "$(output pyenv-version)" "graalpy3.13-25.3.4.1"

  : >"$GITHUB_OUTPUT"
  INPUT_GRAALPY_VERSION=25.3.4.1 CLI_GRAALPY_INTERPRETER=graalpy3.13-25.4.4 \
    run_resolve_graalpy >/dev/null
  check "a bare input version is still derived" "$(output pyenv-version)" "graalpy3.13-25.3.4.1"
}

interpreter_without_a_version_still_works() {
  mkdir -p "$WORK/project"
  CLI_GRAALPY_INTERPRETER=graalpy3.13-25.4.4 run_resolve_graalpy >/dev/null
  check "uses the identifier" "$(output pyenv-version)" "graalpy3.13-25.4.4"
  check "takes the version from its suffix" "$(output graalpy-version)" "25.4.4"
}

interpreter_requires_something_to_go_on() {
  mkdir -p "$WORK/project"
  local out status
  out="$(run_resolve_graalpy)"
  status=$?
  check "fails when the CLI reports neither" "$status" "1"
  check_contains "names the input" "$out" "'graalpy-version' input"
}

# -- project dependencies ----------------------------------------------------

deps_auto_detects_declared_dependencies() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\ndependencies = ["six"]\n' >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "installs the project" "$(output install-project)" "true"
  check_contains "records the project in the marker" "$(output venv-marker)" " -e:"
}

deps_auto_skips_a_project_without_dependencies() {
  mkdir -p "$WORK/project"
  # The minimal Pyronaut project: Java dependencies only, no Python ones.
  printf '[project]\nname = "demo"\n\n[tool.pyronaut.dependencies]\nruntime = ["io.micronaut:micronaut-http-server-netty"]\n' \
    >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "does not install the project" "$(output install-project)" "false"
  check "leaves it out of the marker" \
    "$(printf '%s' "$(output venv-marker)" | grep -c -- ' -e:')" "0"
}

deps_auto_handles_a_multiline_dependencies_array() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\ndependencies = [\n  "six",\n  "requests>=2",\n]\n' \
    >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "installs the project" "$(output install-project)" "true"
}

deps_auto_ignores_extras_only_dependencies() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\ndependencies = [\n  "pytest; extra == \x27dev\x27",\n]\n' \
    >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "treats an extras-only requirement as nothing declared" "$(output install-project)" "false"
}

deps_auto_ignores_other_dependency_tables() {
  mkdir -p "$WORK/project"
  # Only [project].dependencies counts; the Pyronaut and optional tables must
  # not be mistaken for it.
  printf '[project]\nname = "demo"\n\n[project.optional-dependencies]\ndev = ["black"]\n\n[tool.pyronaut.dependencies]\nruntime = ["io.micronaut:micronaut-http-server-netty"]\n' \
    >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "does not install the project" "$(output install-project)" "false"
}

deps_install_project_can_be_forced_and_disabled() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\n' >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_INSTALL_PROJECT=true run_resolve_graalpy >/dev/null
  check "forced on" "$(output install-project)" "true"

  : >"$GITHUB_OUTPUT"
  printf '[project]\nname = "demo"\ndependencies = ["six"]\n' >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_INSTALL_PROJECT=false run_resolve_graalpy >/dev/null
  check "forced off despite declared dependencies" "$(output install-project)" "false"
}

deps_install_project_needs_a_pyproject() {
  mkdir -p "$WORK/project"
  local out status
  out="$(INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_INSTALL_PROJECT=true run_resolve_graalpy)"
  status=$?
  check "fails when forced without a pyproject.toml" "$status" "1"
  check_contains "says why" "$out" "no pyproject.toml"
}

deps_rejects_a_bad_install_project() {
  mkdir -p "$WORK/project"
  local out status
  out="$(INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_INSTALL_PROJECT=maybe run_resolve_graalpy)"
  status=$?
  check "fails" "$status" "1"
  check_contains "names the input" "$out" "Input 'install-project' must be auto, true or false"
}

deps_auto_detects_requirements_txt() {
  mkdir -p "$WORK/project"
  printf 'typing-extensions\n' >"$WORK/project/requirements.txt"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "finds it" "$(output requirements-files)" "$WORK/project/requirements.txt"
  check_contains "records it in the marker" "$(output venv-marker)" " -r:"
}

deps_requirements_can_be_listed_and_disabled() {
  mkdir -p "$WORK/project"
  printf 'six\n' >"$WORK/project/base.txt"
  printf 'typing-extensions\n' >"$WORK/project/dev.txt"
  printf 'ignored\n' >"$WORK/project/requirements.txt"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_REQUIREMENTS="$WORK/project/base.txt
$WORK/project/dev.txt" run_resolve_graalpy >/dev/null
  check "uses the listed files instead of requirements.txt" "$(output requirements-files)" \
    "$WORK/project/base.txt
$WORK/project/dev.txt"

  : >"$GITHUB_OUTPUT"
  INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_REQUIREMENTS=false run_resolve_graalpy >/dev/null
  check "false uses none" "$(output requirements-files)" ""
}

deps_rejects_a_missing_requirements_file() {
  mkdir -p "$WORK/project"
  local out status
  out="$(INPUT_GRAALPY_VERSION=25.3.4.1 INPUT_REQUIREMENTS="$WORK/project/nope.txt" run_resolve_graalpy)"
  status=$?
  check "fails" "$status" "1"
  check_contains "names the file" "$out" "requirements file does not exist"
}

deps_cache_key_tracks_requirement_contents() {
  mkdir -p "$WORK/project"
  printf 'six\n' >"$WORK/project/requirements.txt"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  local first
  first="$(output cache-key)"

  : >"$GITHUB_OUTPUT"
  printf 'six\ntyping-extensions\n' >"$WORK/project/requirements.txt"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "editing requirements.txt changes the key" \
    "$([ "$(output cache-key)" != "$first" ] && echo differs)" "differs"
}

deps_cache_key_tracks_pyproject_contents() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\ndependencies = ["six"]\n' >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  local first
  first="$(output cache-key)"

  : >"$GITHUB_OUTPUT"
  printf '[project]\nname = "demo"\ndependencies = ["six", "attrs"]\n' >"$WORK/project/pyproject.toml"
  INPUT_GRAALPY_VERSION=25.3.4.1 run_resolve_graalpy >/dev/null
  check "adding a dependency changes the key" \
    "$([ "$(output cache-key)" != "$first" ] && echo differs)" "differs"
}

deps_are_installed_into_the_environment() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\ndependencies = ["six"]\n' >"$WORK/project/pyproject.toml"
  printf 'typing-extensions\n' >"$WORK/project/requirements.txt"
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  : >"$WORK/venv-created"
  : >"$WORK/pip-calls"
  REQUIREMENTS_FILES="$WORK/project/requirements.txt" INSTALL_PROJECT=true \
    PROJECT_DIR="$WORK/project" run_setup_graalpy >/dev/null
  local install_call
  install_call="$(grep -- '--no-compile' "$WORK/pip-calls")"
  check_contains "installs pytest" "$install_call" "pytest"
  check_contains "installs the requirement file" "$install_call" "-r $WORK/project/requirements.txt"
  check_contains "installs the project editable" "$install_call" "-e $WORK/project"
}

deps_are_skipped_when_not_requested() {
  mkdir -p "$WORK/project"
  stub_pyenv_root "$WORK/pyenv" graalpy3.13-25.3.4.1
  : >"$WORK/venv-created"
  : >"$WORK/pip-calls"
  run_setup_graalpy >/dev/null
  local install_call
  install_call="$(grep -- '--no-compile' "$WORK/pip-calls")"
  check "installs nothing but pytest" \
    "$(printf '%s' "$install_call" | grep -c -- '-e \|-r ')" "0"
}

# -- write-settings ----------------------------------------------------------

run_write_settings() {
  PYRONAUT_HOME="${PYRONAUT_HOME:-$HOME/.pyronaut}" \
    INPUT_MAVEN_REPOSITORIES="${INPUT_MAVEN_REPOSITORIES:-}" \
    INPUT_NATIVE_IMAGES_BASE_URL="${INPUT_NATIVE_IMAGES_BASE_URL:-}" \
    INPUT_NATIVE_IMAGES_VERSION="${INPUT_NATIVE_IMAGES_VERSION:-}" \
    INPUT_NATIVE_IMAGES_RELEASE_TAG="${INPUT_NATIVE_IMAGES_RELEASE_TAG:-}" \
    "$SCRIPTS/write-settings.sh" "$1" 2>&1
}

settings_render_and_apply() {
  mkdir -p "$HOME/.pyronaut"
  INPUT_MAVEN_REPOSITORIES='mavenCentral
https://central.sonatype.com/repository/maven-snapshots/' \
    INPUT_NATIVE_IMAGES_BASE_URL='https://github.com/micronaut-projects/pyronaut/releases' \
    INPUT_NATIVE_IMAGES_VERSION='0.0.3' \
    run_write_settings render >/dev/null
  check "reports a rendered file" "$(output rendered)" "$RUNNER_TEMP/setup-pyronaut/settings.toml"

  run_write_settings apply >/dev/null
  local settings
  settings="$(cat "$HOME/.pyronaut/settings.toml")"
  check_contains "writes the maven table" "$settings" '[maven]'
  check_contains "quotes each repository" "$settings" '  "mavenCentral",'
  check_contains "writes the native-images table" "$settings" '[native-images]'
  check_contains "writes base-url" "$settings" 'base-url = "https://github.com/micronaut-projects/pyronaut/releases"'
  check_contains "writes version" "$settings" 'version = "0.0.3"'
  check "omits an unset release-tag" "$(printf '%s' "$settings" | grep -c 'release-tag')" "0"
}

settings_escape_quotes() {
  INPUT_NATIVE_IMAGES_BASE_URL='/tmp/a"b\c' run_write_settings render >/dev/null
  check_contains "escapes quotes and backslashes" \
    "$(cat "$RUNNER_TEMP/setup-pyronaut/settings.toml")" 'base-url = "/tmp/a\"b\\c"'
}

settings_hash_tracks_content() {
  INPUT_NATIVE_IMAGES_VERSION=0.0.3 run_write_settings render >/dev/null
  local first
  first="$(output settings-hash)"
  : >"$GITHUB_OUTPUT"
  INPUT_NATIVE_IMAGES_VERSION=0.0.3 run_write_settings render >/dev/null
  check "is stable for identical inputs" "$(output settings-hash)" "$first"
  : >"$GITHUB_OUTPUT"
  INPUT_NATIVE_IMAGES_VERSION=0.0.4 run_write_settings render >/dev/null
  check "changes with the content" "$([ "$(output settings-hash)" != "$first" ] && echo differs)" "differs"
}

settings_adopt_a_file_the_workflow_wrote() {
  mkdir -p "$HOME/.pyronaut"
  printf '[native-images]\nversion = "9.9.9"\n' >"$HOME/.pyronaut/settings.toml"
  run_write_settings render >/dev/null
  check_contains "marks the hash as adopted" "$(output settings-hash)" "existing-"
  check "adopts it as the rendered file" "$(output rendered)" "$RUNNER_TEMP/setup-pyronaut/settings.toml"
  run_write_settings apply >/dev/null
  check_contains "leaves the content in place" "$(cat "$HOME/.pyronaut/settings.toml")" '9.9.9'
}

settings_drop_a_stale_cached_file() {
  # No settings inputs and nothing rendered, but a restored cache put a
  # settings.toml back: applying must remove it.
  run_write_settings render >/dev/null
  check "reports no settings" "$(output settings-hash)" "none"
  mkdir -p "$HOME/.pyronaut"
  printf '[native-images]\nversion = "from-the-cache"\n' >"$HOME/.pyronaut/settings.toml"
  run_write_settings apply >/dev/null
  check "removes the stale file" "$([ -f "$HOME/.pyronaut/settings.toml" ] && echo present || echo gone)" "gone"
}

# -- resolve-sdk-cache-key ---------------------------------------------------

run_sdk_cache_key() {
  CACHE_KEY_BASE="${CACHE_KEY_BASE:-base-Linux-x64}" \
    PROJECT_DIR="${PROJECT_DIR:-$WORK/project}" \
    PYRONAUT_VERSION="${PYRONAUT_VERSION:-0.0.3}" \
    GRAALVM_ID="${GRAALVM_ID:-Oracle-GraalVM-25.0.1-abcdef}" \
    SETTINGS_HASH="${SETTINGS_HASH:-none}" \
    "$SCRIPTS/resolve-sdk-cache-key.sh" 2>&1
}

sdk_cache_key_shape() {
  mkdir -p "$WORK/project"
  run_sdk_cache_key >/dev/null
  check "keys on version, JDK and settings" "$(output cache-key)" \
    "base-Linux-x64-sdk-0.0.3-Oracle-GraalVM-25.0.1-abcdef-settings-none"
  check "falls back to the JDK then the version" "$(output restore-keys)" \
    "base-Linux-x64-sdk-0.0.3-Oracle-GraalVM-25.0.1-abcdef-
base-Linux-x64-sdk-0.0.3-"
  check "keys maven on the project manifest" "$(output maven-cache-key)" \
    "base-Linux-x64-maven-0.0.3-no-project"
}

sdk_cache_key_tracks_the_project() {
  mkdir -p "$WORK/project"
  printf '[project]\nname = "demo"\n' >"$WORK/project/pyproject.toml"
  run_sdk_cache_key >/dev/null
  local first
  first="$(output maven-cache-key)"
  check "differs from the no-project key" \
    "$([ "$first" != "base-Linux-x64-maven-0.0.3-no-project" ] && echo differs)" "differs"

  : >"$GITHUB_OUTPUT"
  printf '[project]\nname = "demo"\ndependencies = []\n' >"$WORK/project/pyproject.toml"
  run_sdk_cache_key >/dev/null
  check "changes when pyproject.toml changes" \
    "$([ "$(output maven-cache-key)" != "$first" ] && echo differs)" "differs"
  check "leaves the SDK key alone" "$(output cache-key)" \
    "base-Linux-x64-sdk-0.0.3-Oracle-GraalVM-25.0.1-abcdef-settings-none"
}

# -- install-cli -------------------------------------------------------------

cli_rejects_an_unmatched_wheel() {
  local out status
  out="$(INPUT_PYRONAUT_WHEEL="$WORK/dist/pyronaut-*.whl" CLI_VENV_DIR="$WORK/cli" \
    "$SCRIPTS/install-cli.sh" 2>&1)"
  status=$?
  check "fails" "$status" "1"
  check_contains "says the glob matched nothing" "$out" "matched no file"
  check "creates no environment" "$([ -e "$WORK/cli" ] && echo present || echo absent)" "absent"
}

cli_rejects_an_ambiguous_wheel() {
  mkdir -p "$WORK/dist"
  touch "$WORK/dist/pyronaut-0.0.3-py3-none-any.whl" "$WORK/dist/pyronaut-0.0.4-py3-none-any.whl"
  local out status
  out="$(INPUT_PYRONAUT_WHEEL="$WORK/dist/pyronaut-*.whl" CLI_VENV_DIR="$WORK/cli" \
    "$SCRIPTS/install-cli.sh" 2>&1)"
  status=$?
  check "fails" "$status" "1"
  check_contains "says how many matched" "$out" "matched 2 files"
}

cli_ignores_an_interpreter_inside_the_target_venv() {
  # What a second use of the action in one job looks like: the first run left
  # its CLI venv on PATH, so `python3.12` resolves inside the directory this
  # run is about to delete and recreate. Picking it up meant `rm -rf` deleted
  # the interpreter mid-flight and `-m venv` died with exit 127.
  mkdir -p "$WORK/cli/bin"
  # A real venv's bin carries every name the probe tries, so stub them all —
  # otherwise whichever one this machine happens not to have would let the
  # probe fall through to the system interpreter and the test would pass even
  # with the guard removed.
  local name
  for name in python3.13 python3.12 python3.11 python3.10 python3 python; do
    cat >"$WORK/cli/bin/$name" <<'STALE'
#!/usr/bin/env bash
# Answers the CPython probe exactly as the real venv interpreter would.
exit 0
STALE
    chmod +x "$WORK/cli/bin/$name"
  done

  local out
  out="$(PATH="$WORK/cli/bin:$PATH" INPUT_PYRONAUT_WHEEL="$WORK/nope-*.whl" \
    CLI_VENV_DIR="$WORK/cli" "$SCRIPTS/install-cli.sh" 2>&1)"
  # It fails on the bogus wheel, which is expected; what matters is which
  # interpreter it chose before getting there.
  check_contains "reports an interpreter" "$out" "CLI interpreter:"
  check "does not choose one inside the target venv" \
    "$(printf '%s' "$out" | grep -c "CLI interpreter: $WORK/cli/bin")" "0"
}

# -- summary -----------------------------------------------------------------

summary_reports_cache_state() {
  PYRONAUT_VERSION=0.0.3 MICRONAUT_CORE_VERSION=5.2.3 GRAALVM_LABEL="Oracle GraalVM 25.0.1+8.1" \
    JAVA_HOME_USED=/opt/graalvm GRAALPY_PYENV_VERSION=graalpy3.13-25.3.4.1 \
    VENV_DIR=/w/.venv PYRONAUT_HOME=/home/runner/.pyronaut LOCAL_REPOSITORY=/home/runner/.m2/repository \
    SDK_CACHE_HIT=true GRAALPY_CACHE_HIT=false "$SCRIPTS/summary.sh" >/dev/null 2>&1
  local summary
  summary="$(cat "$GITHUB_STEP_SUMMARY")"
  check_contains "names the Pyronaut version" "$summary" '| Pyronaut | `0.0.3` |'
  check_contains "names the GraalVM" "$summary" '| GraalVM | `Oracle GraalVM 25.0.1+8.1` |'
  check_contains "reports a cache hit" "$summary" '| SDK cache | `hit` |'
  check_contains "reports a cache miss" "$summary" '| GraalPy cache | `miss` |'
}

summary_handles_a_skipped_graalpy() {
  PYRONAUT_VERSION=0.0.3 GRAALPY_PYENV_VERSION='' GRAALPY_CACHE_HIT='' VENV_DIR=/w/.venv \
    "$SCRIPTS/summary.sh" >/dev/null 2>&1
  check_contains "says GraalPy was not installed" "$(cat "$GITHUB_STEP_SUMMARY")" '| GraalPy | `not installed` |'
  check_contains "says the cache was disabled" "$(cat "$GITHUB_STEP_SUMMARY")" '| GraalPy cache | `disabled` |'
  check "omits the environment row" \
    "$(grep -c 'GraalPy environment' "$GITHUB_STEP_SUMMARY")" "0"
}

# -- run ---------------------------------------------------------------------

test_case "preflight: defaults" preflight_defaults
test_case "preflight: overrides" preflight_overrides
test_case "preflight: normalizes booleans" preflight_normalizes_booleans
test_case "preflight: rejects a bad boolean" preflight_rejects_a_bad_boolean
test_case "preflight: rejects Windows" preflight_rejects_windows
test_case "preflight: rejects a missing project-dir" preflight_rejects_missing_project

test_case "verify-graalvm: accepts Oracle GraalVM" graalvm_accepts_oracle
test_case "verify-graalvm: accepts GraalVM Community" graalvm_accepts_community
test_case "verify-graalvm: the id tracks the JDK" graalvm_id_tracks_the_jdk
test_case "verify-graalvm: rejects a non-GraalVM JDK" graalvm_rejects_non_graalvm
test_case "verify-graalvm: rejects an old JDK" graalvm_rejects_old_jdk
test_case "verify-graalvm: rejects a missing JAVA_HOME" graalvm_rejects_missing_java_home
test_case "verify-graalvm: warns on a version mismatch" graalvm_warns_on_version_mismatch

test_case "resolve-graalpy: derives the version from the CLI" graalpy_derives_from_the_cli
test_case "resolve-graalpy: the input wins over the CLI" graalpy_input_wins_over_the_cli
test_case "resolve-graalpy: accepts a pyenv identifier" graalpy_accepts_a_pyenv_identifier
test_case "resolve-graalpy: honours the python feature version" graalpy_honours_the_python_feature_version
test_case "resolve-graalpy: pins pytest" graalpy_pins_pytest
test_case "resolve-graalpy: the cache key tracks requirements" graalpy_cache_key_tracks_requirements
test_case "resolve-graalpy: the marker lists every requirement" graalpy_marker_lists_every_requirement
test_case "resolve-graalpy: can be disabled" graalpy_can_be_disabled

test_case "setup-graalpy: reuses a matching environment" graalpy_reuses_a_matching_environment
test_case "setup-graalpy: rebuilds on a marker mismatch" graalpy_rebuilds_on_a_marker_mismatch
test_case "setup-graalpy: rebuilds a broken environment" graalpy_rebuilds_a_broken_environment
test_case "setup-graalpy: exports the pyenv selection" graalpy_exports_the_pyenv_selection
test_case "setup-graalpy: can activate the environment" graalpy_can_activate_the_environment

test_case "run-setup: silences progress" setup_silences_progress
test_case "run-setup: passes the local repository" setup_passes_the_local_repository
test_case "run-setup: appends extra arguments" setup_appends_extra_arguments
test_case "run-setup: lets the workflow keep progress" setup_lets_the_workflow_keep_progress
test_case "run-setup: warns about a packed argument" setup_warns_about_a_packed_argument
test_case "run-setup: reports a failure" setup_reports_a_failure

test_case "interpreter: the CLI's identifier is preferred" interpreter_from_the_cli_is_preferred
test_case "interpreter: falls back to deriving" interpreter_falls_back_to_deriving
test_case "interpreter: the input overrides the CLI" interpreter_input_overrides_the_cli
test_case "interpreter: works without a version" interpreter_without_a_version_still_works
test_case "interpreter: requires something to go on" interpreter_requires_something_to_go_on

test_case "deps: auto-detects declared dependencies" deps_auto_detects_declared_dependencies
test_case "deps: auto skips a project without dependencies" deps_auto_skips_a_project_without_dependencies
test_case "deps: handles a multi-line dependencies array" deps_auto_handles_a_multiline_dependencies_array
test_case "deps: ignores extras-only dependencies" deps_auto_ignores_extras_only_dependencies
test_case "deps: ignores other dependency tables" deps_auto_ignores_other_dependency_tables
test_case "deps: install-project can be forced and disabled" deps_install_project_can_be_forced_and_disabled
test_case "deps: install-project needs a pyproject" deps_install_project_needs_a_pyproject
test_case "deps: rejects a bad install-project" deps_rejects_a_bad_install_project
test_case "deps: auto-detects requirements.txt" deps_auto_detects_requirements_txt
test_case "deps: requirements can be listed and disabled" deps_requirements_can_be_listed_and_disabled
test_case "deps: rejects a missing requirements file" deps_rejects_a_missing_requirements_file
test_case "deps: the cache key tracks requirement contents" deps_cache_key_tracks_requirement_contents
test_case "deps: the cache key tracks pyproject contents" deps_cache_key_tracks_pyproject_contents
test_case "deps: are installed into the environment" deps_are_installed_into_the_environment
test_case "deps: are skipped when not requested" deps_are_skipped_when_not_requested

test_case "write-settings: renders and applies" settings_render_and_apply
test_case "write-settings: escapes TOML strings" settings_escape_quotes
test_case "write-settings: the hash tracks the content" settings_hash_tracks_content
test_case "write-settings: adopts a file the workflow wrote" settings_adopt_a_file_the_workflow_wrote
test_case "write-settings: drops a stale cached file" settings_drop_a_stale_cached_file

test_case "sdk-cache-key: shape" sdk_cache_key_shape
test_case "sdk-cache-key: tracks the project" sdk_cache_key_tracks_the_project

test_case "install-cli: rejects an unmatched wheel" cli_rejects_an_unmatched_wheel
test_case "install-cli: rejects an ambiguous wheel" cli_rejects_an_ambiguous_wheel
test_case "install-cli: ignores an interpreter inside the target venv" cli_ignores_an_interpreter_inside_the_target_venv

test_case "summary: reports the cache state" summary_reports_cache_state
test_case "summary: handles a skipped GraalPy" summary_handles_a_skipped_graalpy

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
