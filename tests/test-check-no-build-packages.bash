#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_SCRIPT="${REPO_ROOT}/scripts/check-no-build-packages.sh"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-no-build-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
repo="${test_root}/repo"
mkdir -p "${repo}/nested" "${repo}/scripts"
cp "$SOURCE_SCRIPT" "${repo}/scripts/check-no-build-packages.sh"
CHECK_SCRIPT="${repo}/scripts/check-no-build-packages.sh"
git -C "$repo" init --quiet

write_root_lock() {
  cat > "${repo}/uv.lock" << 'LOCK'
version = 1

[[package]]
name = "alpha"
version = "1.2.3"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "bravo"
version = "4.5.6"
source = { git = "https://example.com/bravo.git" }

[[package]]
name = "workspace-project"
version = "0.1.0"
source = { editable = "." }
LOCK
}

write_root_manifest() {
  local body=$1
  cat > "${repo}/pyproject.toml" << TOML
[project]
name = "workspace-project"
version = "0.1.0"

[tool.uv]
no-build-package = [
${body}
]
TOML
}

write_root_lock
write_root_manifest '  "alpha",
  "bravo",'
cat > "${repo}/nested/uv.lock" << 'LOCK'
version = 1

[[package]]
name = "charlie"
version = "7.8.9"
source = { url = "https://example.com/charlie.whl" }

[[package]]
name = "nested-project"
version = "0.2.0"
source = { directory = "." }
LOCK
cat > "${repo}/nested/pyproject.toml" << 'TOML'
[project]
name = "nested-project"
version = "0.2.0"

[tool.uv]
no-build-package = [
  "charlie",
]
TOML
git -C "$repo" add -A

failures=0

