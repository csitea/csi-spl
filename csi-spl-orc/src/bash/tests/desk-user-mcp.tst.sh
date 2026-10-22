#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the spool MCP follows the desk user (spec 069 section 8.5, row B5).
#   1. the serve half exits 75 (so the agent CLI starts spool-mcp again) when
#      the desk dir it serves is renamed or replaced; RED CONTROL before the
#      row: it kept serving the old path. CONTROL: an untouched desk keeps
#      serving, and a normal end (stdin closed) still exits with the server's
#      own code
#   2. SPOOL_DESK_USER unset: the install writes the agent config exactly as
#      before (two lines, the box user), no state-root file, no sudo hop
#   3. SPOOL_DESK_USER set: the box half and its binary land in the desk
#      user's home (written as that user), state-root names the desk user's
#      cloud root (B1's spl_desk_state_root), the agent config names the desk
#      user for the hop and the box user for tmux, and seats are read from
#      the desk user's tree as that user; unset again removes state-root
#   4. the agent half with that config hops to the desk user, reads its tmux
#      window as the box user, and the server serves from state-root
# getent and sudo are stubs over sandbox users; sudo runs the command as the
# caller and logs "-u <user> <command>". Nothing outside $T is read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
SH="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spool-mcp.sh"
CNFLIB="$PROJ_ROOT/lib/bash/funcs/spl-cloud-cnf.func.sh"
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)"
SIDE="" HOLD="" SRV=""
trap 'kill $SIDE $HOLD $SRV 2>/dev/null; rm -rf "$T"' EXIT
unset SPOOL_DESK_BOX SPOOL_DESK_USER SPOOL_MCP_STATE_ROOT
export SPOOL_BOX_ENV="$T/box.env.none"

# A live fake sidecar (argv `spool hub-run`) and desk trees that point at it.
env -i PATH=/usr/bin:/bin SPOOL_ROOT="$T/x/spool" SPOOL_KEYS_DIR="$T/x/keys" SPOOL_BOX_ID=box-desk \
  SPOOL_HUB_URL=https://hub.example.net SPOOL_TENANT=t1 bash -c 'exec -a "spool hub-run" sleep 300' &
SIDE=$!
for _ in $(seq 50); do tr '\0' ' ' <"/proc/$SIDE/cmdline" 2>/dev/null | grep ' hub-run' >/dev/null && break; sleep 0.1; done
desk_tree() {  # <cloud root>: <root>/dev/desk/t1/box-desk with seat c-007
  local d="$1/dev/desk/t1/box-desk"
  mkdir -p "$d/spool/c-007/inbox" "$d/spool/.hub" "$d/keys"
  echo "$SIDE" >"$d/spool/.hub/hub-run.pid"
}
# fake spool: records its pid and argv, reads stdin to EOF (a server waiting
# for requests), then exits 3
fake_spool() {  # <path>
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "\$\$" >"$T/served.pid"; printf 'ARGV %s\n' "\$*" >"$T/served"
cat >/dev/null
exit 3
EOF
  chmod +x "$1"
}
MCP="$T/box/mcp"; mkdir -p "$MCP"; desk_tree "$T/box/cloud"
cp "$SH" "$MCP/spool-mcp.sh"; chmod +x "$MCP/spool-mcp.sh"; fake_spool "$MCP/spool"

# ── 1. a renamed desk ends the server ───────────────────────────────────────
mkfifo "$T/in"
serve_bg() {  # start the box half on a held-open fifo; sets SRV and HOLD
  rm -f "$T/served" "$T/served.pid"
  sleep 300 >"$T/in" & HOLD=$!
  SPOOL_MCP_WATCH_S=1 "$MCP/spool-mcp.sh" --serve --as c-007 dev <"$T/in" >"$T/out" 2>&1 & SRV=$!
  for _ in $(seq 50); do [ -s "$T/served.pid" ] && break; sleep 0.1; done
}
ends_within() {  # <pid> <seconds>: 0 when the pid is gone within the time
  local _; for _ in $(seq $(($2 * 10))); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1
}
stop_hold() { kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; HOLD=""; }
D1="$T/box/cloud/dev/desk/t1/box-desk"
serve_bg
[ -s "$T/served" ] && pass "1. the box half serves c-007" || fail "1. not served: $(cat "$T/out")"
sleep 2.5
kill -0 "$SRV" 2>/dev/null && pass "1. CONTROL: an untouched desk keeps serving (2.5 s, watch 1 s)" || fail "1. CONTROL: ended on its own: $(cat "$T/out")"
spid="$(cat "$T/served.pid" 2>/dev/null)"
mv "$D1" "$D1.moved-test"
if ends_within "$SRV" 6; then
  wait "$SRV"; rc=$?
  [[ $rc -eq 75 ]] && grep -q 'moved away' "$T/out" && pass "1. RED CONTROL: a renamed desk ends the server with 75" ||
    fail "1. renamed desk: rc $rc $(cat "$T/out")"
  ends_within "$spid" 2 && pass "1. the spool server itself is stopped" || fail "1. spool server $spid still runs"
