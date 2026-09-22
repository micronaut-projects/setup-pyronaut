#!/usr/bin/env bash
#
# Confirm that JAVA_HOME points at a GraalVM the Pyronaut CLI will accept, and
# derive a stable identifier for it to key the SDK cache on.
#
# Pyronaut's own toolchain discovery takes JAVA_HOME first when it satisfies the
# requested toolchain, so getting this right here is what stops `pyronaut setup`
# from downloading a second GraalVM of its own.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

readonly MINIMUM_FEATURE_VERSION=25

[ -n "${JAVA_HOME:-}" ] || fail \
  "JAVA_HOME is not set. Leave the 'graalvm' input at 'true', or set up a GraalVM ${MINIMUM_FEATURE_VERSION}+ JDK before this action."

java_home="$(absolute_path "$JAVA_HOME")"
java_bin="$java_home/bin/java"
[ -x "$java_bin" ] || fail "JAVA_HOME does not contain an executable bin/java: $java_home"

report="$("$java_bin" -version 2>&1)" || fail "Unable to run $java_bin -version"
printf '%s\n' "$report"

case "$(printf '%s' "$report" | tr '[:upper:]' '[:lower:]')" in
  *graalvm*) ;;
  *)
    fail "JAVA_HOME is not a GraalVM installation: $java_home. Pyronaut needs GraalVM for native-image and its embedded GraalPy runtime."
    ;;
esac

# `java version "25.0.1"` / `openjdk version "25"` -> 25
feature_version="$(printf '%s\n' "$report" |
  awk -F'"' '/version "/ { split($2, parts, /[.+_-]/); print parts[1]; exit }')"
case "$feature_version" in
  '' | *[!0-9]*) fail "Unable to determine the Java feature version from: $(printf '%s' "$report" | head -1)" ;;
esac

if [ "$feature_version" -lt "$MINIMUM_FEATURE_VERSION" ]; then
  fail "Pyronaut requires JDK ${MINIMUM_FEATURE_VERSION} or later, but JAVA_HOME is Java ${feature_version}: $java_home"
fi

requested="$(printf '%s' "${INPUT_JAVA_VERSION:-}" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')"
if [ -n "$requested" ] && [ "$feature_version" -ne "$requested" ]; then
  warn "Requested Java $requested but JAVA_HOME is Java $feature_version ($java_home)."
fi

# The runtime line names the distribution and build, e.g.
#   Java(TM) SE Runtime Environment Oracle GraalVM 25.0.1+8.1 (build ...)
#   OpenJDK Runtime Environment GraalVM CE 25.0.1+8.1 (build ...)
# Everything between `Runtime Environment ` and ` (build ` is the name, which
# keeps the distribution attached to the version. Matching the word `GraalVM`
# directly would not: a greedy `.*` backtracks onto the second word of
# `Oracle GraalVM` and drops the vendor.
label="$(printf '%s\n' "$report" |
  sed -n 's/^.*Runtime Environment \(.*\) (build .*$/\1/p' |
  head -1)"
case "$label" in
  *GraalVM*) ;;
  *) label="GraalVM $feature_version" ;;
esac

# The cache key has to change whenever the JDK does, because `~/.pyronaut/setup`
# records this JAVA_HOME by absolute path; a stale entry would only force an
# unnecessary re-run of setup, never a wrong build.
graalvm_id="$(sanitize_key "$label")-$(printf '%s\n%s\n' "$java_home" "$report" | short_hash)"

set_output "java-home" "$java_home"
set_output "java-feature-version" "$feature_version"
set_output "graalvm-label" "$label"
set_output "graalvm-id" "$graalvm_id"

printf 'Using %s at %s\n' "$label" "$java_home"
