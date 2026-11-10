#!/usr/bin/env bash
# Purpose: go-modcache-sweep.sh on a fixture module cache and fixture
# checkouts in a mktemp dir (no go, no network; a sleep under a unique name,
# set as GO_MODCACHE_BUSY_RX, stands in for a running build):
#   - the refusals: a bad DRY_RUN, GO_MODCACHE_AGE_D 0, roots with no go.mod /
#     go.sum, a root dir the scan cannot read; no cache is OK
#   - KEEP used: a go.sum line, a go.sum /go.mod-only line, a go.mod require of
#     a case-escaped path (github.com/!big!corp), the toolchain a go.mod asks
#   - KEEP recent: an unnamed version with a fresh file
#   - planned: an unnamed old version (extracted dir + download files, read
#     only), one with download files only, an unasked toolchain; a go.sum in
#     node_modules or inside the cache (a scan root too) names nothing
#   - KEEP busy: the cache owner runs go
#   - the dry run removes nothing; DRY_RUN=0 removes the planned ones only,
#     read-only files included, and keeps @v/list
#   - red controls: with each keep check cut from a copy of the script, the
#     version it guarded is planned (or the refused run goes ahead)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/go-modcache-sweep.sh"
T="$(mktemp -d)"
trap 'kill "${gp:-}" 2>/dev/null; chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
bash -n "$SCRIPT" || { echo "FAIL bash -n"; exit 1; }
me="$(id -un)"
C="$T/cache" D="$T/cache/cache/download" S="$T/src"

# ver <escaped module> <version> [x]: download files, and the extracted dir with x
ver() {
  mkdir -p "$D/$1/@v"; echo "$2" >"$D/$1/@v/list"
  for e in info mod zip ziphash; do echo "$1 $2" >"$D/$1/@v/$2.$e"; done
  [[ "${3:-}" == x ]] && { mkdir -p "$C/$1@$2/sub"; echo x >"$C/$1@$2/sub/a.go"; }
  return 0
}
fixture() {
  chmod -R u+w "$T" 2>/dev/null; rm -rf "$C" "$S"
  ver example.com/used v1.0.0 x; ver example.com/modonly v1.1.0; ver 'github.com/!big!corp/lib' v2.0.0 x
  ver example.com/old v0.9.0 x; ver example.com/dlonly v0.1.0; ver example.com/fresh v0.2.0 x
  ver golang.org/toolchain v0.0.1-go1.26.10.linux-amd64 x; ver golang.org/toolchain v0.0.1-go1.25.0.linux-amd64 x
  mkdir -p "$D/sumdb/sum.golang.org/lookup" "$C/cache/vcs/x"; echo 'example.com/old v0.9.0 h1:x=' >"$C/cache/vcs/x/go.sum"
  mkdir -p "$S/app" "$S/web/node_modules/m"
  printf 'module app\n\ngo 1.26\n\ntoolchain go1.26.10\n\nrequire (\n\tgithub.com/BigCorp/lib v2.0.0 // indirect\n)\n' >"$S/app/go.mod"
  printf 'example.com/used v1.0.0 h1:a=\nexample.com/used v1.0.0/go.mod h1:b=\nexample.com/modonly v1.1.0/go.mod h1:c=\n' >"$S/app/go.sum"
  echo 'example.com/old v0.9.0 h1:x=' >"$S/web/node_modules/m/go.sum"
  find "$C" "$S" -exec touch -h -d '30 days ago' {} +
  touch "$C/example.com/fresh@v0.2.0/sub/a.go"
  find "$C" -path "$C/cache" -prune -o -type d -name '*@*' -prune -exec chmod -R a-w {} + # as go leaves them
}
busy="gotest-$$-$RANDOM"
run() { env GO_MODCACHE_SUDO=0 GO_MODCACHE_DIRS="${DIRS-$me:$C}" GO_MODCACHE_ROOTS="${ROOTS:-$S $C}" GO_MODCACHE_BUSY_RX="^$busy\$" "$@" bash "${X:-$SCRIPT}" >"$T/out" 2>&1; }
has() { grep -qE -- "$1" "$T/out"; }
fixture

run DRY_RUN=2; [[ $? == 2 ]] && has REFUSE && pass "1. a bad DRY_RUN is refused" || fail "1. DRY_RUN=2 ($(cat "$T/out"))"
run GO_MODCACHE_AGE_D=0; [[ $? == 2 ]] && has REFUSE && pass "1. GO_MODCACHE_AGE_D 0 is refused" || fail "1. age 0"
mkdir -p "$T/empty"; ROOTS="$T/empty" run; [[ $? == 2 ]] && has "REFUSE no go.mod or go.sum" && pass "1. roots with no go.mod / go.sum are refused" || fail "1. no names ($(cat "$T/out"))"
mkdir -p "$T/locked/x"; chmod 000 "$T/locked"
ROOTS="$S $T/locked" run; rc=$?; chmod 755 "$T/locked"
[[ $rc == 2 ]] && has "REFUSE the go.mod / go.sum scan" && pass "1. an unreadable root dir is refused" || fail "1. unreadable ($rc $(cat "$T/out"))"
DIRS="" GO_MODCACHE_USERS=nobody-here run; [[ $? == 0 ]] && has "OK no Go module cache" && pass "1. no cache is OK" || fail "1. no cache ($(cat "$T/out"))"