expect() {
  local label=$1 expected_status=$2 expected_text=$3
  shift 3
  local output status=0
  output=$(cd "$repo" && "$@" 2>&1) || status=$?
  if [[ "$status" == "$expected_status" && "$output" == "$expected_text" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s: expected exit %s, got %s\nExpected:\n%s\nActual:\n%s\n' \
      "$label" "$expected_status" "$status" "$expected_text" "$output" >&2
    failures=$((failures + 1))
  fi
}

root_ok='OK  pyproject.toml: 2 packages, in sync with uv.lock'
root_fail='FAIL pyproject.toml: out of sync with uv.lock'
failure_footer=$'\n\nUpdate no-build-package in each failing manifest to match its uv.lock.'
order_error='  Entries are not sorted alphabetically.'

expect "auto-discovery checks every eligible tracked lock" 0 \
  "OK  nested/pyproject.toml: 1 packages, in sync with nested/uv.lock
${root_ok}" bash "$CHECK_SCRIPT"

write_root_manifest '  "alpha",'
expect "missing package fails" 1 \
  "${root_fail}
  Missing from no-build-package (1):
    + bravo${failure_footer}" bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

write_root_manifest '  "alpha",
  "bravo",
  "stale",'
expect "stale package fails" 1 \
  "${root_fail}
  Listed in no-build-package but not in lock (1):
    - stale${failure_footer}" bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

write_root_manifest '  "alpha",
  "alpha",
  "bravo",'
expect "sorted duplicate reports only duplication" 1 \
  "${root_fail}
  Duplicate entries: alpha${failure_footer}" bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

write_root_manifest '  "alpha",
  "bravo",
  "alpha",'
expect "separated duplicate reports duplication and ordering" 1 \
  "${root_fail}
  Duplicate entries: alpha
${order_error}${failure_footer}" bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

write_root_manifest '  "bravo",
  "alpha",'
expect "out-of-order package fails" 1 \
  "${root_fail}
${order_error}${failure_footer}" bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

write_root_manifest '  "alpha",
  "bravo",'
real_comm=$(command -v comm)
real_sort=$(command -v sort)
fake_bin="${test_root}/bin"
mkdir "$fake_bin"
cat > "${fake_bin}/comm" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${LC_ALL:-}" != C ]]; then
  echo "comm did not receive LC_ALL=C" >&2
  exit 9
fi
exec "$REAL_COMM" "$@"
BASH
cat > "${fake_bin}/sort" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${LC_ALL:-}" != C ]]; then
  echo "sort did not receive LC_ALL=C" >&2
  exit 10
fi
exec "$REAL_SORT" "$@"
BASH
chmod +x "${fake_bin}/comm" "${fake_bin}/sort"
expect "sort and comm explicitly use the C locale" 0 "$root_ok" \
  env -u LC_ALL REAL_COMM="$real_comm" REAL_SORT="$real_sort" PATH="${fake_bin}:${PATH}" \
  bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

no_diff_bin="${test_root}/no-diff-bin"
mkdir "$no_diff_bin"
for tool in bash dirname awk comm git grep sed sort tr uniq; do
  tool_path=$(command -v "$tool")
  ln -s "$tool_path" "${no_diff_bin}/${tool}"
done
expect "diff is absent from the isolated PATH" 1 "" \
  env PATH="$no_diff_bin" bash -c 'command -v diff'
expect "sorted input passes with diff absent from PATH" 0 "$root_ok" \
  env PATH="$no_diff_bin" bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

ordering_bin="${test_root}/ordering-bin"
mkdir "$ordering_bin"
cat > "${ordering_bin}/diff" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
touch "$DIFF_MARKER"
echo 'Injected descriptor comparison failure' >&2
exit 2
BASH
chmod +x "${ordering_bin}/diff"
expect "sorted input passes without invoking diff" 0 "$root_ok" \
  env DIFF_MARKER="${test_root}/diff-called" PATH="${ordering_bin}:${PATH}" \
  bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

write_root_manifest '  "bravo",
  "alpha",'
expect "unsorted input still fails without invoking diff" 1 \
  "${root_fail}
${order_error}${failure_footer}" \
  env DIFF_MARKER="${test_root}/diff-called" PATH="${ordering_bin}:${PATH}" \
  bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml
if [[ -e "${test_root}/diff-called" ]]; then
  echo 'FAIL ordering check invoked external diff' >&2
  failures=$((failures + 1))
fi

write_root_manifest '  "alpha",
  "bravo",'
cat > "${ordering_bin}/sort" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1-}" == '-u' ]]; then
  exec "$REAL_SORT" "$@"
fi
echo 'Injected package ordering failure' >&2
exit 17
BASH
chmod +x "${ordering_bin}/sort"
expect "ordering sort failure propagates" 17 "Injected package ordering failure" \
  env REAL_SORT="$real_sort" PATH="${ordering_bin}:${PATH}" \
  bash "$CHECK_SCRIPT" --pair uv.lock:pyproject.toml

mkdir "${repo}/zero"
printf 'version = 1\n' > "${repo}/zero/uv.lock"
printf '[tool.uv]\nno-build-package = [\n]\n' > "${repo}/zero/pyproject.toml"
expect "empty package lists pass" 0 "OK  zero/pyproject.toml: 0 packages, in sync with zero/uv.lock" \
  bash "$CHECK_SCRIPT" --pair zero/uv.lock:zero/pyproject.toml

mkdir -p "${repo}/explicit"
cp "${repo}/nested/uv.lock" "${repo}/explicit/uv.lock"
cp "${repo}/nested/pyproject.toml" "${repo}/explicit/pyproject.toml"
expect "explicit untracked pair is checked" 0 \
  "OK  explicit/pyproject.toml: 1 packages, in sync with explicit/uv.lock" \
  bash "$CHECK_SCRIPT" --pair explicit/uv.lock:explicit/pyproject.toml
expect "unsafe explicit path is rejected" 2 "ERROR: missing ../uv.lock or pyproject.toml" \
  bash "$CHECK_SCRIPT" --pair ../uv.lock:pyproject.toml
expect "malformed pair is rejected" 2 "ERROR: pair must be LOCK:MANIFEST: uv.lock" \
  bash "$CHECK_SCRIPT" --pair uv.lock

empty_repo="${test_root}/empty"
mkdir -p "${empty_repo}/scripts"
cp "$SOURCE_SCRIPT" "${empty_repo}/scripts/check-no-build-packages.sh"
git -C "$empty_repo" init --quiet
printf '[project]\nname = "empty"\nversion = "0.1.0"\n' > "${empty_repo}/pyproject.toml"
git -C "$empty_repo" add pyproject.toml
status=0
output=$(cd "$empty_repo" && bash scripts/check-no-build-packages.sh 2>&1) || status=$?
if [[ "$status" == 0 && "$output" == "No tracked uv.lock has a no-build-package policy." ]]; then
  printf 'ok   repository without policy is a clean no-op\n'
else
  printf 'FAIL no-policy repository: exit %s\n%s\n' "$status" "$output" >&2
  failures=$((failures + 1))
fi

if ((failures > 0)); then
  printf '\n%s no-build-package test(s) failed\n' "$failures" >&2
  exit 1
fi

printf '\nAll no-build-package tests passed\n'
