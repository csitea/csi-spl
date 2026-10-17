#!/usr/bin/env bash
# agent-id-reap.sh over a CORRUPT registry.tsv (robustness review gap 3,
# SPL-2353): garbled before the reaper starts, and truncated or garbled WHILE
# it retires an id (a flock shim fires inside agent-id-retire.sh's registry
# lock, between its read of the rows and its rewrite). Safe outcome: exit 0,
# only the dead id is reaped and it is quarantined, no live or young id is
# retired, no id is lost to the allocator or handed out twice, and the next
# tick runs clean. A private tmux server; the live box is never touched.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
REAP="$T_SCRIPTS/agent-id-reap.sh"
NAI="$T_SCRIPTS/next-agent-id.sh"
export RETIRE_LANE=0 SPOOL_ID_REAP_H=6
unset DRY_RUN
R="$SPOOL_ROOT"
t_tmux
REAL_FLOCK="$(command -v flock)"
mkdir -p "$T_TMP/bin"
# T_GARBLE=truncate|junk: the first registry lock of the run rewrites the file.
cat >"$T_TMP/bin/flock" <<EOS
#!/usr/bin/env bash
if [ "\$*" = "-w 30 9" ] && [ -n "\${T_GARBLE:-}" ] && [ ! -e "$T_TMP/garbled" ]; then
  : >"$T_TMP/garbled"
  case "\$T_GARBLE" in
    truncate) : >"$R/registry.tsv" ;;
    junk) printf 'c-00\\0\\377\\376 garbage\\nc-005\\tcla' >"$R/registry.tsv" ;;
  esac
fi
exec "$REAL_FLOCK" "\$@"
EOS
chmod +x "$T_TMP/bin/flock"

rec() {  # ID ALIVE UPDATED_AT, as agent-identity.py writes it
  mkdir -p "$R/agents"
  python3 -c 'import json,sys; json.dump({"v":1,"id":sys.argv[1],"kind":"claude","alive":sys.argv[2]=="true","pid":None,"updated_at":sys.argv[3]}, open(sys.argv[4],"w"), indent=1, sort_keys=True)' \
    "$1" "$2" "$3" "$R/agents/$1.json"
}
agent() { mkdir -p "$R/$1/inbox"; printf '%s\tclaude\t%%9\t/x\t20261001T080000Z\n' "$1" >>"$R/registry.tsv"; }
fixture() {  # c-004 dead 8 h, c-005 dead 2 h, c-007 alive (a window)
  [ -z "${P7:-}" ] || tmux -S "$SPOOL_TMUX_SOCKET" kill-pane -t "$P7" 2>/dev/null
  rm -rf "$R" "$T_TMP/garbled"; mkdir -p "$R"
  agent c-004; rec c-004 false 2026-10-02T04:00:00Z
  agent c-005; rec c-005 false 2026-10-02T10:00:00Z
  agent c-007; P7="$(t_window 'tg: c-007 busy' 'sleep 600')"
}
# The allocator's next five ids: none of the held or quarantined ones.
alloc5() { local _; for _ in 1 2 3 4 5; do printf '%s ' "$(bash "$NAI" --kind claude)"; done; }
safe() {  # LABEL REAP_OUTPUT RC
  local out a
  eq "$1: the reaper exits 0" 0 "$3"
  has "$1: the dead c-004 is reaped" "REAP c-004: dead 8 h" "$2"
  has "$1: ...and quarantined in registry.retired.tsv" "c-004	claude	%9	/x	20261001T080000Z	20261002T120000Z" "$(cat "$R/registry.retired.tsv")"
  check "$1: c-005 (dead 2 h) keeps its dir and record" test -d "$R/c-005/inbox" -a -e "$R/agents/c-005.json"
  check "$1: c-007 (alive) keeps its dir" test -d "$R/c-007/inbox"
  hasnt "$1: c-005 is not reaped" "REAP c-005" "$2"
  hasnt "$1: c-007 is not reaped" "REAP c-007" "$2"
  out="$(SPOOL_NOW=2026-10-02T12:10:00Z bash "$REAP" --apply 2>&1)"; eq "$1: the next tick exits 0" 0 "$?"
  has "$1: ...and keeps c-005" "KEEP c-005: dead 130 min" "$out"
  hasnt "$1: ...reaping nobody" "REAP" "$out"
  a="$(alloc5)"
  hasnt "$1: the allocator never hands out c-004 (quarantine): $a" "c-004" "$a"
  hasnt "$1: ...nor c-005 (held): $a" "c-005" "$a"
  hasnt "$1: ...nor c-007 (held): $a" "c-007" "$a"
  eq "$1: ...and hands out five distinct ids" 5 "$(tr ' ' '\n' <<<"$a" | grep -c .)"
}

# --- garbled before the reaper starts --------------------------------------------
fixture
printf 'not a row\n\0\377\376\nc-0041\tclaude\nCLE-\t\t\n\tc-005\n' >>"$R/registry.tsv"
out="$(bash "$REAP" --apply 2>&1)"; safe "garbled at start" "$out" "$?"
eq "garbled at start: every decision names an agent id (junk is no candidate)" "" \
  "$(grep -E ' (KEEP|SKIP|REAP|PLAN) ' <<<"$out" | grep -vE ' (KEEP|SKIP|REAP|PLAN) (c-[0-9]{3,4}|CLE-[0-9]+):' | sed -n 1,3p)"

# --- truncated while c-004 is retired ----------------------------------------------
fixture
out="$(PATH="$T_TMP/bin:$PATH" T_GARBLE=truncate bash "$REAP" --apply 2>&1)"; rc=$?
check "CONTROL truncate: the shim fired" test -e "$T_TMP/garbled"
safe "truncated mid-reap" "$out" "$rc"

# --- garbled (NUL, high bytes, a half row) while c-004 is retired -------------------
fixture
out="$(PATH="$T_TMP/bin:$PATH" T_GARBLE=junk bash "$REAP" --apply 2>&1)"; rc=$?
check "CONTROL junk: the shim fired" test -e "$T_TMP/garbled"
safe "garbled mid-reap" "$out" "$rc"
eq "garbled mid-reap: the half row of c-005 survives the rewrite" 1 "$(grep -ac '^c-005' "$R/registry.tsv")"

t_done
