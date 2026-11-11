#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_doctree passes `folder-delete` (SPL-5256: an empty
#          folder deleted, the hub's 409 for a non-empty one) to the desk's
#          spool, as a writing verb. The binary is a stub recording its argv.
#   1. DRY_RUN=1 (the default): folder-delete makes only the parse-only
#      `doctree --check` call (SPL-2545), no write
#   2. DRY_RUN=0: the stub runs as `doctree folder-delete <folder>`
#   3. DRY_RUN=0 under another agent's seat: refused, no spool call (SPL-2078)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

trap 'rm -rf "$T"' EXIT
orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
D="$T/state/dev/desk/t1/box-desk"
mkdir -p "$D/spool/a-177" "$D/spool/.hub" "$D/keys" "$T/state/dev/bin"
echo '{"box-desk":["a-177"]}' >"$D/spool/.hub/roster.json"
cat >"$T/state/dev/bin/spool" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'argv|%s\n' "$*" >>"$CALLS"
echo '{"id":"f1","deleted":true,"folders":1,"documents":0}'
EOF_STUB
chmod +x "$T/state/dev/bin/spool"

# run [VAR=value]... - the action; stub calls in $T/calls, output in $T/o, rc in $rc
run() {
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
do_spl_desk_doctree' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=a-177 CALLS="$T/calls" "$@" >"$T/o" 2>&1
  rc=$?
}
argv() { sed -n 's/^argv|//p' "$T/calls"; }

# --- 1. dry run ---------------------------------------------------------------------------
run AGENT_ID=a-177 DOCTREE_ARGS='folder-delete f1'
[[ $rc -eq 0 && "$(argv)" == "doctree --check folder-delete f1" ]] && grep -q 'OK DRY_RUN nothing was written' "$T/o" &&
  pass "DRY_RUN=1: folder-delete is a writing verb, only the --check call" || fail "folder-delete dry run (rc=$rc): $(cat "$T/o")"

# --- 2. live ------------------------------------------------------------------------------
run AGENT_ID=a-177 DOCTREE_ARGS='folder-delete f1' DRY_RUN=0
[[ $rc -eq 0 && "$(argv)" == "doctree folder-delete f1" ]] && grep -q '"deleted":true' "$T/o" &&
  pass "DRY_RUN=0: folder-delete reaches the desk spool" || fail "folder-delete (rc=$rc): $(argv) / $(cat "$T/o")"

# --- 3. another agent's seat ---------------------------------------------------------------
run AGENT_ID=c-999 DOCTREE_ARGS='folder-delete f1' DRY_RUN=0
[[ $rc -ne 0 && -z "$(argv)" ]] &&
  pass "DRY_RUN=0 by another agent: refused, no spool call" || fail "folder-delete by c-999 (rc=$rc): $(argv) / $(cat "$T/o")"

echo "doctree-folder-delete-verb: $fails failure(s)"
((fails == 0))
