#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2739 -- do_box_go_switch, the recorded switch of a box's Go.
#          Hermetic: /usr/local and /etc are a sandbox root (GO_SWITCH_ROOT),
#          curl, sha256sum, sudo and go are stubs on PATH, the journal is a
#          temp path; nothing on this box is read, downloaded or written.
#          1. plain directory: the old tree moves to go<old>, a verified
#             download becomes go<new>, the link, the PATH line, the journal,
#             each login user's go, the rollback line, rc 0
#          2. symlink: the target exists, nothing downloaded, the link moves,
#             the old tree untouched, the rollback names the old link
#          3. already current: NO-OP, nothing called, nothing changed
#          4. sha256 mismatch -> rc 2; no published sha -> rc 1; both refused
#             with nothing changed
#          5. DRY_RUN unset and DRY_RUN=1: nothing changed, nothing
#             downloaded, the exact DRY_RUN=0 re-run line
#          6. GO_VERSION unset or not a version -> refused, nothing called
#
#          CONTROL: FUNC=<a file with a no-op do_box_go_switch> must turn
#          cases 1, 2, 4, 5 and 6 red: a check that cannot fail proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FUNC="${FUNC:-$TEST_DIR/../run/box-go-switch.func.sh}"
[[ -r "$FUNC" ]] || { echo "FAIL: cannot read $FUNC"; exit 1; }
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

NEW=1.26.9
OLD=1.25.1
mkdir -p "$tmp/stub" "$tmp/pkg/go/bin"
export CALLS="$tmp/calls" ROOT="$tmp/root"
printf 'go%s\ntime 2026-10-01T00:00:00Z\n' "$NEW" >"$tmp/pkg/go/VERSION"
printf '#!/usr/bin/env bash\necho "go version go%s linux/amd64"\n' "$NEW" >"$tmp/pkg/go/bin/go"
chmod +x "$tmp/pkg/go/bin/go"
tar -C "$tmp/pkg" -czf "$tmp/go$NEW.tgz" go
GOOD_SHA=$(printf '%064d' 7)
cat >"$tmp/stub/curl" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 1 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
echo "curl $1" >>"$CALLS"
if [[ "$1" == *'mode=json'* ]]; then
  [[ "${STUB_NO_SHA:-0}" == 1 ]] && { echo '[]'; exit 0; }
  printf '[{"version":"go1.26.9","files":[{"filename":"go1.26.9.linux-amd64.tar.gz","sha256":"%s"}]}]\n' "$STUB_PUB_SHA"
  exit 0
fi
cp "$STUB_TGZ" "$out"
STUB
cat >"$tmp/stub/sha256sum" <<'STUB'
#!/usr/bin/env bash
echo "sha256sum $(basename "$1")" >>"$CALLS"
echo "$STUB_FILE_SHA  $1"
STUB
# sudo: `-u <user> bash -lc <cmd>` runs <cmd> as a login shell would see it
# (the stub go reads the sandbox link); anything else runs as is
cat >"$tmp/stub/sudo" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -u ]]; then echo "login $2" >>"$CALLS"; shift 2; [[ "$1 $2" == "bash -lc" ]] && exec bash -c "$3"; fi
exec "$@"
STUB
cat >"$tmp/stub/go" <<'STUB'
#!/usr/bin/env bash
v=$(head -1 "$GO_SWITCH_ROOT/usr/local/go/VERSION" 2>/dev/null)
echo "go version ${v:-none} linux/amd64"
STUB
chmod +x "$tmp/stub/"*
export PATH="$tmp/stub:$PATH" GO_SWITCH_ROOT="$ROOT" GO_SWITCH_JOURNAL="$tmp/var/journal.tsv"
export GO_SWITCH_BOX=box-a GO_SWITCH_USERS="u1 u2" GO_ARCH=amd64 STUB_TGZ="$tmp/go$NEW.tgz"
unset DRY_RUN GO_VERSION GO_SWITCH_REASON AGENT_ID GO_SWITCH_ISSUE GO_SHA256 GO_DL_BASE

# mk_tree <dir> <ver>: a Go tree whose VERSION and bin/go say go<ver>
mk_tree() {
  mkdir -p "$1/bin"
  printf 'go%s\n' "$2" >"$1/VERSION"
  printf '#!/usr/bin/env bash\necho "go version go%s linux/amd64"\n' "$2" >"$1/bin/go"
  chmod +x "$1/bin/go"
}

# fresh <plain|link|current>: a clean sandbox root in that start state
fresh() {
  rm -rf "${ROOT:?}" "${tmp:?}/var"
  mkdir -p "$ROOT/usr/local" "$ROOT/etc/profile.d"
  : >"$CALLS"
  case "$1" in
    plain) mk_tree "$ROOT/usr/local/go" "$OLD" ;;
    link) mk_tree "$ROOT/usr/local/go$OLD" "$OLD"; mk_tree "$ROOT/usr/local/go$NEW" "$NEW"
      ln -s "go$OLD" "$ROOT/usr/local/go" ;;
    current) mk_tree "$ROOT/usr/local/go$NEW" "$NEW"; ln -s "go$NEW" "$ROOT/usr/local/go"
      # shellcheck disable=SC2016  # the profile line, expanded by a login shell
      echo 'PATH="$PATH:/usr/local/go/bin"' >"$ROOT/etc/profile.d/go.sh" ;;
  esac
}

