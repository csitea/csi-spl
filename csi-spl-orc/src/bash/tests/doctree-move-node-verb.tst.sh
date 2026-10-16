#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_doctree passes `move-node` (spec 120 section 7: a
#          document or a folder moved under another folder) to the desk's
#          spool, as a writing verb. The binary is a stub recording its argv.
#   1. DRY_RUN=1 (the default): move-node makes no spool call
#   2. DRY_RUN=0: the stub runs as `doctree move-node <node> --parent <folder>`
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
echo '{"node":"n1","parent":"f1"}'
EOF_STUB
chmod +x "$T/state/dev/bin/spool"

# run [VAR=value]... - the action; stub calls in $T/calls, output in $T/o, rc in $rc
run() {
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
do_spl_desk_doctree' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=a-177 AGENT_ID=a-177 CALLS="$T/calls" "$@" >"$T/o" 2>&1
  rc=$?
}
argv() { sed -n 's/^argv|//p' "$T/calls"; }

# --- 1. dry run ---------------------------------------------------------------------------
run DOCTREE_ARGS='move-node n1 --parent f1'
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'OK DRY_RUN nothing was written' "$T/o" &&
  pass "DRY_RUN=1: move-node is a writing verb, no spool call" || fail "move-node dry run (rc=$rc): $(cat "$T/o")"

# --- 2. live ------------------------------------------------------------------------------
run DOCTREE_ARGS='move-node n1 --parent f1' DRY_RUN=0
[[ $rc -eq 0 && "$(argv)" == "doctree move-node n1 --parent f1" ]] &&
  pass "DRY_RUN=0: move-node reaches the desk spool" || fail "move-node (rc=$rc): $(argv) / $(cat "$T/o")"

echo "doctree-move-node-verb: $fails failure(s)"
((fails == 0))