else
  fail "1. RED CONTROL: the server kept serving the renamed desk's old path"; kill "$SRV" "$spid" 2>/dev/null
fi
SRV=""; stop_hold
mv "$D1.moved-test" "$D1"
# a desk replaced by a copy (same path, a new dir) is a move too
serve_bg
mv "$D1" "$D1.old"; cp -a "$D1.old" "$D1"
if ends_within "$SRV" 6; then wait "$SRV"; rc=$?; else rc=none; kill "$SRV" 2>/dev/null; fi
[[ "$rc" == 75 ]] && pass "1. a desk replaced by a copy at the same path ends it too (75)" || fail "1. replaced desk: rc $rc $(cat "$T/out")"
SRV=""; stop_hold; rm -rf "$D1.old"
# a normal end: the CLI closes stdin, the server's own code comes back
serve_bg
stop_hold
if ends_within "$SRV" 6; then wait "$SRV"; rc=$?; else rc=none; kill "$SRV" 2>/dev/null; fi
[[ "$rc" == 3 ]] && ! grep -q 'moved away' "$T/out" && pass "1. CONTROL: stdin closed -> the server's own exit code (3), no move" || fail "1. normal end: rc $rc $(cat "$T/out")"
SRV=""

# ── stubs for 2-4 ───────────────────────────────────────────────────────────
DU=t-desk-user DH="$T/home-desk" AH="$T/home-agent" BH="$T/home-box"
mkdir -p "$T/stub" "$DH" "$AH/.local/bin" "$BH"
cat >"$T/stub/getent" <<EOF
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $DU) echo "$DU:x:5002:5002::$DH:/bin/sh" ;;
  $ME) echo "$ME:x:$(id -u):$(id -g)::$AH:/bin/sh" ;;
  *) exit 2 ;;
esac
EOF
cat >"$T/stub/sudo" <<EOF
#!/usr/bin/env bash
u=""
while [ "\$#" -gt 0 ]; do
  case "\$1" in -n|-H) shift ;; -u) u="\$2"; shift 2 ;; --) shift; break ;; *) break ;; esac
done
echo "-u \$u \$(basename "\$1") \${4:-}" >>"$T/sudo.log"
[ "\$(basename "\$1")" = tmux ] && { echo "c-007 lane"; exit 0; }
exec "\$@"
EOF
cat >"$T/build.sh" <<'EOF'
#!/usr/bin/env bash
printf '#!/bin/sh\n[ "$1 $2" = "mcp --as" ] && exit 1\nexit 0\n' >"$1"; chmod +x "$1"; echo "built $1"
EOF
cat >"$AH/.local/bin/claude" <<EOF_CL
#!/usr/bin/env bash
# fake claude: mcp add|remove -s <user|local> <name> [-- <cmd> <args...>] on ~/.claude.json
op="\$2" scope="\$4" name="\$5"; shift 5; [ "\$op" = add ] && shift
python3 - "$AH/.claude.json" "\$op" "\$scope" "\$name" "\$@" <<'PY'
import json, os, sys
p, op, scope, name, *rest = sys.argv[1:]
d = json.load(open(p)) if os.path.exists(p) else {}
s = d.setdefault("projects", {}).setdefault(os.getcwd(), {}).setdefault("mcpServers", {}) if scope == "local" else d.setdefault("mcpServers", {})
if op == "add":
    s[name] = {"command": rest[0], "args": rest[1:]}
else:
    s.pop(name, None)
json.dump(d, open(p, "w"))
PY
EOF_CL
chmod +x "$T/stub/getent" "$T/stub/sudo" "$T/build.sh" "$AH/.local/bin/claude"
printf 'SPOOL_DESK_USER=%s\n' "$DU" >"$T/box.env.desk"
in_orc() {
  env PATH="$T/stub:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$BH" SPL_AGENT_MCP_BUILD="$T/build.sh" \
    AGENT_USER="$ME" MCP_CLIS=claude MCP_ENVS=prd MCP_SEAT_ENVS= DRY_RUN=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_agent_mcp_install' >"$T/out" 2>&1
}
CONF="$AH/.config/spool-mcp/env"
BM="$BH/.local/share/$OA/mcp" DM="$DH/.local/share/$OA/mcp" DS="$DH/.local/share/$OA/cloud"

