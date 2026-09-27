#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/nautilus-companion-env.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
real_make=$(command -v make)
mkdir "${test_root}/smoke-bin" "${test_root}/bounded-bin"
cat > "${test_root}/smoke-bin/make" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
for name in MAKEFLAGS MFLAGS MAKELEVEL GNUMAKEFLAGS MAKEOVERRIDES MAKEFILES; do
  if declare -p "$name" > /dev/null 2>&1; then
    printf 'leaked %s\n' "$name" >> "$ENV_MARKER"
    exit 82
  fi
done
echo clean >> "$ENV_MARKER"
# Stop at the fixture boundary: the parent must not interpret this as a pass.
exit 83
BASH
cat > "${test_root}/bounded-bin/make" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
depth=$((${PROBE_MAKE_DEPTH:-0} + 1))
printf '%s\n' "$depth" >> "$DEPTH_MARKER"
if ((depth > 4)); then
  echo 'Unexpected Make recursion' >&2
  exit 91
fi
export PROBE_MAKE_DEPTH="$depth"
exec "$REAL_MAKE" "$@"
BASH
chmod +x "${test_root}/smoke-bin/make" "${test_root}/bounded-bin/make"
failures=0

# Exercise every Make-specific companion's real entry point, including future additions.
for companion in "${SCRIPT_DIR}"/test-make-*.bash; do
  : > "${test_root}/environment"
  status=0
  env MAKEFLAGS=n MFLAGS=-n MAKELEVEL=7 GNUMAKEFLAGS=i MAKEOVERRIDES=poison MAKEFILES=poison \
    ENV_MARKER="${test_root}/environment" PATH="${test_root}/smoke-bin:${PATH}" \
    bash "$companion" > "${test_root}/smoke.log" 2>&1 || status=$?
  if [[ "$status" == 0 ]] || ! grep -Fx clean "${test_root}/environment" > /dev/null ||
    grep -q '^leaked ' "${test_root}/environment"; then
    printf 'FAIL %s did not isolate its Make boundary\n' "$companion" >&2
    cat "${test_root}/environment" "${test_root}/smoke.log" >&2
    failures=$((failures + 1))
  else
    printf 'ok   %s isolates Make state and rejects failure\n' "${companion##*/}"
  fi
done

repo="${test_root}/repo"
mkdir "$repo"
cp "${REPO_ROOT}/Makefile" "${REPO_ROOT}/tools.toml" "$repo/"
cp -R "${REPO_ROOT}/scripts" "${REPO_ROOT}/tests" "$repo/"
cat > "${repo}/tests/test-make-test.bash" << 'BASH'
#!/usr/bin/env bash
set -euo pipefail
echo selected >> "$SELECT_MARKER"
exit "$SELECT_STATUS"
BASH
cat > "${test_root}/inherited.mk" << 'MAKE'
$(error Inherited MAKEFILES was read)
MAKE

for mode in healthy dry-run ignore-errors environment-override gnu-dry-run gnu-ignore-errors extra-makefile; do
  : > "${test_root}/selected"
  : > "${test_root}/depth"
  environment=(env -u MAKEFLAGS -u MFLAGS -u MAKELEVEL -u GNUMAKEFLAGS -u MAKEOVERRIDES -u MAKEFILES
    -u TEST_FILES -u PROBE_MAKE_DEPTH
    "SELECT_MARKER=${test_root}/selected" "DEPTH_MARKER=${test_root}/depth"
    "REAL_MAKE=$real_make" "PATH=${test_root}/bounded-bin:${PATH}")
  command=(bash "${repo}/tests/test-make-test-selection.bash")
  expected_status=0
  selected_status=0
  case "$mode" in
    dry-run) environment+=(MAKEFLAGS=n MFLAGS=-n MAKELEVEL=7) ;;
    ignore-errors)
      environment+=(MAKEFLAGS=i MFLAGS=-i MAKELEVEL=7)
      expected_status=2
      selected_status=47
      ;;
    environment-override)
      command=(make --no-print-directory -C "$repo" -e test TEST_FILES=tests/test-make-test-selection.bash)
      ;;
    gnu-dry-run) environment+=(GNUMAKEFLAGS=n) ;;
    gnu-ignore-errors)
      environment+=(GNUMAKEFLAGS=i)
      expected_status=2
      selected_status=47
      ;;
    extra-makefile) environment+=("MAKEFILES=${test_root}/inherited.mk") ;;
  esac
  status=0
  "${environment[@]}" "SELECT_STATUS=$selected_status" "${command[@]}" \
    > "${test_root}/selection.log" 2>&1 || status=$?
  selected=$(cat "${test_root}/selected")
  depths=$(cat "${test_root}/depth")
  expected_depths=1
  if [[ "$mode" == environment-override ]]; then
    expected_depths=$'1\n2'
  fi
  if [[ "$status" != "$expected_status" || "$selected" != selected || "$depths" != "$expected_depths" ]]; then
    printf 'FAIL %s: exit %s, selected <%s>, depths <%s>\n' "$mode" "$status" "$selected" "$depths" >&2
    cat "${test_root}/selection.log" >&2
    failures=$((failures + 1))
  else
    printf 'ok   %s executes the selected test once and preserves its result\n' "$mode"
  fi
done

if ((failures > 0)); then
  printf '%s companion environment tests failed\n' "$failures" >&2
  exit 1
fi
echo 'All companion environment tests passed'
