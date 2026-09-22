#!/usr/bin/env bash
#
# Print `pyronaut doctor` for the project. Diagnostics only: a failing check
# here is reported as a warning rather than failing the job, because the
# commands the workflow actually runs will fail on their own if a precondition
# they need is missing.
set -euo pipefail
# shellcheck source=scripts/common.sh
. "$(dirname "$0")/common.sh"

group "pyronaut doctor"
status=0
"$PYRONAUT" doctor --project-dir "$PROJECT_DIR" || status=$?
endgroup

if [ "$status" -ne 0 ]; then
  warn "pyronaut doctor reported problems (exit $status). See the 'pyronaut doctor' group above for the suggested fixes."
fi
