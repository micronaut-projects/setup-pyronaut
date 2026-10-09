#!/usr/bin/env bash
#
# Decide whether this job needs Pyronaut's native launchers (`pyronaut-dev`,
# `pyronaut-run` and `pyronaut-run-python`), whether `pyronaut setup` should be
# asked to download them, and whether `~/.pyronaut/bin` belongs in the cache.
#
# The launchers are about 1.6 GB on linux-amd64. Since micronaut-projects/pyronaut#360,
# `pyronaut setup` no longer downloads them unless it is given
# `--native-launchers`; a command that selects one downloads it on first use
# instead. A JVM-toolchain project never needs them, so this keeps them out of
# both the setup run and the cache unless the project actually uses them.
#
# Older SDKs always download the launchers during setup and reject the flag, so
# for those the action keeps the v1 behaviour: no flag, and the launchers cached.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

pyproject="$PROJECT_DIR/pyproject.toml"

# The toolchain type the project's pyproject.toml declares, lowercased, or
# nothing when it declares none. Pyronaut reads `tool.pyronaut.toolchain.type`,
# which TOML lets a project spell as a table, a dotted key or an inline table;
# all three are recognised here. As in resolve-graalpy.sh this reads the common
# TOML shapes rather than parsing TOML, and an unrecognised shape reads as no
# type at all — the JVM toolchain, which is Pyronaut's own default too.
declared_toolchain_type() {
  [ -f "$pyproject" ] || return 0
  awk '
    function unquote(value) {
      sub(/^[[:space:]]+/, "", value)
      if (value ~ /^"/) { sub(/^"/, "", value); sub(/".*$/, "", value) }
      else if (value ~ /^\047/) { sub(/^\047/, "", value); sub(/\047.*$/, "", value) }
      else { sub(/[[:space:]#].*$/, "", value) }
      return tolower(value)
    }
    /^[[:space:]]*\[/ {
      header = $0
      sub(/^[[:space:]]*\[+/, "", header)
      sub(/\].*$/, "", header)
      gsub(/[[:space:]"\047]/, "", header)
      next
    }
    /^[[:space:]]*[A-Za-z0-9_."\047-]+[[:space:]]*=/ {
      key = $0
      sub(/=.*$/, "", key)
      gsub(/[[:space:]"\047]/, "", key)
      value = $0
      sub(/^[^=]*=/, "", value)
      full = (header == "" ? key : header "." key)
      if (full == "tool.pyronaut.toolchain.type") {
        type = unquote(value)
      } else if (full == "tool.pyronaut.toolchain" && value ~ /^[[:space:]]*\{/) {
        if (match(value, /(^|[{,[:space:]])type[[:space:]]*=/)) {
          type = unquote(substr(value, RSTART + RLENGTH))
        }
      }
    }
    END { if (type != "") print type }
  ' "$pyproject"
}

requested="$(printf '%s' "${INPUT_NATIVE_LAUNCHERS:-auto}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
case "$requested" in
  auto | '') requested=auto ;;
  true | 1 | yes | on) requested=true ;;
  false | 0 | no | off) requested=false ;;
  *) fail "Input 'native-launchers' must be auto, true or false, but was '${INPUT_NATIVE_LAUNCHERS:-}'" ;;
esac

# A workflow that already passes the flag itself has made the decision, whatever
# the input says, and must not get it twice.
flag_in_setup_args=false
while IFS= read -r argument; do
  [ "$argument" = "--native-launchers" ] && flag_in_setup_args=true
done <<EOF
$(meaningful_lines "${INPUT_SETUP_ARGS:-}")
EOF

reason=""
if [ "$flag_in_setup_args" = true ]; then
  needed=true
  reason="--native-launchers in setup-args"
elif [ "$requested" != auto ]; then
  needed="$requested"
  reason="native-launchers: $requested"
elif [ ! -f "$pyproject" ]; then
  # Without a pyproject.toml, `pyronaut dev` and `pyronaut test` run the
  # project's Python sources directly on the native `pyronaut-dev`, unless the
  # command is given --jvm.
  needed=true
  reason="no pyproject.toml, so direct-source runs use the native pyronaut-dev"
else
  toolchain_type="$(declared_toolchain_type)"
  if [ "$toolchain_type" = native ]; then
    needed=true
    reason="tool.pyronaut.toolchain.type is native"
  else
    needed=false
    reason="tool.pyronaut.toolchain.type is ${toolchain_type:-not set}, so the JVM toolchain"
  fi
fi

# Whether this SDK knows the flag. Every Pyronaut CLI answers `setup --help`
# with its usage and without doing any setup, and the ones from #360 on list
# --native-launchers in it.
supported=false
if [ -n "${PYRONAUT:-}" ] && "$PYRONAUT" setup --help 2>&1 | grep -q -- '--native-launchers'; then
  supported=true
fi

if [ "$supported" = true ]; then
  # Only add the flag when the workflow did not pass it already.
  if [ "$needed" = true ] && [ "$flag_in_setup_args" = false ]; then
    pass_flag=true
  else
    pass_flag=false
  fi
  cache_launchers="$needed"
  provisioned="$needed"
else
  # An SDK from before #360 downloads the launchers during every setup and does
  # not accept the flag. Caching them is then what the action did in v1, and
  # still saves the download.
  pass_flag=false
  cache_launchers=true
  provisioned=true
  if [ "$requested" = false ]; then
    notice "This Pyronaut CLI always downloads its native launchers during setup; native-launchers: false needs a Pyronaut release that supports pyronaut setup --native-launchers."
  fi
fi

set_output "native-launchers" "$provisioned"
set_output "setup-flag" "$pass_flag"
set_output "cache" "$cache_launchers"
set_output "supported" "$supported"
set_output "reason" "$reason"

printf 'Native launchers needed: %s (%s)\n' "$needed" "$reason"
printf 'setup --native-launchers supported: %s\n' "$supported"
printf 'Downloaded during setup: %s\n' "$provisioned"
printf 'Cache ~/.pyronaut/bin:   %s\n' "$cache_launchers"
