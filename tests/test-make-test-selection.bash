#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

make --no-print-directory -C "$REPO_ROOT" test TEST_FILES=tests/test-make-test.bash
echo 'Explicit make test selection preserves fixture isolation'
