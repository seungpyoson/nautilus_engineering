#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-make-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
test_root=$(cd "$test_root" && pwd -P)
repo="${test_root}/repo"
linked="${test_root}/linked worktree"
mkdir -p "${repo}/scripts" "${repo}/tests"
cp "${REPO_ROOT}/Makefile" "${REPO_ROOT}/tools.toml" "$repo/"
cp "${REPO_ROOT}/scripts/tool-version.sh" "${repo}/scripts/"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

# A developer's global hook must not replace the hook exercised by this fixture.
mkdir "${test_root}/global-hooks"
cat > "${test_root}/global-hooks/pre-commit" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
touch "${GIT_CONFIG_GLOBAL}.hook-ran"
echo 'Unexpected inherited Git hook' >&2
exit 47
BASH
chmod +x "${test_root}/global-hooks/pre-commit"
git config --file "${test_root}/global.gitconfig" core.hooksPath "${test_root}/global-hooks"
export GIT_CONFIG_GLOBAL="${test_root}/global.gitconfig"

cat > "${repo}/tests/fixture-check.bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
git_vars=$(git rev-parse --local-env-vars)
for git_var in $git_vars; do
  if declare -p "$git_var" > /dev/null 2>&1; then
    printf 'Git repository variable leaked: %s\n' "$git_var" >&2
    exit 31
  fi
done
if [[ "$PROBE_FAIL" == 1 ]]; then
  echo 'Injected companion failure' >&2
  exit 23
fi
foreign="${PROBE_ROOT}/foreign repository"
mkdir "$foreign"
git -C "$foreign" init --quiet
git -C "$foreign" config user.name 'Fixture author'
git -C "$foreign" config user.email fixture@example.invalid
git -C "$foreign" config commit.gpgsign false
git -C "$foreign" config core.hooksPath "${foreign}/.git/hooks"
printf 'foreign payload\n' > "${foreign}/payload"
git -C "$foreign" add payload
git -C "$foreign" commit --quiet -m 'Create foreign fixture'
actual_root=$(git -C "$foreign" rev-parse --show-toplevel)
actual_payload=$(git -C "$foreign" show HEAD:payload)
[[ "$actual_root" == "$foreign" ]] || exit 1
[[ "$actual_payload" == 'foreign payload' ]] || exit 1
printf 'foreign repository committed\n' > "${PROBE_ROOT}/fixture-result"
BASH

git -C "$repo" init --quiet
git -C "$repo" config user.name 'Parent author'
git -C "$repo" config user.email parent@example.invalid
git -C "$repo" config commit.gpgsign false
git -C "$repo" config core.hooksPath "${repo}/.git/hooks"
git -C "$repo" add -A
git -C "$repo" commit --quiet -m 'Create parent fixture'
git -C "$repo" worktree add --quiet -b hook-test "$linked"
parent_head=$(git -C "$repo" rev-parse HEAD)
parent_index=$(git -C "$repo" write-tree)
cp "${repo}/.git/config" "${test_root}/parent-config"

cat > "${repo}/.git/hooks/pre-commit" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
: "${GIT_DIR:?Expected a linked-worktree commit hook}"
: "${GIT_INDEX_FILE:?Expected the commit hook index}"
exec make --no-print-directory test TEST_FILES=tests/fixture-check.bash
BASH
chmod +x "${repo}/.git/hooks/pre-commit"

printf 'outer payload\n' > "${linked}/outer-change"
git -C "$linked" add outer-change
expected_tree=$(git -C "$linked" write-tree)
status=0
PROBE_ROOT="$test_root" PROBE_FAIL=0 git -C "$linked" commit --quiet -m 'Exercise commit hook' \
  > "${test_root}/commit.log" 2>&1 || status=$?
if [[ "$status" != 0 ]]; then
  cat "${test_root}/commit.log" >&2
  printf 'FAIL isolated hook commit: exit %s\n' "$status" >&2
  exit 1
fi
fixture_result=$(cat "${test_root}/fixture-result")
[[ "$fixture_result" == 'foreign repository committed' ]] || fail 'foreign commit was not verified'
actual_tree=$(git -C "$linked" rev-parse 'HEAD^{tree}')
[[ "$actual_tree" == "$expected_tree" ]] || fail 'outer commit contains unexpected files'
actual_index=$(git -C "$linked" write-tree)
[[ "$actual_index" == "$expected_tree" ]] || fail 'outer index changed'
actual_status=$(git -C "$linked" status --porcelain)
[[ -z "$actual_status" ]] || fail 'outer worktree is not clean'
actual_head=$(git -C "$repo" rev-parse HEAD)
[[ "$actual_head" == "$parent_head" ]] || fail 'parent branch moved'
actual_index=$(git -C "$repo" write-tree)
[[ "$actual_index" == "$parent_index" ]] || fail 'parent index changed'
cmp "${repo}/.git/config" "${test_root}/parent-config"
echo 'ok   hook tests commit in a foreign repo without altering the parent'

committed_head=$(git -C "$linked" rev-parse HEAD)
printf 'uncommitted payload\n' > "${linked}/rejected-change"
git -C "$linked" add rejected-change
expected_tree=$(git -C "$linked" write-tree)
status=0
PROBE_ROOT="$test_root" PROBE_FAIL=1 git -C "$linked" commit --quiet -m 'Reject failing companion' \
  > "${test_root}/rejected.log" 2>&1 || status=$?
[[ "$status" == 1 ]] || fail "failing companion commit returned $status instead of 1"
grep -Fx 'Injected companion failure' "${test_root}/rejected.log"
actual_head=$(git -C "$linked" rev-parse HEAD)
[[ "$actual_head" == "$committed_head" ]] || fail 'failed hook still created a commit'
actual_index=$(git -C "$linked" write-tree)
[[ "$actual_index" == "$expected_tree" ]] || fail 'failed hook changed the staged tree'
cmp "${repo}/.git/config" "${test_root}/parent-config"
echo 'ok   failing companion still rejects the outer commit'

fake_bin="${test_root}/bin"
mkdir "$fake_bin"
real_git=$(command -v git)
cat > "${fake_bin}/git" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'rev-parse --local-env-vars' ]]; then
  echo 'Injected Git environment lookup failure' >&2
  exit 29
fi
exec "$REAL_GIT" "$@"
BASH
chmod +x "${fake_bin}/git"
cat > "${linked}/tests/should-not-run.bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
touch "$PROBE_ROOT/should-not-run"
BASH
status=0
PROBE_ROOT="$test_root" REAL_GIT="$real_git" PATH="${fake_bin}:${PATH}" \
  make --no-print-directory -C "$linked" test TEST_FILES=tests/should-not-run.bash \
  > "${test_root}/lookup.log" 2>&1 || status=$?
[[ "$status" == 2 ]] || fail "Git lookup failure returned $status instead of 2"
grep -Fx 'Injected Git environment lookup failure' "${test_root}/lookup.log"
[[ ! -e "${test_root}/should-not-run" ]] || fail 'test ran after Git lookup failed'
echo 'ok   Git environment lookup failure stops the test runner'

[[ ! -e "${GIT_CONFIG_GLOBAL}.hook-ran" ]] || fail 'inherited global hook ran in a fixture'
echo 'All make test isolation cases passed'
