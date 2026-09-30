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

# --- installer: config-free common-hooks-dir install -------------------------
# It installs ONE hook in the common hooks dir and writes NO git config, so the
# whole extensions.worktreeConfig / core.bare landmine is gone.
MAIN="$ROOT/main"
git -C . init -q "$MAIN" >/dev/null 2>&1 || git init -q "$MAIN"
git -C "$MAIN" commit -q --allow-empty -m init
mkdir -p "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks"
install -m 0755 "$HOOK" "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
git -C "$MAIN" worktree add -q "$ROOT/wtA" -b wtA >/dev/null 2>&1
git -C "$MAIN" worktree add -q "$ROOT/wtB" -b wtB >/dev/null 2>&1

bash "$INSTALL" "$ROOT/wtA" >/dev/null 2>&1; eq "6. installer on wtA -> exit 0" 0 "$?"
# the hook lands in the COMMON hooks dir, pointing at the shared payload
dest="$MAIN/.git/hooks/pre-push"
[ -e "$dest" ] && [ "$(readlink -f "$dest")" = "$(readlink -f "$MAIN/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push")" ] \
  && pass "6. common hooks dir has the pre-push hook" || fail "6. common hooks dir has the pre-push hook" "$(readlink "$dest" 2>/dev/null)"
# every linked worktree resolves hooks to that same common dir
eq "6. wtA resolves hooks to the common dir" "$MAIN/.git/hooks" "$(git -C "$ROOT/wtA" rev-parse --git-path hooks 2>/dev/null)"

# 7. CONTROL: the installer writes NO git config (no worktreeConfig, no
#    core.bare / core.worktree churn) -- the poison bug class is impossible.
eq "7. installer does NOT enable extensions.worktreeConfig" "" \
  "$(git config -f "$MAIN/.git/config" --get extensions.worktreeConfig 2>/dev/null)"
eq "7. installer leaves no core.worktree in the common config" "" \
  "$(git config -f "$MAIN/.git/config" --get core.worktree 2>/dev/null)"
[ ! -e "$MAIN/.git/config.worktree" ] && pass "7. no per-worktree config.worktree written" || fail "7. no per-worktree config.worktree written"

bash "$INSTALL" "$ROOT/wtA" >/dev/null 2>&1; eq "8. installer is idempotent" 0 "$?"
bash "$INSTALL" "$ROOT/not-a-repo-$$" >/dev/null 2>&1; eq "8. non-git dir -> exit 2" 2 "$?"

# 9. CONTROL: a repo carrying core.bare=true in its COMMON config is UNAFFECTED
#    by the installer -- it never enables worktreeConfig, so it cannot flip the
#    main checkout to bare. The main stays exactly as it was.
MB="$ROOT/barelm"
git -C . init -q "$MB" >/dev/null 2>&1 || git init -q "$MB"
git -C "$MB" commit -q --allow-empty -m init
mkdir -p "$MB/csi-spl-orc/src/bash/features/spawn-agents/hooks"
install -m 0755 "$HOOK" "$MB/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
git -C "$MB" worktree add -q "$ROOT/wtLM" -b wtLM >/dev/null 2>&1
bash "$INSTALL" "$ROOT/wtLM" >/dev/null 2>&1; eq "9. installer on any repo -> exit 0" 0 "$?"
eq "9. it did NOT enable worktreeConfig (no bare landmine)" "" \
  "$(git config -f "$MB/.git/config" --get extensions.worktreeConfig 2>/dev/null)"
[ -e "$MB/.git/hooks/pre-push" ] && pass "9. the common hook is installed" || fail "9. the common hook is installed"

# 11. the hook REFUSES when the common config is poisoned with core.worktree
git -C "$REPO" config core.worktree /somewhere/else
( cd "$REPO" && bash "$HOOK" origin file://x >/dev/null 2>&1 ); eq "11. poisoned common core.worktree -> hook refuses (exit 1)" 1 "$?"
# ... but the override still lets a fixer through
( cd "$REPO" && env SPL_PREPUSH_OVERRIDE=1 bash "$HOOK" origin file://x >/dev/null 2>&1 ); eq "11. ... override still escapes the poison" 0 "$?"
git -C "$REPO" config --unset-all core.worktree 2>/dev/null || true

echo "-- test-pre-push-hook.sh: $fails failed"
[ "$fails" -eq 0 ]
