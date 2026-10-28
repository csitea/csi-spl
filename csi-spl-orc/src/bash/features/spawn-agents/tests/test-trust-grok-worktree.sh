#!/usr/bin/env bash
# test-trust-grok-worktree.sh — grok trusts a linked worktree only through its
# MAIN checkout's key (SPL-4065).
#
# 2026-10-28: g-563 (a reviewer on another repo) restarted in its worktree
# <repo>-wt/g-563 and sat on grok's "Do you trust the contents of
# this directory? <repo>": trust-workdir.sh wrote only the worktree
# key, and grok 1.0.70 (`grok inspect --json` .projectTrusted) reads a linked
# worktree as trusted only with its main checkout's key. csi-spl seats never
# hit it: /opt/csi/csi-spl had been trusted by hand long before.
#   1. grok on a linked worktree: the worktree AND its main checkout keys
#   2. --settle verifies both keys (exit 0)
#   3. a second run adds nothing (idempotent)
#   4. a main checkout itself: its own key only
#   5. a plain subdir of a worktree: no main checkout key (never a parent)
#   6. claude on a linked worktree: the worktree key only
#   7. a dir outside git: its own key only
#   8. a real grok, when one is on PATH: .projectTrusted true (info only)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SPOOL_ROOT="$TMP/spool" SPOOL_TEST=1; mkdir -p "$SPOOL_ROOT"
H="$TMP/home"; mkdir -p "$H/.grok"
git -c init.defaultBranch=master init -q "$TMP/repo"
git -C "$TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$TMP/repo" worktree add -q -b w1 "$TMP/repo-wt/w1"
mkdir -p "$TMP/repo-wt/w1/sub" "$TMP/plain"
MAIN="$(cd "$TMP/repo" && pwd -P)"; WT="$(cd "$TMP/repo-wt/w1" && pwd -P)"
STORE="$H/.grok/trusted_folders.toml"
keys() { grep -c "^\[folders\.\"$1\"\]" "$STORE" 2>/dev/null || true; }
trust() { HOME="$H" TRUST_SETTLE_SECS=0.3 bash "$T_SCRIPTS/trust-workdir.sh" "$@" "$(id -un)" grok 2>&1; }

: >"$STORE"
out="$(trust "$WT")"
eq "1a. grok, linked worktree: the worktree key" 1 "$(keys "$WT")"
eq "1b. grok, linked worktree: its main checkout key" 1 "$(keys "$MAIN")"
has "1c. it says so" "main checkout $MAIN" "$out"

: >"$STORE"; rc=0
out="$(trust --settle "$WT")" || rc=$?
eq "2a. --settle on a linked worktree exits 0" 0 "$rc"
has "2b. --settle verified it" "verified $WT" "$out"
eq "2c. ... with the main checkout key in the store" 1 "$(keys "$MAIN")"
sleep 0.5

before="$(cat "$STORE")"; trust "$WT" >/dev/null
eq "3. a second run adds nothing" "$before" "$(cat "$STORE")"

: >"$STORE"; trust "$MAIN" >/dev/null
eq "4. a main checkout: its own key, one block" 1 "$(grep -c '^\[folders\.' "$STORE")"

: >"$STORE"; trust "$WT/sub" >/dev/null
eq "5a. a subdir of a worktree: its own key" 1 "$(keys "$WT/sub")"
eq "5b. ... and no main checkout key" 0 "$(keys "$MAIN")"

echo '{"projects": {}}' >"$H/.claude.json"
HOME="$H" bash "$T_SCRIPTS/trust-workdir.sh" "$WT" "$(id -un)" claude >/dev/null 2>&1
eq "6. claude, linked worktree: the worktree key only" "$WT" \
  "$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["projects"]))' "$H/.claude.json")"

: >"$STORE"; trust "$TMP/plain" >/dev/null
eq "7. a dir outside git: its own key only" 1 "$(grep -c '^\[folders\.' "$STORE")"

if command -v grok >/dev/null 2>&1; then
  : >"$STORE"; trust "$WT" >/dev/null
  mkdir -p "$TMP/gh"; cp "$STORE" "$TMP/gh/trusted_folders.toml"
  pt="$(cd "$WT" && GROK_HOME="$TMP/gh" timeout 30 grok inspect --json 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin).get("projectTrusted"))' 2>/dev/null)"
  echo "info - 8. real grok ($(grok --version 2>/dev/null | sed -n 1p)) .projectTrusted on the worktree: ${pt:-unread}"
else
  echo "info - 8. no grok on PATH: the real-grok read is skipped"
fi

t_done
