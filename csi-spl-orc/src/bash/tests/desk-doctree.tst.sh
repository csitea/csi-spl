#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_doctree runs one `spool doctree` verb for a desk agent
#          through the desk's installed spool binary, so a lane never sees the
#          desk state or a key path (data rule). The binary is a stub that
#          records its argv and env and, like a real error, names its keys dir.
#   1. the action exists (red before it landed)
#   2. list: the stub runs as `doctree list` with SPOOL_ROOT / SPOOL_HUB_URL /
#      SPOOL_TENANT / SPOOL_KEYS_DIR of the desk; only its output is printed
#   3. a spool error that names the keys dir reaches the output masked
#   4. refused, no spool call: an agent with no seat, an agent missing from
#      the hub roster, a verb outside the doctree list
#   5. refused, no spool call: DOCTREE_IN outside the allowed dirs, a /tmp
#      symlink into the desk state, a --file naming another file, --out
#   6. DOCTREE_IN is passed as --file, as --path for a picture, and replaces
#      an explicit --file naming it
#   7. DRY_RUN=1 (the default) writing verbs make no spool call; reads run
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
D="$T/state/dev/desk/t1/box-desk"
mkdir -p "$D/spool/a-177" "$D/spool/c-002" "$D/spool/.hub" "$D/keys" "$T/state/dev/bin" "$T/in"
echo '{"box-desk":["a-177"]}' >"$D/spool/.hub/roster.json"
echo secret-key >"$D/keys/box.key"
cat >"$T/state/dev/bin/spool" <<'EOF_STUB'
#!/usr/bin/env bash
{ printf 'argv|%s\n' "$*"; printf 'env|%s|%s|%s|%s|%s\n' "$SPOOL_ROOT" "$SPOOL_HUB_URL" "$SPOOL_TENANT" "$SPOOL_KEYS_DIR" "$SPOOL_BOX_ID"; } >>"$CALLS"
if [[ "${STUB_FAIL:-0}" == 1 ]]; then echo "open $SPOOL_KEYS_DIR/box.key: permission denied" >&2; exit 1; fi
echo '{"docs":[{"id":"42","title":"Rebuild guide"}]}'
EOF_STUB
chmod +x "$T/state/dev/bin/spool"
echo "a body" >"$T/in/body.md"

# run [VAR=value]... - the action; stub calls in $T/calls, output in $T/o, rc in $rc
run() {
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
do_spl_desk_doctree' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=a-177 CALLS="$T/calls" "$@" >"$T/o" 2>&1
  rc=$?
}
argv() { sed -n 's/^argv|//p' "$T/calls"; }
no_leak() { ! grep -qF "$T" "$T/o" && ! grep -q secret-key "$T/o"; }

# --- 1. the action exists ------------------------------------------------------------------
SNIPPET='declare -F do_spl_desk_doctree' in_orc >/dev/null 2>&1 &&
  pass "do_spl_desk_doctree exists" || fail "do_spl_desk_doctree is not defined"

# --- 2. list ------------------------------------------------------------------------------
run DOCTREE_ARGS=list
if [[ $rc -eq 0 && "$(argv)" == "doctree list" ]] &&
  grep -qxF "env|$D/spool|https://hub.invalid|t1|$D/keys|box-desk" "$T/calls" &&
  [[ "$(cat "$T/o")" == '{"docs":[{"id":"42","title":"Rebuild guide"}]}' ]] && no_leak; then
  pass "list runs the desk's spool with its root, hub, tenant and keys; prints only the verb's output"
else
  fail "list (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"
fi

# --- 3. a spool error naming the keys dir --------------------------------------------------
run DOCTREE_ARGS=list STUB_FAIL=1
[[ $rc -ne 0 ]] && grep -q '<desk>/keys/box.key: permission denied' "$T/o" && no_leak &&
  pass "a spool error reaches the output with the desk state masked" || fail "error leak (rc=$rc): $(cat "$T/o")"

