#!/usr/bin/env bash
#
# Run `pyronaut setup`, which provisions the SDK toolchain and resolves the SDK
# classpaths into the Maven repository. With `--native-launchers` it also
# downloads the native launchers; resolve-native-launchers.sh decides whether
# this job needs them.
#
# Setup is idempotent and validates its own manifest, so on a cache hit this is
# a fast no-op and on a stale cache it repairs only what changed.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

cd "$PROJECT_DIR"

args=()
# Only pass --local-repository when the workflow asked for a specific one;
# Pyronaut's own default already resolves to ~/.m2/repository.
if [ -n "${INPUT_LOCAL_REPOSITORY:-}" ]; then
  args+=("--local-repository" "$LOCAL_REPOSITORY")
fi

progress_given=0
while IFS= read -r argument; do
  [ -n "$argument" ] || continue
  case "$argument" in
    --progress | --progress=* | "--progress "*) progress_given=1 ;;
  esac
  # Each line is one argument, so that a value containing spaces survives. A
  # line that holds both an option and its value would reach the CLI as a
  # single token and come back as "Unknown pyronaut setup option"; say so here,
  # where the fix is obvious.
  case "$argument" in
    -*" "*)
      warn "setup-args entry '$argument' contains a space. Put the option and its value on separate lines, or write --option=value."
      ;;
  esac
  args+=("$argument")
done <<EOF
$(meaningful_lines "${INPUT_SETUP_ARGS:-}")
EOF

if is_true "${NATIVE_LAUNCHERS_FLAG:-}"; then
  args+=("--native-launchers")
fi

# The default, `auto`, renders spinners that a log with no terminal turns into
# noise. A --progress in setup-args wins, so a workflow can still ask for them.
if [ "$progress_given" -eq 0 ]; then
  args+=("--progress" "off")
fi

group "pyronaut setup"
printf '$ %s setup %s\n' "$PYRONAUT" "${args[*]}"
if ! "$PYRONAUT" setup "${args[@]}"; then
  endgroup
  printf '::error::pyronaut setup failed. Run the action with `run-doctor: true` for a full environment report.\n' >&2
  if is_true "${NATIVE_LAUNCHERS:-}"; then
    printf '::error::If it failed downloading native launchers, the `github-token` input needs read access to releases of micronaut-projects/pyronaut.\n' >&2
  fi
  exit 1
fi
endgroup
