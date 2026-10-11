#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_wsdoc runs one `spool doc-*` verb (the WORKSPACE docs,
#          spec 075) for a desk agent through the desk's installed spool
#          binary, so a lane never sees the desk state or a key path (data
#          rule). The binary is a stub that records its argv and env and, like
#          a real error, names its keys dir. Tenant and doc are synthetic.
#   1. the action exists
#   2. list: the stub runs as `doc-list <prefix>` with SPOOL_ROOT /
#      SPOOL_HUB_URL / SPOOL_TENANT / SPOOL_KEYS_DIR of the desk; only its
#      output is printed; read runs as `doc-read <path>`
#   3. a spool error that names the keys dir reaches the output masked
#   4. refused, no spool call: an agent with no seat, an agent missing from
#      the hub roster, an unknown verb, rename (no history-keeping rename on
#      the hub), a flag, a path that is not a relative .md path
#   5. refused, no spool call: write without WSDOC_IN, WSDOC_IN outside the
#      allowed dirs, a /tmp symlink into the desk state, WSDOC_IN on a read
#   6. write: DRY_RUN=1 (the default) makes no spool call; DRY_RUN=0 runs
#      `doc-write <path> --file <WSDOC_IN>`
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
echo '{"files":[{"path":"ws/agents/howto.md","updated":"2026-01-01T00:00:00Z"}]}'
EOF_STUB
chmod +x "$T/state/dev/bin/spool"
echo "a body" >"$T/in/body.md"

# run [VAR=value]... - the action; stub calls in $T/calls, output in $T/o, rc in $rc
run() {
  : >"$T/calls"
  SNIPPET='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
do_spl_desk_wsdoc' in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=a-177 CALLS="$T/calls" "$@" >"$T/o" 2>&1
  rc=$?
}
argv() { sed -n 's/^argv|//p' "$T/calls"; }
no_leak() { ! grep -qF "$T" "$T/o" && ! grep -q secret-key "$T/o"; }

# --- 1. the action exists ------------------------------------------------------------------
SNIPPET='declare -F do_spl_desk_wsdoc' in_orc >/dev/null 2>&1 &&
  pass "do_spl_desk_wsdoc exists" || fail "do_spl_desk_wsdoc is not defined"

# --- 2. list, read ------------------------------------------------------------------------
run WSDOC_ARGS='list ws/agents/'
if [[ $rc -eq 0 && "$(argv)" == "doc-list ws/agents/" ]] &&
  grep -qxF "env|$D/spool|https://hub.invalid|t1|$D/keys|box-desk" "$T/calls" &&
  [[ "$(cat "$T/o")" == '{"files":[{"path":"ws/agents/howto.md","updated":"2026-01-01T00:00:00Z"}]}' ]] && no_leak; then
  pass "list runs the desk's spool with its root, hub, tenant and keys; prints only the verb's output"
else
  fail "list (rc=$rc): $(cat "$T/o") / $(cat "$T/calls")"
fi
run WSDOC_ARGS=list
[[ $rc -eq 0 && "$(argv)" == "doc-list" ]] && pass "list with no prefix" || fail "bare list (rc=$rc): $(argv) / $(cat "$T/o")"
run WSDOC_ARGS='read ws/agents/howto.md'
[[ $rc -eq 0 && "$(argv)" == "doc-read ws/agents/howto.md" ]] &&
  pass "read runs as it is (no DRY_RUN)" || fail "read (rc=$rc): $(argv) / $(cat "$T/o")"

# --- 3. a spool error naming the keys dir --------------------------------------------------
run WSDOC_ARGS=list STUB_FAIL=1
[[ $rc -ne 0 ]] && grep -q '<desk>/keys/box.key: permission denied' "$T/o" && no_leak &&
  pass "a spool error reaches the output with the desk state masked" || fail "error leak (rc=$rc): $(cat "$T/o")"

# --- 4. seat, roster, verb, flags, paths ---------------------------------------------------
refused() { # <label> <grep> -> pass when rc!=0, no spool call, the FATAL shows, nothing leaks
  if [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q -- "$2" "$T/o" && no_leak; then pass "$1"; else fail "$1 (rc=$rc): $(cat "$T/o")"; fi
}
run WSDOC_ARGS=list DESK_AGENT=c-009
refused "an agent with no seat in the desk is refused" 'c-009 has no seat'
run WSDOC_ARGS=list DESK_AGENT=c-002
refused "a seat dir missing from the hub roster is refused" 'not in the hub roster'
run WSDOC_ARGS='delete ws/agents/howto.md' DRY_RUN=0
refused "an unknown verb is refused" "'delete' is not a wsdoc verb"
run WSDOC_ARGS='rename ws/agents/howto.md ws/agents/howto.en.md' DRY_RUN=0
refused "rename is refused: no history-keeping rename on the hub" 'rename is refused'
run WSDOC_ARGS="write ws/agents/howto.md --file $D/keys/box.key" DRY_RUN=0
refused "a flag in WSDOC_ARGS is refused" 'takes no flag'
run WSDOC_ARGS='read ../keys/box.key'
refused "a path that is not a relative .md path is refused" 'is not a workspace doc path'
run WSDOC_ARGS='read /etc/hostname.md'
refused "an absolute path is refused" 'is not a workspace doc path'
run WSDOC_ARGS='list ../'
refused "a list prefix with .. is refused" 'is not a relative doc prefix'
run WSDOC_ARGS='read a.md b.md'
refused "read takes one path" 'usage:'

# --- 5. WSDOC_IN ---------------------------------------------------------------------------
run WSDOC_ARGS='write ws/agents/howto.md' DRY_RUN=0
refused "write without WSDOC_IN is refused" 'write needs WSDOC_IN'
run WSDOC_ARGS='write ws/agents/howto.md' WSDOC_IN=/etc/hostname DRY_RUN=0
refused "WSDOC_IN outside the worktree, /tmp and dispatch/ is refused" 'WSDOC_IN must lie in'
ln -s "$D/keys/box.key" "$T/in/link"
run WSDOC_ARGS='write ws/agents/howto.md' WSDOC_IN="$T/in/link" DRY_RUN=0
refused "a /tmp symlink into the desk state is refused" 'WSDOC_IN lies in the desk state'
run WSDOC_ARGS='read ws/agents/howto.md' WSDOC_IN="$T/in/body.md"
refused "WSDOC_IN on a read is refused" 'WSDOC_IN is for write only'

# --- 6. write: dry run by default, DRY_RUN=0 runs ------------------------------------------
run WSDOC_ARGS='write ws/agents/howto.bg.md' WSDOC_IN="$T/in/body.md"
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'OK DRY_RUN nothing was written' "$T/o" && no_leak &&
  pass "write under the default DRY_RUN makes no spool call" || fail "dry write (rc=$rc): $(cat "$T/o")"
run WSDOC_ARGS='write ws/agents/howto.bg.md' WSDOC_IN="$T/in/body.md" DRY_RUN=0
[[ $rc -eq 0 && "$(argv)" == "doc-write ws/agents/howto.bg.md --file $T/in/body.md" ]] &&
  pass "write with DRY_RUN=0 runs doc-write --file WSDOC_IN" || fail "write (rc=$rc): $(argv) / $(cat "$T/o")"

echo "desk-wsdoc: $fails failure(s)"
((fails == 0))
