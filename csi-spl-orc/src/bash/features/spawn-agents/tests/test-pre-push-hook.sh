#!/usr/bin/env bash
# test-pre-push-hook.sh (SPL-1252) — the deploy-gate pre-push hook and its
# per-worktree installer, with a STUBBED gate so nothing heavy runs.
#   HOOK
#     1. gate passes            -> exit 0, tree stamped green
#     2. gate fails             -> exit 1 (REFUSE)
#     3. SPL_PREPUSH_OVERRIDE=1  -> exit 0 even when the gate would fail, audited
#     4. an already-green tree   -> exit 0 WITHOUT running the gate (rebase-retry)
#     5. not the spool tree      -> exit 0 (fail-open), never blocks a foreign repo
#   INSTALLER
#     6. installs core.hooksPath for ONE worktree only, others untouched
#     7. idempotent (second run still 0)
#     8. a non-git dir           -> exit 2
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$HERE/../scripts" && pwd)"
HOOK="$(cd "$HERE/../hooks" && pwd)/pre-push"
INSTALL="$SCRIPTS/install-pre-push-hook.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# --- a throwaway spool-shaped repo with a STUB gate --------------------------
REPO="$ROOT/repo"
mkdir -p "$REPO/csi-spl-iac"
cat >"$REPO/csi-spl-iac/run" <<'EOF'
#!/usr/bin/env bash
# stub ./run: the gate fails iff STUB_FAIL=1; args (-a do_check_pre_push) ignored
[ "${STUB_FAIL:-0}" = 1 ] && exit 7
exit 0
EOF
chmod +x "$REPO/csi-spl-iac/run"
git -C "$REPO" init -q
echo seed >"$REPO/seed"; git -C "$REPO" add -A; git -C "$REPO" commit -qm seed

# Run the hook with CWD at the repo top (as git does), an isolated log/stamp dir.
run_hook() {  # <logdir> [env assignments...]
  local ld="$1"; shift
  ( cd "$REPO" && env "$@" SPL_PREPUSH_LOG_DIR="$ld" bash "$HOOK" origin file://x >/dev/null 2>&1 )
}

# 1. gate passes
L="$ROOT/l1"; run_hook "$L"; eq "1. gate passes -> exit 0" 0 "$?"
grep -q '^PASS ' <(sed 's/^[^ ]* [^ ]* //' "$L/pre-push.log") 2>/dev/null \
  && pass "1. logged PASS" || fail "1. logged PASS"
[ -s "$L/pre-push.green" ] && pass "1. tree stamped green" || fail "1. tree stamped green"

# 2. gate fails
L="$ROOT/l2"; run_hook "$L" STUB_FAIL=1; eq "2. gate fails -> exit 1 (REFUSE)" 1 "$?"
grep -q 'REFUSE' "$L/pre-push.log" && pass "2. logged REFUSE" || fail "2. logged REFUSE"

# 3. override beats a failing gate
L="$ROOT/l3"; run_hook "$L" STUB_FAIL=1 SPL_PREPUSH_OVERRIDE=1; eq "3. override -> exit 0" 0 "$?"
grep -q 'OVERRIDE' "$L/pre-push.log" && pass "3. logged OVERRIDE" || fail "3. logged OVERRIDE"

# 4. an already-green tree skips the gate (so a failing stub still passes)
L="$ROOT/l4"; run_hook "$L"; eq "4. first run greens the tree (exit 0)" 0 "$?"
run_hook "$L" STUB_FAIL=1; eq "4. same tree skips the gate despite STUB_FAIL" 0 "$?"
grep -q 'SKIP-GREEN' "$L/pre-push.log" && pass "4. logged SKIP-GREEN" || fail "4. logged SKIP-GREEN"

# 5. a non-spool repo (no csi-spl-iac/run) -> fail-open
NS="$ROOT/nonspool"; git -C . init -q "$NS" >/dev/null 2>&1 || git init -q "$NS"
git -C "$NS" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
L="$ROOT/l5"
( cd "$NS" && env SPL_PREPUSH_LOG_DIR="$L" bash "$HOOK" origin file://x >/dev/null 2>&1 )
eq "5. not the spool tree -> exit 0 (fail-open)" 0 "$?"

# --- installer isolation -----------------------------------------------------
# The installer resolves the hooks dir from the common git dir's parent, so the
# throwaway main checkout needs the real hook payload at that path.
MAIN="$ROOT/main"
git -C . init -q "$MAIN" >/dev/null 2>&1 || git init -q "$MAIN"
git -C "$MAIN" commit -q --allow-empty -m init
mkdir -p "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks"
install -m 0755 "$HOOK" "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
git -C "$MAIN" worktree add -q "$ROOT/wtA" -b wtA >/dev/null 2>&1
git -C "$MAIN" worktree add -q "$ROOT/wtB" -b wtB >/dev/null 2>&1

bash "$INSTALL" "$ROOT/wtA" >/dev/null 2>&1; eq "6. installer on wtA -> exit 0" 0 "$?"
hp="$(git -C "$ROOT/wtA" config --get core.hooksPath 2>/dev/null)"
[ "$hp" = "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks" ] \
  && pass "6. wtA core.hooksPath set" || fail "6. wtA core.hooksPath set" "$hp"
eq "6. wtB untouched" "" "$(git -C "$ROOT/wtB" config --get core.hooksPath 2>/dev/null)"
eq "6. main untouched" "" "$(git -C "$MAIN" config --get core.hooksPath 2>/dev/null)"

bash "$INSTALL" "$ROOT/wtA" >/dev/null 2>&1; eq "7. installer is idempotent" 0 "$?"
bash "$INSTALL" "$ROOT/not-a-repo-$$" >/dev/null 2>&1; eq "8. non-git dir -> exit 2" 2 "$?"

echo "-- test-pre-push-hook.sh: $fails failed"
[ "$fails" -eq 0 ]
