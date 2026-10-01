#!/usr/bin/env bash
# test-agent-user-default.sh — CLE-77907, 2026-10-01: agents run as the box's
# agent user with NO env, and the su-dash trust hop never feeds its script
# through a pty.
#
# 3 lanes sat at python's '>>>' for 11 min: trust-workdir piped its script into
# `sudo su --pty - <agent> -c "python3 - ..."`; with --pty, stdin is the pty,
# so python read the terminal, never the script, and claude never started.
#   1-4  box.env (box-config.sh) supplies SPOOL_AGENT_USER; the env wins
#   5-6  a dry-run spawn with no SPOOL_AGENT_USER plans the hop to that user
#   7-10 trust-workdir via su-dash and sudo-i (stub sudo, HOME sandboxed):
#        the entry is written, and the hop carried no --pty and no stdin
#   11-12 agent-user-check.sh flags a CLI running as the box user
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
ME="$(id -un)"
OTHER="$(getent passwd nobody >/dev/null && echo nobody || echo daemon)"

# 1-4 the box config
BC="$T_SCRIPTS/box-config.sh"
rc=0; bash "$BC" SPOOL_AGENT_USER=no-such-user-77907 >/dev/null 2>&1 || rc=$?
eq "1. box-config refuses an unknown user" 2 "$rc"
bash "$BC" SPOOL_AGENT_USER="$OTHER" >/dev/null
eq "2. box-config wrote box.env" "SPOOL_AGENT_USER=$OTHER" "$(cat "$SPOOL_ROOT/box.env")"
got="$(env -u SPOOL_AGENT_USER bash -c '. "$1/../lib/spool-env.inc.sh"; spool_env_resolve; echo "$SPOOL_AGENT_USER"' _ "$T_SCRIPTS")"
eq "3. unset SPOOL_AGENT_USER resolves from box.env" "$OTHER" "$got"
got="$(SPOOL_AGENT_USER="$ME" bash -c '. "$1/../lib/spool-env.inc.sh"; spool_env_resolve; echo "$SPOOL_AGENT_USER"' _ "$T_SCRIPTS")"
eq "4. the environment wins over box.env" "$ME" "$got"

# 5-6 a spawn dry run with no env names the agent user
WD="$T_TMP/wd"; mkdir -p "$WD"; echo brief >"$T_TMP/brief.md"
out="$(env -u SPOOL_AGENT_USER -u CLAUDE_BIN SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool bash "$T_SCRIPTS/spawn-claude.sh" CLE-77 "$WD" "$T_TMP/brief.md" x 2>&1)"
has "5. dry run hops to the box.env agent user" "su --pty - ${OTHER} (SPOOL_RUN_AS_AGENT=su-dash)" "$out"
has "6. dry run plans trust for the box.env agent user" "trust-workdir.sh --settle ${WD} ${OTHER} claude" "$out"
bash "$BC" SPOOL_AGENT_USER= >/dev/null
eq "6b. KEY= removes the key" "" "$(cat "$SPOOL_ROOT/box.env")"

# 7-10 the trust hop through a stub sudo: runs the command as THIS user with
# the sandbox HOME, and records the pty flag and whatever arrived on stdin.
STUB="$T_TMP/bin"; mkdir -p "$STUB"
cat >"$STUB/sudo" <<'SH'
#!/usr/bin/env bash
log="$STUB_LOG"; pty=no
[ "$1" = su ] && shift
[ "$1" = --pty ] && { pty=yes; shift; }
cmd="${@: -1}"
stdin="$(timeout 1 cat 2>/dev/null | head -c 64)"
printf 'argv=%s pty=%s stdin=[%s]\n' "$*" "$pty" "$stdin" >>"$log"
exec env HOME="$STUB_HOME" bash -c "$cmd" </dev/null
SH
chmod +x "$STUB/sudo"
for mode in su-dash sudo-i; do
  H="$T_TMP/home-$mode"; mkdir -p "$H" "$T_TMP/wt-$mode"; echo '{"projects": {}}' >"$H/.claude.json"
  : >"$T_TMP/log-$mode"
  # SPOOL_AGENT_PTY=1: as if called from a terminal, which is what put --pty on the hop
  echo 'print("SCRIPT-ON-STDIN")' | PATH="$STUB:$PATH" STUB_LOG="$T_TMP/log-$mode" STUB_HOME="$H" \
    SPOOL_AGENT_PTY=1 SPOOL_RUN_AS_AGENT=$mode TRUST_SETTLE_SECS=0.3 \
    timeout 20 bash "$T_SCRIPTS/trust-workdir.sh" --settle "$T_TMP/wt-$mode" "$OTHER" claude >"$T_TMP/out-$mode" 2>&1
  rc=$?
  trusted="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["projects"].get(sys.argv[2],{}).get("hasTrustDialogAccepted"))' "$H/.claude.json" "$T_TMP/wt-$mode")"
  eq "7. $mode: trust hop exits 0 and the entry is written" "0 True" "$rc $trusted"
  has "8. $mode: the hop verified it" "verified" "$(cat "$T_TMP/out-$mode")"
  hasnt "9. $mode: the hop took no --pty" "pty=yes" "$(cat "$T_TMP/log-$mode")"
  has "10. $mode: nothing was fed on stdin" "stdin=[]" "$(cat "$T_TMP/log-$mode")"
done
sleep 0.5

# 11-12 the check after a spawn (a CLI name of its own: real agents run here)
FAKE="$T_TMP/fakebin"; mkdir -p "$FAKE"; cp "$(command -v sleep)" "$FAKE/claude-t77907"
rc=0; env SPOOL_AGENT_USER="$OTHER" SPOOL_BOX_USER="$ME" bash "$T_SCRIPTS/agent-user-check.sh" claude-t77907 >/dev/null 2>&1 || rc=$?
eq "11. agent-user-check: clean box -> 0" 0 "$rc"
"$FAKE/claude-t77907" 30 & fp=$!
sleep 0.2
out="$(env SPOOL_AGENT_USER="$OTHER" SPOOL_BOX_USER="$ME" bash "$T_SCRIPTS/agent-user-check.sh" claude-t77907 2>/dev/null)"; rc=$?
kill "$fp" 2>/dev/null; wait "$fp" 2>/dev/null
eq "12. agent-user-check: a box-user claude -> 1, named" "1 $fp" "$rc $(printf '%s' "$out" | awk -v p="$fp" '$1==p{print $1}')"

t_done