# state: every path under the sandbox with its type, link and content sum
state() {
  (cd "$ROOT" && find . -printf '%p %y %l\n' | sort
    find . -type f -exec md5sum {} + | sort) 2>/dev/null
  [[ ! -e "$GO_SWITCH_JOURNAL" ]] || echo "journal $(wc -l <"$GO_SWITCH_JOURNAL")"
}

# run_switch: one action run in a fresh shell
run_switch() {
  # shellcheck disable=SC1090  # the file under test (FUNC: a control copy)
  ( source "$FUNC"; do_box_go_switch ) 2>&1
}

# case_plain: 1
case_plain() {
  local out rc=0
  fresh plain
  out=$(DRY_RUN=0 GO_VERSION=$NEW GO_SWITCH_REASON='needs 1.26' AGENT_ID=c-900 GO_SWITCH_ISSUE=SPL-1 \
    STUB_PUB_SHA=$GOOD_SHA STUB_FILE_SHA=$GOOD_SHA run_switch) || rc=$?
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  grep -qx "BEFORE /usr/local/go: dir, version $OLD" <<<"$out" || { echo "$out"; return 1; }
  grep -q 'mode=json' "$CALLS" || { cat "$CALLS"; return 1; }
  grep -q "^sha256sum go$NEW.linux-amd64.tar.gz$" "$CALLS" || { cat "$CALLS"; return 1; }
  [[ "$(readlink "$ROOT/usr/local/go")" == "go$NEW" ]] || { ls -l "$ROOT/usr/local"; return 1; }
  [[ "$(head -1 "$ROOT/usr/local/go$NEW/VERSION")" == "go$NEW" ]] || return 1
  [[ ! -L "$ROOT/usr/local/go$OLD" && "$("$ROOT/usr/local/go$OLD/bin/go" version)" == *"go$OLD "* ]] ||
    { echo "the old tree is not kept as go$OLD"; return 1; }
  grep -q '/usr/local/go/bin' "$ROOT/etc/profile.d/go.sh" || return 1
  [[ "$(bash -c ". '$ROOT/etc/profile.d/go.sh'; . '$ROOT/etc/profile.d/go.sh'; echo \"\$PATH\"" |
    tr ':' '\n' | grep -cx /usr/local/go/bin)" == 1 ]] || { echo "the PATH line is not idempotent"; return 1; }
  awk -F '\t' -v o="$OLD" -v n="$NEW" 'NR == 1 && NF == 8 && $2 == "box-a" && $3 == "c-900" &&
    $4 == "SPL-1" && $5 == "switch" && $6 == o && $7 == n && $8 == "needs 1.26" { ok = 1 }
    END { exit !(ok && NR == 1) }' "$GO_SWITCH_JOURNAL" || { cat "$GO_SWITCH_JOURNAL"; return 1; }
  grep -qx "AFTER u1 login shell: go$NEW" <<<"$out" || { echo "$out"; return 1; }
  grep -qx "AFTER u2 login shell: go$NEW" <<<"$out" || { echo "$out"; return 1; }
  grep -qx "ROLLBACK: sudo rm '$ROOT/usr/local/go' && sudo mv '$ROOT/usr/local/go$OLD' '$ROOT/usr/local/go'" <<<"$out" ||
    { echo "$out"; return 1; }
}
if case_plain; then pass "1. plain directory: old tree kept, verified download linked, PATH line, journal, login checks, rollback"
else fail "1. plain directory"; fi

# case_link: 2
case_link() {
  local out rc=0 old_before
  fresh link
  old_before=$(cd "$ROOT/usr/local/go$OLD" && find . -type f -exec md5sum {} + | sort)
  out=$(DRY_RUN=0 GO_VERSION=go$NEW GO_SWITCH_REASON=r AGENT_ID=c-901 run_switch) || rc=$?
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  ! grep -q '^curl ' "$CALLS" || { cat "$CALLS"; return 1; }
  [[ "$(readlink "$ROOT/usr/local/go")" == "go$NEW" ]] || return 1
  [[ "$(cd "$ROOT/usr/local/go$OLD" && find . -type f -exec md5sum {} + | sort)" == "$old_before" ]] || return 1
  grep -qx "ROLLBACK: sudo ln -sfn 'go$OLD' '$ROOT/usr/local/go'" <<<"$out" || { echo "$out"; return 1; }
}
if case_link; then pass "2. symlink: nothing downloaded, the link moves, the old tree untouched, rollback names it"
else fail "2. symlink"; fi

# case_current: 3
case_current() {
  local out rc=0 before
  fresh current
  before=$(state)
  out=$(DRY_RUN=0 GO_VERSION=$NEW GO_SWITCH_REASON=r AGENT_ID=c-902 run_switch) || rc=$?
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  grep -q '^NO-OP: ' <<<"$out" || { echo "$out"; return 1; }
  [[ ! -s "$CALLS" && "$(state)" == "$before" ]] || { cat "$CALLS"; return 1; }
}
if case_current; then pass "3. already current: NO-OP, nothing called, nothing changed"
else fail "3. already current"; fi

# case_refused <want rc> <env...>: 4, the sha cannot be trusted
case_refused() {
  local want="$1" out rc=0 before
  shift
  fresh plain
  before=$(state)
  # shellcheck disable=SC2016  # $0 is the sourced file, for the child shell
  out=$(env "$@" DRY_RUN=0 GO_VERSION=$NEW GO_SWITCH_REASON=r AGENT_ID=c-903 bash -c \
    'source "$0"; do_box_go_switch' "$FUNC" 2>&1) || rc=$?
  [[ "$rc" == "$want" ]] || { echo "rc $rc, want $want: $out"; return 1; }
  grep -q '^REFUSED: ' <<<"$out" || { echo "$out"; return 1; }
  [[ "$(state)" == "$before" ]] || { echo "the sandbox changed"; return 1; }
}
if case_refused 2 STUB_PUB_SHA="$GOOD_SHA" STUB_FILE_SHA="$(printf '%064d' 8)"; then
  pass "4. sha256 mismatch: rc 2, refused, nothing changed"
else fail "4. sha256 mismatch"; fi
if case_refused 2 GO_SHA256="$(printf '%064d' 9)" STUB_PUB_SHA="$GOOD_SHA" STUB_FILE_SHA="$GOOD_SHA"; then
  pass "4. GO_SHA256 override that does not match: rc 2, refused"
else fail "4. GO_SHA256 override mismatch"; fi
if case_refused 1 STUB_NO_SHA=1 STUB_FILE_SHA="$GOOD_SHA"; then
  pass "4. no published sha256 and no GO_SHA256: rc 1, refused, nothing changed"
else fail "4. unverifiable version"; fi

# case_dry <DRY_RUN value or empty>: 5
case_dry() {
  local out rc=0 before want
  fresh plain
  before=$(state)
  want="DRY_RUN=0 GO_VERSION='$NEW' GO_SWITCH_REASON='it'\\''s needed' AGENT_ID='c-904' ./run -a do_box_go_switch"
  if [[ -n "$1" ]]; then
    out=$(DRY_RUN="$1" GO_VERSION=$NEW GO_SWITCH_REASON="it's needed" AGENT_ID=c-904 run_switch) || rc=$?
  else
    out=$(GO_VERSION=$NEW GO_SWITCH_REASON="it's needed" AGENT_ID=c-904 run_switch) || rc=$?
  fi
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  [[ ! -s "$CALLS" && "$(state)" == "$before" ]] || { cat "$CALLS"; return 1; }
  grep -q '^DRY RUN: nothing changed$' <<<"$out" || { echo "$out"; return 1; }
  grep -q "^STEP mv $ROOT/usr/local/go $ROOT/usr/local/go$OLD" <<<"$out" || { echo "$out"; return 1; }
  [[ "$(tail -1 <<<"$out")" == "$want" ]] || { printf 'want: %s\ngot:  %s\n' "$want" "$(tail -1 <<<"$out")"; return 1; }
}
if case_dry ""; then pass "5. DRY_RUN unset: the plan, nothing changed, the exact DRY_RUN=0 re-run line"
else fail "5. DRY_RUN unset"; fi
if case_dry 1; then pass "5. DRY_RUN=1: the plan, nothing changed, the exact DRY_RUN=0 re-run line"
else fail "5. DRY_RUN=1"; fi

# 6: GO_VERSION missing or not a version -> refused before any command
fresh plain
before=$(state)
for spec in "-u GO_VERSION" "GO_VERSION=" "GO_VERSION=latest"; do
  rc=0
  # shellcheck disable=SC2086,SC2016  # spec is an env argument list; $0 for the child
  out=$(env $spec DRY_RUN=0 GO_SWITCH_REASON=r AGENT_ID=c-905 bash -c 'source "$0"; do_box_go_switch' "$FUNC" 2>&1) || rc=$?
  if [[ "$rc" != 0 && ! -s "$CALLS" && "$(state)" == "$before" ]] && grep -qE 'GO_VERSION (must be set|.* is not X.Y)' <<<"$out"; then
    pass "6. $spec: refused, nothing called"
  else fail "6. $spec: rc $rc, $out"; fi
done

echo "box-go-switch: $fails failure(s)"
[[ "$fails" == 0 ]]