# --- 4. seat, roster, verb ---------------------------------------------------------------
refused() { # <label> <grep> -> pass when rc!=0, no spool call, the FATAL shows, nothing leaks
  if [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "$2" "$T/o" && no_leak; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o")"; fi
}
run DOCTREE_ARGS=list DESK_AGENT=c-009
refused "an agent with no seat in the desk is refused" 'c-009 has no seat'
run DOCTREE_ARGS=list DESK_AGENT=c-002
refused "a seat dir missing from the hub roster is refused" 'not in the hub roster'
run DOCTREE_ARGS='hub-pin --box x'
refused "a verb outside the doctree list is refused" "'hub-pin' is not a doctree verb"

# --- 5. DOCTREE_IN and the file flags ------------------------------------------------------
run DOCTREE_ARGS='add 42 --kind para' DOCTREE_IN=/etc/hostname DRY_RUN=0
refused "DOCTREE_IN outside the worktree, /tmp and dispatch/ is refused" 'DOCTREE_IN must lie in'
ln -s "$D/keys/box.key" "$T/in/link"
run DOCTREE_ARGS='add 42 --kind para' DOCTREE_IN="$T/in/link" DRY_RUN=0
refused "a /tmp symlink into the desk state is refused" 'DOCTREE_IN lies in the desk state'
run DOCTREE_ARGS="add 42 --kind para --file $D/keys/box.key" DRY_RUN=0
refused "a --file naming anything but DOCTREE_IN is refused" 'may only name DOCTREE_IN'
run DOCTREE_ARGS="add 42 --kind picture --path=/etc/hostname" DOCTREE_IN="$T/in/body.md" DRY_RUN=0
refused "a --path= naming another file is refused" 'may only name DOCTREE_IN'
run DOCTREE_ARGS="export 42 --out $T/in/x.md"
refused "--out is refused" '\-\-out is refused'

# --- 6. DOCTREE_IN passed through ---------------------------------------------------------
run DOCTREE_ARGS='add 42 --kind para' DOCTREE_IN="$T/in/body.md" DRY_RUN=0
[[ $rc -eq 0 && "$(argv)" == "doctree add 42 --kind para --file $T/in/body.md" ]] &&
  pass "DOCTREE_IN goes in as --file" || fail "--file (rc=$rc): $(argv) / $(cat "$T/o")"
run DOCTREE_ARGS='add 42 --kind picture --caption "a b"' DOCTREE_IN="$T/in/body.md" DRY_RUN=0
[[ $rc -eq 0 && "$(argv)" == "doctree add 42 --kind picture --caption a b --path $T/in/body.md" ]] &&
  pass "DOCTREE_IN goes in as --path for a picture; quoted words stay one word" || fail "--path (rc=$rc): $(argv) / $(cat "$T/o")"
run DOCTREE_ARGS="edit 42 7 --field body --file $T/in/../in/body.md" DOCTREE_IN="$T/in/body.md" DRY_RUN=0
[[ $rc -eq 0 && "$(argv)" == "doctree edit 42 7 --field body --file $T/in/body.md" ]] &&
  pass "an explicit --file naming DOCTREE_IN is kept, not doubled" || fail "explicit --file (rc=$rc): $(argv) / $(cat "$T/o")"

# --- 7. DRY_RUN ---------------------------------------------------------------------------
dry_ok=1
for a in 'create --title X' 'add 42 --kind para --text t' 'edit 42 7 --field title --value v' \
  'move 42 7 --ord 1' 'delete 42' 'rename 42 --title Y' 'folder --name f'; do
  run DOCTREE_ARGS="$a"
  [[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'OK DRY_RUN nothing was written' "$T/o" || { dry_ok=0; fail "dry run '$a' (rc=$rc): $(cat "$T/o")"; }
done
(( dry_ok )) && pass "DRY_RUN=1 (default): the 7 writing verbs make no spool call"
run DOCTREE_ARGS='read 42'
[[ $rc -eq 0 && "$(argv)" == "doctree read 42" ]] &&
  pass "a read runs under the default DRY_RUN" || fail "read (rc=$rc): $(cat "$T/o")"

echo "desk-doctree: $fails failure(s)"
((fails == 0))