# ── 2. unset: the install as before ─────────────────────────────────────────
: >"$T/sudo.log"
in_orc; rc=$?
want="$(printf 'SPOOL_MCP_BOX_USER=%s\nSPOOL_MCP_SERVE=%s' "$ME" "$BM/spool-mcp.sh")"
[[ $rc -eq 0 && "$(cat "$CONF" 2>/dev/null)" == "$want" ]] && pass "2. unset: the agent config is the two lines of before (box user, box half)" ||
  fail "2. unset conf: rc $rc '$(cat "$CONF" 2>/dev/null)' $(cat "$T/out")"
[[ -x "$BM/spool-mcp.sh" && -x "$BM/spool" && ! -e "$BM/state-root" && ! -e "$DM" ]] &&
  pass "2. unset: the box half in the box user's home, no state-root, nothing in the desk user's" || fail "2. unset box half: $(ls -la "$BM" "$DM" 2>&1)"
[[ ! -s "$T/sudo.log" ]] && pass "2. unset: no sudo hop (agent user = caller)" || fail "2. unset sudo: $(cat "$T/sudo.log")"
got="$(PATH="$T/stub:$PATH" bash -c 'do_log() { :; }; . "$1"; spl_desk_user' _ "$CNFLIB")"
[[ -z "$got" ]] && pass "2. CONTROL: with no key the resolver names no desk user" || fail "2. resolver: '$got'"

# ── 3. set: the box half follows the desk user ──────────────────────────────
: >"$T/sudo.log"; desk_tree "$DS"
printf 'claude c-007 %s\n' "$T" >"$T/live"
in_orc SPOOL_BOX_ENV="$T/box.env.desk" MCP_ENVS=dev MCP_SEAT_ENVS=dev SPOOL_DESK_BOX=box-desk SPL_AGENT_MCP_LIVE="$T/live"; rc=$?
[[ $rc -eq 0 && -x "$DM/spool-mcp.sh" && -x "$DM/spool" ]] && cmp -s "$SH" "$DM/spool-mcp.sh" &&
  pass "3. set: the box half and its binary are in the desk user's home" || fail "3. set box half: rc $rc $(ls -la "$DM" 2>&1) $(cat "$T/out")"
[[ "$(cat "$DM/state-root" 2>/dev/null)" == "$DS" ]] && pass "3. set: state-root = the desk user's cloud root" || fail "3. state-root: '$(cat "$DM/state-root" 2>&1)'"
grep -q "^-u $DU bash box-side" "$T/sudo.log" && pass "3. set: the box half is written as the desk user" || fail "3. set sudo: $(cat "$T/sudo.log")"
want="$(printf 'SPOOL_MCP_BOX_USER=%s\nSPOOL_MCP_SERVE=%s\nSPOOL_MCP_TMUX_USER=%s' "$DU" "$DM/spool-mcp.sh" "$ME")"
[[ "$(cat "$CONF")" == "$want" ]] && pass "3. set: the config hops to the desk user, tmux stays the box user's" || fail "3. set conf: '$(cat "$CONF")'"
grep -q 'spool-dev: 1 live claude agent(s) of .* seated in dev on box-desk, 0 not' "$T/out" && grep -q "^-u $DU bash seats" "$T/sudo.log" &&
  pass "3. set: the seat lookup reads the desk user's tree as the desk user" || fail "3. seats: $(grep spool-dev "$T/out") $(cat "$T/sudo.log")"
in_orc SPL_AGENT_MCP_DIR="$DM"; rc=$?
[[ $rc -eq 0 && ! -e "$DM/state-root" ]] && pass "3. unset again (a rollback re-install): state-root removed" || fail "3. rollback: rc $rc $(ls "$DM")"
in_orc SPOOL_BOX_ENV="$T/box.env.desk" || fail "3. re-install set: $(cat "$T/out")"

# ── 4. the agent half hops to the desk user, serves from state-root ─────────
: >"$T/sudo.log"; rm -f "$T/served"
fake_spool "$DM/spool"
env -u MCP_BOT_AGENT_ID -u SPOOL_AGENT_ID PATH="$T/stub:$PATH" TMUX_PANE=%1 SPOOL_MCP_CONF="$CONF" \
  "$SH" dev >"$T/out" 2>&1 </dev/null; rc=$?
[[ $rc -eq 3 ]] && grep -qx "ARGV mcp --as c-007 --desks $DS/dev/desk --desk-box box-desk --seat-cmd $DM/spool-mcp.sh --seat dev box-desk" "$T/served" &&
  pass "4. the agent half serves c-007 from the desk user's tree" || fail "4. agent half: rc $rc $(cat "$T/out") $(cat "$T/served" 2>&1)"
[[ "$(cut -d' ' -f1-3 "$T/sudo.log")" == "$(printf -- '-u %s tmux\n-u %s spool-mcp.sh' "$ME" "$DU")" ]] &&
  pass "4. tmux is read as the box user, the server runs as the desk user" || fail "4. hops: $(cat "$T/sudo.log")"

[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