run; rc=$?
[[ $rc == 0 ]] && pass "2. dry run exits 0" || fail "2. dry run rc=$rc ($(tail -3 "$T/out"))"
for e in "used [0-9]+KB user=$me example.com/used@v1.0.0" "used [0-9]+KB user=$me example.com/modonly@v1.1.0" \
  "used [0-9]+KB user=$me github.com/BigCorp/lib@v2.0.0" "used [0-9]+KB user=$me golang.org/toolchain@v0.0.1-go1.26.10.linux-amd64" \
  "recent [0-9]+KB user=$me example.com/fresh@v0.2.0"; do
  has "KEEP $e$" && pass "3. KEEP ${e##* }" || fail "3. KEEP $e ($(grep "${e##* }" "$T/out"))"
done
for e in example.com/old@v0.9.0 example.com/dlonly@v0.1.0 golang.org/toolchain@v0.0.1-go1.25.0.linux-amd64; do
  has "PLAN remove [1-9][0-9]*KB user=$me $e$" && pass "4. planned with its size: $e" || fail "4. $e ($(grep "$e" "$T/out"))"
done
has "DONE would-remove=3 " && pass "4. the dry run counts 3" || fail "4. count ($(tail -1 "$T/out"))"
grep -q sumdb "$T/out" && fail "4. sumdb read as a module" || pass "4. sumdb is no module"
[[ -d "$C/example.com/old@v0.9.0" && -f "$D/example.com/dlonly/@v/v0.1.0.zip" ]] && pass "4. the dry run removed nothing" || fail "4. the dry run removed something"

mkdir -p "$T/bin"; ln -s "$(command -v sleep)" "$T/bin/$busy"; "$T/bin/$busy" 300 & gp=$!
sleep 0.3
run; has "KEEP busy user=$me $C" && has "DONE would-remove=0 " && pass "5. a running go keeps the whole cache" || fail "5. busy ($(tail -2 "$T/out"))"
sed -E 's/^  go_busy "\$o" && /  false \&\& /' "$SCRIPT" >"$T/ctl.sh"
X="$T/ctl.sh" run; has "DONE would-remove=3 " && pass "6. control: without the busy check, the busy cache is planned" || fail "6. control busy"
kill "$gp" 2>/dev/null; wait "$gp" 2>/dev/null; gp=""

# control <label> <sed -E script> <ERE the run must show>
control() {
  sed -E "$2" "$SCRIPT" >"$T/ctl.sh"
  if cmp -s "$SCRIPT" "$T/ctl.sh"; then fail "6. control $1: pattern matched nothing"; return; fi
  X="$T/ctl.sh" run
  has "$3" && pass "6. control: without the $1 check, $3" || fail "6. control $1 ($(tail -2 "$T/out"))"
}
control used 's/^  \[\[ -n "\$\{used\[\$1\]:-\}" \]\] && return 0$/  :/' "PLAN remove [0-9]+KB user=$me example.com/used@v1.0.0$"
control escaped 's/lambda m: m.group\(1\).upper\(\)/lambda m: m.group(0)/' "PLAN remove [0-9]+KB user=$me github.com/!big!corp/lib@v2.0.0$"
control toolchain 's/\[\[ -n "\$\{used_tc\[\$\{BASH_REMATCH\[1\]\}\]:-\}" \]\]/false/' "PLAN remove [0-9]+KB user=$me golang.org/toolchain@v0.0.1-go1.26.10"
control recent 's/elif \(\( new > cut \)\); then/elif false; then/' "PLAN remove [0-9]+KB user=$me example.com/fresh@v0.2.0$"
control prune 's/-name node_modules -o //' "KEEP used [0-9]+KB user=$me example.com/old@v0.9.0$"
ROOTS="$T/empty"
control no-names 's/^  \(\( n > 0 \)\) \|\|/  true ||/' "DONE would-remove=[1-9]"
ROOTS="$S $T/locked"; chmod 000 "$T/locked"
control scan-error 's/^  if \[\[ -n "\$bad" \]\]; then/  if false; then/' "DONE would-remove=3 "
chmod 755 "$T/locked"; ROOTS=""

run DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && pass "7. real run exits 0" || fail "7. real run rc=$rc ($(grep -E 'WARN|DONE' "$T/out"))"
[[ ! -e "$C/example.com/old@v0.9.0" && ! -e "$D/example.com/old/@v/v0.9.0.zip" && ! -e "$D/example.com/dlonly/@v/v0.1.0.mod" \
  && ! -e "$C/golang.org/toolchain@v0.0.1-go1.25.0.linux-amd64" ]] && pass "7. the planned versions are gone, read-only files too" || fail "7. not removed ($(grep -E 'REMOVE|WARN' "$T/out"))"
[[ -d "$C/example.com/used@v1.0.0" && -f "$D/example.com/modonly/@v/v1.1.0.mod" && -d "$C/github.com/!big!corp/lib@v2.0.0" \
  && -d "$C/golang.org/toolchain@v0.0.1-go1.26.10.linux-amd64" && -d "$C/example.com/fresh@v0.2.0" ]] && pass "7. every kept version is still there" || fail "7. a kept version was removed"
[[ -f "$D/example.com/old/@v/list" ]] && pass "7. @v/list stays" || fail "7. @v/list removed"
has "DONE removed=3 " && pass "7. the real run counts 3" || fail "7. count ($(tail -1 "$T/out"))"

echo "go-modcache-sweep: ${fails} failure(s)"
[[ "$fails" -eq 0 ]]
