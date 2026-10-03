#!/usr/bin/env bash
# test-agent-id.sh — the agent id grammar (specs/061 wave A, accept only):
# c-004 and the legacy CLE-07 both parse, the legacy form is refused on a
# write path after SPOOL_LEGACY_ID_UNTIL (read through SPOOL_NOW, FR-004), and
# that constant equals spec 061 section 0 and the Go agentid.LegacyUntil (FR-005).
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
. "$T_FEAT/lib/agent-state.inc.sh"

before=2026-10-02T12:00:00Z after=2026-10-03T21:00:00Z
nope() { ! "$@" 2>/dev/null; }

# 1. the grammar
for id in c-004 a-123 g-999 q-005 c-001; do
  check "1. agent id: $id" spl_is_agent_id "$id"
done
for id in c-000 C-004 c-4 c-0004 x-004 c004 HUM-17 GST-2 BOX-1 ''; do
  check "1. not an agent id: '$id'" nope spl_is_agent_id "$id"
done
for id in c-004 HUM-17 GST-2 BOX-1 CLE-77952; do
  check "1. participant: $id" spl_is_participant_id "$id"
done
check "1. not a participant: c-4" nope spl_is_participant_id c-4
eq "1. kind of c-004" claude "$(spl_kind_of_agent_id c-004)"
eq "1. kind of a-010" agy "$(spl_kind_of_agent_id a-010)"
eq "1. kind of GRK-7" grok "$(spl_kind_of_agent_id GRK-7)"
eq "1. kind of q-004" qwen "$(spl_kind_of_agent_id q-004)"
check "1. spool_valid_id c-004" spool_valid_id c-004

# 2. the cutoff, through the injectable clock
SPOOL_NOW="$before"
check "2. CLE-77952 accepted before the cutoff" spl_is_agent_id CLE-77952
SPOOL_NOW="$SPOOL_LEGACY_ID_UNTIL"
check "2. CLE-77952 accepted AT the cutoff instant" spl_is_agent_id CLE-77952
SPOOL_NOW="$after"
err="$(spl_is_agent_id CLE-77952 2>&1)"; rc=$?
eq "2. CLE-77952 refused after the cutoff" 1 "$rc"
has "2. FR-003 text without an alias" "CLE-77952 is retired as an id; use c-0NN" "$err"
printf 'CLE-77952\tc-007\tclaude\tbox-desk\t2026-10-02T10:00:00Z\n' >"$SPOOL_ROOT/agent-id-aliases.tsv"
err="$(spl_is_agent_id CLE-77952 2>&1)"
has "2. FR-003 text names the alias" "CLE-77952 is retired as an id; use c-007" "$err"
eq "2. resolve through the alias table" c-007 "$(spl_agent_id_resolve CLE-77952)"
eq "2. no alias row resolves to itself" CLE-5 "$(spl_agent_id_resolve CLE-5)"
printf 'CLE-9\tc-010\tclaude\tbox-a\tx\nCLE-9\tc-011\tclaude\tbox-b\tx\n' >>"$SPOOL_ROOT/agent-id-aliases.tsv"
eq "2. a bare id with two box rows stays itself" CLE-9 "$(spl_agent_id_resolve CLE-9)"
eq "2. id@box picks that box's row" c-011 "$(spl_agent_id_resolve CLE-9@box-b)"
check "2. c-004 still accepted after the cutoff" spl_is_agent_id c-004
check "2. HUM-17 still a participant after the cutoff" spl_is_participant_id HUM-17
check "2. spool_valid_id refuses CLE-7 after the cutoff" nope spool_valid_id CLE-7
SPOOL_NOW=1790000000   # epoch seconds: 2026-09-21
check "2. epoch SPOOL_NOW before the cutoff" spl_legacy_id_ok
SPOOL_NOW="$before"
rm -f "$SPOOL_ROOT/agent-id-aliases.tsv"

# 3. readers take both forms whatever the clock (window names, FR-010)
for SPOOL_NOW in "$before" "$after"; do
  for w in "c-004 wip" "bx1: c-004 > wip" "c-004@box-desk ? wip" "c-004"; do
    eq "3. [$SPOOL_NOW] id of window '$w'" c-004 "$(spool_id_of_window "$w")"
  done
  eq "3. [$SPOOL_NOW] id of window 'bx1: CLE-07 wip'" CLE-07 "$(spool_id_of_window "bx1: CLE-07 wip")"
