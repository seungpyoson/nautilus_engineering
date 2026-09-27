#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The helper is linted separately; staged-file hooks may omit it from their inputs.
# shellcheck source=tests/make-environment.bash disable=SC1091
source "${SCRIPT_DIR}/make-environment.bash"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

make --no-print-directory -C "$REPO_ROOT" test TEST_FILES=tests/test-make-test.bash
echo 'Explicit make test selection preserves fixture isolation'
