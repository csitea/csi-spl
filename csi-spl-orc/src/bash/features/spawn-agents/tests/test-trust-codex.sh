#!/usr/bin/env bash
# test-trust-codex.sh — trust-workdir.sh knows the codex kind (SPL-5300).
#
# 2026-11-11 on box 1: spawn-window.sh started o-629 in its linked worktree;
# trust-workdir.sh printed "unknown agent 'codex'", and Codex 0.166.0 stopped
# on "Trust this folder? 1. Trust and continue 2. Quit" naming the MAIN
# checkout. Codex keeps trust in $CODEX_HOME (~/.codex)/config.toml as
# [projects."<dir>"] trust_level = "trusted"; the hand-given answer wrote the
# main checkout's key there.
#   1. codex on a linked worktree: the worktree AND its main checkout keys,
#      the rest of config.toml kept
#   2. --settle verifies (exit 0)
#   3. a second run changes nothing (idempotent)
#   4. an "untrusted" entry turns trusted, no second table
#   5. CODEX_HOME is honoured
#   6. no codex home: skipped, nothing created
#   7. codex alone writes no other kind's store
#   8. spool_start_dialog names codex's trust dialog "trust prompt"
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export SPOOL_ROOT="$TMP/spool" SPOOL_TEST=1; mkdir -p "$SPOOL_ROOT"
H="$TMP/home"; mkdir -p "$H/.codex"
git -c init.defaultBranch=master init -q "$TMP/repo"
git -C "$TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$TMP/repo" worktree add -q -b w1 "$TMP/repo-wt/w1"
MAIN="$(cd "$TMP/repo" && pwd -P)"; WT="$(cd "$TMP/repo-wt/w1" && pwd -P)"
STORE="$H/.codex/config.toml"
unset CODEX_HOME
# level KEY [FILE]: the trust_level codex would read for KEY, "-" when none
level() {
  python3 -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
print(d.get("projects", {}).get(sys.argv[2], {}).get("trust_level", "-"))' "${2:-$STORE}" "$1" 2>&1
}
trust() { HOME="$H" TRUST_SETTLE_SECS=0.3 bash "$T_SCRIPTS/trust-workdir.sh" "$@" "$(id -un)" codex 2>&1; }
SEED='cli_auth_credentials_store = "file"

[analytics]
enabled = false
'

printf '%s' "$SEED" >"$STORE"
out="$(trust "$WT")"
hasnt "1a. codex is a known kind" "unknown agent" "$out"
eq "1b. codex, linked worktree: the worktree key" trusted "$(level "$WT")"
eq "1c. codex, linked worktree: its main checkout key" trusted "$(level "$MAIN")"
eq "1d. the other keys are kept" "file False" "$(python3 -c 'import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb")); print(d["cli_auth_credentials_store"], d["analytics"]["enabled"])' "$STORE" 2>&1)"

printf '%s' "$SEED" >"$STORE"; rc=0
out="$(trust --settle "$WT")" || rc=$?
eq "2a. --settle on a linked worktree exits 0" 0 "$rc"
has "2b. --settle verified it for codex" "verified $WT for codex" "$out"
sleep 0.5

before="$(cat "$STORE")"; trust "$WT" >/dev/null
eq "3. a second run changes nothing" "$before" "$(cat "$STORE")"

printf '%s\n[projects."%s"]\ntrust_level = "untrusted"\n' "$SEED" "$MAIN" >"$STORE"
trust "$MAIN" >/dev/null
eq "4a. an untrusted entry turns trusted" trusted "$(level "$MAIN")"
eq "4b. ... in its one table" 1 "$(grep -c "^\[projects\.\"$MAIN\"\]" "$STORE")"

mkdir -p "$TMP/ch"; : >"$TMP/ch/config.toml"
HOME="$H" CODEX_HOME="$TMP/ch" bash "$T_SCRIPTS/trust-workdir.sh" "$MAIN" "$(id -un)" codex >/dev/null 2>&1
eq "5. CODEX_HOME is honoured" trusted "$(level "$MAIN" "$TMP/ch/config.toml")"

H2="$TMP/home2"; mkdir -p "$H2"
out="$(HOME="$H2" bash "$T_SCRIPTS/trust-workdir.sh" "$MAIN" "$(id -un)" codex 2>&1)"
has "6a. no codex home: skipped" "codex (no store)" "$out"
check "6b. ... and nothing created" test ! -e "$H2/.codex"

mkdir -p "$H/.grok" "$H/.qwen"; echo '{"projects": {}}' >"$H/.claude.json"; : >"$H/.grok/trusted_folders.toml"
trust "$WT" >/dev/null
eq "7. codex alone writes no other kind's store" '{"projects": {}}|' \
  "$(cat "$H/.claude.json")|$(cat "$H/.grok/trusted_folders.toml")"

# Codex 0.166.0 on o-629's pane (2026-11-11, box 1, n=1, as c-002 read it)
# shellcheck source=../lib/start-check.inc.sh
. "$T_FEAT/lib/start-check.inc.sh"
codex_trust="  Folder access

  <MAIN CHECKOUT>

  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings.

› 1. Trust and continue
  2. Quit"
eq "8. codex trust dialog named" "trust prompt" "$(spool_start_dialog <<<"$codex_trust")"

# 9. spawn-window's start check on a codex pane: the dialog = exit 3 (spawn
# exit 11), codex's idle screen = started with spawn-window's READY_RE.
# Codex 0.166.0 idle, o-629's pane %738 (2026-11-11, n=1)
codex_idle="  Worked for 35s • 12:33 PM


› Ask Codex to do anything

  GPT-6-Luna default · <WORKTREE> · Read the seed prompt
  ? for shortcuts"
READY_RE="$(sed -n "s/^.*\[ \"\$KIND\" = codex \] && START_CHECK_READY_RE='\(.*\)'$/\1/p" "$T_SCRIPTS/spawn-window.sh")"
check "9a. spawn-window sets a codex READY_RE" test -n "$READY_RE"
cap_file() { cat "$TMP/screen.$1" 2>/dev/null; }
printf '%s\n' "$codex_trust" >"$TMP/screen.t"; printf '%s\n' "$codex_idle" >"$TMP/screen.i"
out="$(START_CHECK_POLL=0.2 START_CHECK_READY_RE="$READY_RE" spool_start_check t 2 cap_file)"; rc=$?
eq "9b. the codex trust dialog: exit 3" 3 "$rc"; eq "9c. ... naming it" "trust prompt" "$out"
out="$(START_CHECK_POLL=0.2 START_CHECK_READY_RE="$READY_RE" spool_start_check i 2 cap_file)"; rc=$?
eq "9d. codex idle: started, exit 0" 0 "$rc"
out="$(START_CHECK_POLL=0.2 spool_start_check i 1 cap_file)"; rc=$?
eq "9e. control: no READY_RE, the claude box alone: exit 4" 4 "$rc"

t_done