done
SPOOL_NOW="$before"
eq "3. an_strip tagged c-004" "c-004 > wip" "$(SPOOL_BOX_TAG=bx1 an_strip "bx1: c-004 > wip")"
eq "3. an_strip c-004@box" "c-004 > wip" "$(an_strip "c-004@box-desk > wip")"
eq "3. an_strip badge in front" "c-004 ! wip" "$(an_strip "! bx1: c-004 wip")"
eq "3. badge of c-004" ">" "$(name_badge "bx1: c-004 > wip")"
eq "3. decorate c-004" "c-004@bx1 wip" "$(SPOOL_BOX_TAG=bx1 an_decorate "c-004 wip")"
eq "3. launcher argv" "claude c-004" "$(printf 'bash /x/spawn-claude.sh c-004 /w\n' | agent_of_ps)"
eq "3. hop env id" "claude c-004" "$(printf "sudo env SPOOL_AGENT_ID=c-004 /h/.local/bin/claude\n" | agent_of_ps)"
py="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$T_SCRIPTS/agent-identity.py" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("ai", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.strip_name("bx1: c-004 > wip")[0], m.strip_name("c-004@box-desk wip")[0], m.badge_of("bx1: c-004 > wip"),
      bool(m.ID_RE.match("c-004")), bool(m.ID_RE.match("CLE-7")), bool(m.ID_RE.match("c-4")),
      m.NAME_ID_RE.findall("CLE-77957-x c-004-y"))
PY
)"
eq "3. agent-identity.py reads c-004" "c-004 c-004 > True True False ['CLE-77957', 'c-004']" "$py"
py="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$T_SCRIPTS/spool-mirror.py" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("sm", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(bool(m.ID_RE.match("c-004")), bool(m.ID_RE.match("HUM-17")),
      bool(m.MACHINE_LINE.match(": 'SPOOL c-004: x")))
PY
)"
eq "3. spool-mirror.py reads c-004" "True True True" "$py"

# 4. FR-005: one instant, pinned in every module
spec="$T_REPO/csi-spl-doc/specs/061-agent-id-rename/spec.md"
eq "4. spec 061 section 0 names SPOOL_LEGACY_ID_UNTIL" 1 \
  "$(grep -c "LEGACY AGENT IDS END AT \`${SPOOL_LEGACY_ID_UNTIL}\`" "$spec")"
go="$T_REPO/csi-spl-api/src/go/spool-hub-api/internal/agentid/agentid.go"
if [ -r "$go" ]; then
  gv="$(python3 - "$go" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'LegacyUntil\w*\s*=\s*"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)"', s)
if m:
    print(m.group(1))
else:
    m = re.search(r'LegacyUntil\s*=\s*time\.Date\(\s*(\d+),\s*(?:time\.)?(\w+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+)', s)
    months = "January February March April May June July August September October November December".split()
    mo = m.group(2); mo = months.index(mo) + 1 if mo in months else int(mo)
    print("%04d-%02d-%02dT%02d:%02d:%02dZ" % (int(m.group(1)), mo, *map(int, m.group(3, 4, 5, 6))))
PY
)"
  eq "4. bash SPOOL_LEGACY_ID_UNTIL == Go agentid.LegacyUntil" "$gv" "$SPOOL_LEGACY_ID_UNTIL"
else
  nok "4. Go agentid.LegacyUntil not found at $go"
fi

# 5. a c-004 window is counted, listed and closable (private tmux server)
if command -v tmux >/dev/null 2>&1; then
  t_tmux
  t_window "bx1: CLE-10 wip" 'sleep 600' >/dev/null
  p4="$(t_window "bx1: c-004 demo" 'sleep 600')"
  eq "5. the window count regex counts c-004" 2 "$(tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a -F '#{window_name}' \
    | grep -cE '^([A-Za-z0-9][A-Za-z0-9._-]*: )?([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)')"
  eq "5. pane-scan lists c-004 on its pane" 1 "$(bash "$T_SCRIPTS/pane-scan.sh" 2>&1 | grep -cE "c-004 +$p4\$")"
  has "5. agent-top lists c-004" "c-004 " "$(SPOOL_BOX_TAG=bx1 bash "$T_SCRIPTS/agent-top.sh" 2>&1)"
  out="$(bash "$T_SCRIPTS/tmux-close-window.sh" --agent C-004 2>&1)"
  has "5. tmux-close-window --agent C-004 normalises to c-004" "killed window" "$out"
  hasnt "5. ...and c-004's window is gone" "c-004" "$(tmux -S "$SPOOL_TMUX_SOCKET" list-windows -a -F '#{window_name}')"
fi

t_done
