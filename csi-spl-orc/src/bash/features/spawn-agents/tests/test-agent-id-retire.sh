#!/usr/bin/env bash
# agent-id-retire.sh (specs/061 §3.6) and its /exit-clean hook
# (tmux-close-window.sh --retire): the spool dir, the registry rows and the
# identity record move aside, the number stays quarantined for the allocator,
# then comes back. A private tmux server; the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
RET="$T_SCRIPTS/agent-id-retire.sh"
NAI="$T_SCRIPTS/next-agent-id.sh"
CLOSE="$T_SCRIPTS/tmux-close-window.sh"
unset CLE_TMUX_PANE GRK_TMUX_PANE AGY_TMUX_PANE QWN_TMUX_PANE
export CLOSE_LOG_DIR="$T_TMP/logs" SPOOL_NOW=2026-10-02T12:00:00Z; mkdir -p "$CLOSE_LOG_DIR"
R="$SPOOL_ROOT"
t_tmux

# A spawned agent: claimed dir with unread mail, a registry row, a record.
id="$(bash "$NAI" --kind claude)"
eq "the fixture agent is c-004" c-004 "$id"
printf '{"v":1}\n' >"$R/c-004/inbox/unread.json"
printf 'c-004\tclaude\t%%5\t/x\t20261002T080000Z\nc-099\tclaude\t%%6\t/y\t20261002T080000Z\n' >"$R/registry.tsv"
mkdir -p "$R/agents"; printf '{"id":"c-004"}\n' >"$R/agents/c-004.json"
printf '{"v":1,"hash":"%s","records":1}\n' "$(python3 "$T_SCRIPTS/agent-identity.py" --dir "$R/agents" hash)" >"$R/agents/index.json"

# --- refusals -----------------------------------------------------------------
bash "$RET" --apply c-001 >/dev/null 2>&1;   eq "a role id is refused (2)" 2 "$?"
bash "$RET" --apply CLE-002 >/dev/null 2>&1; eq "a legacy role id is refused (2)" 2 "$?"
bash "$RET" --apply HUM-17 >/dev/null 2>&1;  eq "a non-agent id is refused (2)" 2 "$?"
bash "$RET" --apply c-777 >/dev/null 2>&1;   eq "an id nothing holds is exit 4" 4 "$?"
P="$(t_window 'tg: c-004 busy' 'sleep 600')"
bash "$RET" --apply c-004 >/dev/null 2>&1;   eq "an id a window still carries is refused (3)" 3 "$?"
check "...and nothing moved" test -d "$R/c-004/inbox"
tmux -S "$SPOOL_TMUX_SOCKET" kill-window -t "$P"

# --- dry run ------------------------------------------------------------------
out="$(bash "$RET" c-004 2>&1)"; eq "the dry run exits 0" 0 "$?"
has "it plans the dir move" "PLAN move      $R/c-004 -> $R/.retired/c-004.20261002T080000Z" "$out"
has "it plans the registry" "PLAN registry  1 row(s)" "$out"
has "it plans the record" "PLAN identity" "$out"
check "the dry run moves nothing" test -d "$R/c-004/inbox" -a -e "$R/agents/c-004.json"

# --- apply --------------------------------------------------------------------
h0="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hash"])' "$R/agents/index.json" 2>/dev/null)"
bash "$RET" --apply c-004 >"$T_TMP/o" 2>&1; eq "retire exits 0" 0 "$?"
check "the spool dir is gone" test ! -e "$R/c-004"
check "it moved whole, unread mail kept aside" test -s "$R/.retired/c-004.20261002T080000Z/inbox/unread.json"
eq "the registry keeps the other agent only" "c-099" "$(cut -f1 "$R/registry.tsv")"
eq "registry.retired.tsv has the row + retired-utc" "c-004	claude	%5	/x	20261002T080000Z	20261002T120000Z" "$(cat "$R/registry.retired.tsv")"
check "the record moved to agents/retired/" test -s "$R/agents/retired/c-004.20261002T080000Z.json" -a ! -e "$R/agents/c-004.json"
h1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hash"])' "$R/agents/index.json")"
eq "index.json is re-hashed to the records on disk" "$(python3 "$T_SCRIPTS/agent-identity.py" --dir "$R/agents" hash)" "$h1"
[ -n "$h0" ] && [ "$h0" != "$h1" ] && ok "...and the hash changed" || nok "...and the hash changed ($h0 -> $h1)"

# --- the allocator: quarantined, then free -------------------------------------
printf '003\n' >"$R/agent-id.cursor"
eq "inside the 24 h quarantine 004 is skipped" c-005 "$(bash "$NAI" --kind claude --no-reserve)"
eq "after it, 004 comes back" c-004 "$(SPOOL_NOW=2026-10-03T12:00:01Z bash "$NAI" --kind claude --no-reserve)"

# --- a second generation does not overwrite the first ----------------------------
mkdir -p "$R/c-004/inbox"; printf 'c-004\tclaude\t%%7\t/z\t20261002T080000Z\n' >>"$R/registry.tsv"
bash "$RET" --apply c-004 >/dev/null 2>&1
check "same generation stamp -> a .2 dir, the first kept" test -d "$R/.retired/c-004.20261002T080000Z.2" -a -s "$R/.retired/c-004.20261002T080000Z/inbox/unread.json"

# --- qualified layout + no registry row ------------------------------------------
mkdir -p "$R/g-010@sat/inbox"; ln -s g-010@sat "$R/g-010"
bash "$RET" --apply g-010 >/dev/null 2>&1; eq "a qualified id retires" 0 "$?"
check "the <ID>@<box> dir moved and the link is gone" test ! -e "$R/g-010@sat" -a ! -L "$R/g-010" -a -d "$(ls -d "$R"/.retired/g-010.* | sed -n 1p)/inbox"
has "with no registry row one is synthesized (quarantine holds)" "g-010	grok" "$(cat "$R/registry.retired.tsv")"

# --- the /exit-clean hook: tmux-close-window.sh --agent ID --defer --retire --------
export SPOOL_BOX_TAG=tg
mkdir -p "$R/q-020/inbox"
P2="$(t_window 'tg: q-020 done' 'sleep 600')"
bash "$CLOSE" --agent q-020 --defer --retire --timeout 10 >"$T_TMP/o" 2>&1; eq "--defer --retire returns 0 at once" 0 "$?"
for _ in $(seq 1 30); do [ -e "$R/q-020" ] || break; sleep 0.5; done
check "the window closed" bash -c "! tmux -S '$SPOOL_TMUX_SOCKET' list-panes -a -F '#{pane_id}' | grep -qx '$P2'"
check "then the id was retired" test ! -e "$R/q-020" -a -n "$(ls -d "$R"/.retired/q-020.* 2>/dev/null)"
has "the close log records the retire" "agent-id-retire: q-020 retired" "$(cat "$CLOSE_LOG_DIR"/kill-your-self-close-*.log)"
mkdir -p "$R/q-021/inbox"
P3="$(t_window 'tg: q-021 done' 'sleep 600')"
bash "$CLOSE" --agent q-021 --defer --timeout 10 >/dev/null 2>&1
for _ in $(seq 1 30); do tmux -S "$SPOOL_TMUX_SOCKET" list-panes -a -F '#{pane_id}' | grep -x "$P3" >/dev/null || break; sleep 0.5; done
sleep 1
check "CONTROL: without --retire the id stays held" test -d "$R/q-021/inbox"

t_done
