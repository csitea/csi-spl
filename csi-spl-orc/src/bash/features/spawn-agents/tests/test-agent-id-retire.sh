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

# --- the write side: alias row + desk seats (owner 2026-10-05, t1 dc6d5e3f) -----
# A desk announces every agent dir of its spool root; the retired id must
# leave it, and the alias table must say where the id went.
export SPOOL_DESK_BOX=tb DESK_STATE_ROOT="$T_TMP/desks"
DK="$DESK_STATE_ROOT/prd/desk/csi-rel/tb/spool"; DO="$DESK_STATE_ROOT/prd/desk/csi-rel/box-rsp/spool"
mkdir -p "$DK"/{AGY-3499,CLE-002,c-002,c-031,GRK-3526@tb}/inbox "$DO"/c-031/inbox "$DESK_STATE_ROOT/dev/desk/t1/tb/spool/c-031/inbox"
ln -s c-002 "$DK/CLE-003"
printf '{"v":1}\n' >"$DK/c-031/inbox/m.json"
TB="$R/agent-id-aliases.tsv"

bash "$RET" --apply --successor c-040 c-031 >/dev/null 2>&1; eq "--successor on a new-grammar id is refused (2)" 2 "$?"
bash "$RET" --apply --successor CLE-9 AGY-3499 >/dev/null 2>&1; eq "--successor must be a new id (2)" 2 "$?"

out="$(bash "$RET" --successor c-030 AGY-3499 2>&1)"; eq "a legacy id held only by a desk seat plans (0, was 4)" 0 "$?"
has "...it plans the alias row" "PLAN alias     AGY-3499 -> c-030 (tb)" "$out"
has "...and the desk drop" "PLAN drop      prd/csi-rel/tb AGY-3499" "$out"
check "...the dry run drops nothing" test -d "$DK/AGY-3499/inbox"
bash "$RET" --apply --successor c-030 AGY-3499 >"$T_TMP/o" 2>&1; eq "retire of a seated legacy id exits 0" 0 "$?"
check "the AGY-3499 seat left the desk (kept under .retired)" test ! -e "$DK/AGY-3499" -a -d "$(ls -d "$DK"/.retired/AGY-3499.* 2>/dev/null | sed -n 1p)/inbox"
eq "the alias row maps it to its successor" "AGY-3499	c-030	agy	tb	2026-10-02T12:00:00Z" "$(grep '^AGY-3499' "$TB")"
eq "the spool-env resolver reads that row" c-030 "$(SPOOL_ROOT="$R" bash -c ". '$T_SCRIPTS/../lib/spool-env.inc.sh'; spl_agent_id_resolve AGY-3499@tb")"

mkdir -p "$R/c-031/inbox"
bash "$RET" --apply c-031 >"$T_TMP/o" 2>&1; eq "retire of a seated new id exits 0" 0 "$?"
eq "with no successor the row says retired" "c-031	retired	claude	tb	2026-10-02T12:00:00Z" "$(grep '^c-031' "$TB")"
check "its seat on this box's desk is gone, its mail kept" test ! -e "$DK/c-031" -a -s "$(ls -d "$DK"/.retired/c-031.* | sed -n 1p)/inbox/m.json"
check "...and on the dev desk too" test ! -e "$DESK_STATE_ROOT/dev/desk/t1/tb/spool/c-031"
check "CONTROL: another box's seat of the same number stays" test -d "$DO/c-031/inbox"
check "CONTROL: the other seats stay" test -d "$DK/c-002/inbox" -a -d "$DK/CLE-002/inbox"
eq "a retired row maps nothing for the resolver" c-031 "$(SPOOL_ROOT="$R" bash -c ". '$T_SCRIPTS/../lib/spool-env.inc.sh'; spl_agent_id_resolve c-031")"

printf 'GRK-77\tg-010\tgrok\ttb\t2026-10-02T00:00:00Z\n' >>"$TB"
mkdir -p "$R/GRK-77/inbox"
bash "$RET" --apply GRK-77 >"$T_TMP/o" 2>&1
has "a legacy id the map already aliased keeps its row" "DO alias     GRK-77@tb keeps its row" "$(cat "$T_TMP/o")"
eq "...and no second row is written" 1 "$(grep -c '^GRK-77' "$TB")"

mkdir -p "$R/c-032/inbox"; printf 'c-032\tclaude\t%%9\t/z\t20261002T080000Z\n' >>"$R/registry.tsv"
DESK_STATE_ROOT='' bash "$RET" --apply c-032 >"$T_TMP/o" 2>&1
hasnt "CONTROL: under SPOOL_TEST with no DESK_STATE_ROOT no desk is read" "drop" "$(cat "$T_TMP/o")"

# --- desk-seat-drop.sh --legacy: what do_spl_desk_legacy_drop runs --------------
DROP="$T_SCRIPTS/desk-seat-drop.sh"
out="$(bash "$DROP" --legacy 2>&1)"; eq "the legacy listing exits 0" 0 "$?"
has "it lists the legacy seats per desk (a link is not a seat)" "SEATED prd/csi-rel/tb CLE-002 GRK-3526@tb" "$out"
has "a desk with none says -" "SEATED prd/csi-rel/box-rsp -" "$out"
check "the dry run drops nothing" test -d "$DK/CLE-002/inbox" -a -d "$DK/GRK-3526@tb/inbox"
bash "$DROP" --legacy --box box-rsp --apply >/dev/null 2>&1
check "--box limits it to that box's desks" test -d "$DK/CLE-002/inbox"
bash "$DROP" --legacy --apply >"$T_TMP/o" 2>&1; eq "--apply exits 0" 0 "$?"
has "it reports the drops" "desk-seat-drop: 2 seat(s) on 3 desk(s) dropped" "$(cat "$T_TMP/o")"
check "the legacy seats are gone" test ! -e "$DK/CLE-002" -a ! -e "$DK/GRK-3526@tb"
check "CONTROL: new ids and links stay" test -d "$DK/c-002/inbox" -a -L "$DK/CLE-003"
has "a second run finds none" "SEATED prd/csi-rel/tb -" "$(bash "$DROP" --legacy 2>&1)"
bash "$DROP" --legacy c-002 >/dev/null 2>&1; eq "--legacy and ids together are refused (2)" 2 "$?"
unset SPOOL_DESK_BOX DESK_STATE_ROOT

t_done
