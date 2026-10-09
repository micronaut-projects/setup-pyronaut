#!/usr/bin/env bash
#
# Build the cache keys for `~/.pyronaut`, for the native launchers under
# `~/.pyronaut/bin`, and for the Maven local repository.
#
# `~/.pyronaut/setup/<version>/<os>-<arch>/setup.json` records the GraalVM, the
# Maven repository and the resolved SDK classpaths by absolute path, and Pyronaut
# re-validates all of it on every `pyronaut setup`. So a key that is too loose
# costs one extra setup run and nothing more — which is why the SDK key is exact
# on everything that identifies the manifest, while the Maven key is allowed to
# fall back to a prefix and let the resolver top up what is missing.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

sdk_prefix="$CACHE_KEY_BASE-sdk-$(sanitize_key "$PYRONAUT_VERSION")"
sdk_key="$sdk_prefix-$(sanitize_key "$GRAALVM_ID")-settings-$(sanitize_key "$SETTINGS_HASH")"

# Project dependencies are resolved into the Maven repository by `pyronaut
# install` later in the job, so this cache is keyed on the project manifests and
# saved at the end of the job rather than straight after setup.
project_hash="no-project"
if [ -f "$PROJECT_DIR/pyproject.toml" ]; then
  project_hash="$(short_hash <"$PROJECT_DIR/pyproject.toml")"
fi

# The native launchers are cached on their own, so a JVM-only job and a job that
# uses the native toolchain share the SDK entry without either one saving or
# restoring the other's 1.6 GB of launchers. Pyronaut keeps them under
# `~/.pyronaut/bin/<version>/<os>-<arch>/` and which build it downloads depends
# only on its version and the `[native-images]` settings, not on the GraalVM.
# No restore-keys: launchers of another version would never be used, only kept.
launchers_key="$CACHE_KEY_BASE-launchers-$(sanitize_key "$PYRONAUT_VERSION")-settings-$(sanitize_key "$SETTINGS_HASH")"

maven_prefix="$CACHE_KEY_BASE-maven-$(sanitize_key "$PYRONAUT_VERSION")"
maven_key="$maven_prefix-$project_hash"

set_output "cache-key" "$sdk_key"
set_output "restore-keys" "$sdk_prefix-$(sanitize_key "$GRAALVM_ID")-
$sdk_prefix-"
set_output "launchers-cache-key" "$launchers_key"
set_output "maven-cache-key" "$maven_key"
set_output "maven-restore-keys" "$maven_prefix-
$CACHE_KEY_BASE-maven-"

printf 'SDK cache key:   %s\n' "$sdk_key"
printf 'Launchers key:   %s\n' "$launchers_key"
printf 'Maven cache key: %s\n' "$maven_key"
