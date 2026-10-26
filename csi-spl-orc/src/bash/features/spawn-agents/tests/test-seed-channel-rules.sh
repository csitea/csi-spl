#!/usr/bin/env bash
# A seat whose brief names a mapped channel (`Channel: <tenant> #<channel>`)
# reads that channel's rules doc before it acts, at its first seed and at
# every rotation/restart seed (SPL-3500; owner HUM-10 msg 4501003a). The seed
# generator exports the doc to a file and the seed names it; the doc's rules
# are never copied into the seed. Renders seeds with SPAWN_DRY_RUN=1 and
# SPAWN_PLAN_DIR (the export lands in the plan dir) and a stub export
# (CHANNEL_RULES_EXPORT_CMD). Cases: the mapped seat gets the line and a
# non-empty file; a seat on another channel, or with no Channel: line, gets
# no change; a failed and an empty export are FATAL and write no seed; a
# rotation seed (a BRIEF with no Channel: line) still gets it from the
# recorded task brief. Control: spawn-core without the CHANNEL_RULES slot ->
# the line is missing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
DOC=0a1b2c3d-1111-2222-3333-444455556666
printf 'acme\tops\t%s\tprd\tc-900\n' "$DOC" > "$SPOOL_ROOT/channel-rules.tsv"
export CHANNEL_RULES_EXPORT_CMD='printf "# 1 Rules of %s\n\n- rule one, doc %s, env %s, as %s\n" "$CR_TENANT" "$CR_DOC" "$CR_ENV" "$CR_AGENT"'

printf '# Seat brief: ops seat\n\nEpic: SPL-1\nChannel: acme #ops\n\nWork.\n' > "$T_TMP/ops.md"
printf '# Seat brief: other seat\n\nChannel: acme #sales\n\nWork.\n' > "$T_TMP/other.md"
printf '# Lane brief: about the ops seats, mentions acme #ops only in prose\n\nWork.\n' > "$T_TMP/prose.md"
printf '# Rotation seed\n\nRead your brief and the handoff.\n' > "$T_TMP/seed.md"
mkdir -p "$T_TMP/plain"

seed() {  # SCRIPTS_DIR ID BRIEF PLAN -> prints the rendered seed; rc of the spawn in $T_TMP/rc
  rm -rf "$4"; mkdir -p "$4"
  SPAWN_PLAN_DIR="$4" bash "$1/spawn-claude.sh" "$2" "$T_TMP/plain" "$3" "rules" >"$4/out" 2>&1
  echo $? > "$T_TMP/rc"
  cat "$4/prompt.txt" 2>/dev/null
}

s="$(seed "$T_SCRIPTS" c-901 "$T_TMP/ops.md" "$T_TMP/p1")"
has "mapped seat: the seed carries the rules line" "CHANNEL RULES (acme #ops): before you act" "$s"
has "... naming the exported file" "read $T_TMP/p1/channel-rules.md, the export of qto doc $DOC" "$s"
check "... and that file is non-empty" test -s "$T_TMP/p1/channel-rules.md"
has "... holding the doc's export" "rule one, doc $DOC, env prd, as c-900" "$(cat "$T_TMP/p1/channel-rules.md" 2>/dev/null)"
hasnt "... the doc's rules are not copied into the seed" "rule one" "$s"
has "... the plan names the step" "PLAN rules" "$(cat "$T_TMP/p1/out")"

s="$(seed "$T_SCRIPTS" c-902 "$T_TMP/other.md" "$T_TMP/p2")"
hasnt "seat on an unmapped channel: no rules line" "CHANNEL RULES" "$s"
check "... and no file" test ! -e "$T_TMP/p2/channel-rules.md"
has "... the seed is still written" "Your spool agent id is c-902" "$s"

s="$(seed "$T_SCRIPTS" c-903 "$T_TMP/prose.md" "$T_TMP/p3")"
hasnt "brief that only mentions the channel in prose: no rules line" "CHANNEL RULES" "$s"

s="$(CHANNEL_RULES_EXPORT_CMD='exit 7' seed "$T_SCRIPTS" c-904 "$T_TMP/ops.md" "$T_TMP/p4")"
eq "failed export: the spawn fails" 1 "$(cat "$T_TMP/rc")"
has "... with a FATAL naming the doc" "FATAL channel rules: the export of qto doc $DOC" "$(cat "$T_TMP/p4/out")"
check "... and writes no seed" test ! -e "$T_TMP/p4/prompt.txt"
check "... and no rules file" test ! -e "$T_TMP/p4/channel-rules.md"

s="$(CHANNEL_RULES_EXPORT_CMD='printf "  \n\n"' seed "$T_SCRIPTS" c-905 "$T_TMP/ops.md" "$T_TMP/p5")"
eq "empty export: the spawn fails" 1 "$(cat "$T_TMP/rc")"
has "... with a FATAL" "or is empty" "$(cat "$T_TMP/p5/out")"
check "... and writes no seed" test ! -e "$T_TMP/p5/prompt.txt"

printf 'acme\tops\tnot-a-uuid\tprd\tc-900\n' > "$T_TMP/bad.tsv"
s="$(SPOOL_CHANNEL_RULES_MAP="$T_TMP/bad.tsv" seed "$T_SCRIPTS" c-906 "$T_TMP/ops.md" "$T_TMP/p6")"
eq "malformed map row: the spawn fails" 1 "$(cat "$T_TMP/rc")"
has "... with a FATAL naming the row" "is not '<doc uuid> <dev|prd> <agent id>'" "$(cat "$T_TMP/p6/out")"

# A rotation or restart hands spawn-core a seed file as BRIEF; the task brief
# is still lifetime/brief.md (spawn-core records BRIEF over it only later).
mkdir -p "$SPOOL_ROOT/c-907/lifetime"; cp "$T_TMP/ops.md" "$SPOOL_ROOT/c-907/lifetime/brief.md"
s="$(seed "$T_SCRIPTS" c-907 "$T_TMP/seed.md" "$T_TMP/p7")"
has "rotation seed: the rules line from the recorded task brief" "CHANNEL RULES (acme #ops)" "$s"
check "... and a non-empty file" test -s "$T_TMP/p7/channel-rules.md"

s="$(seed "$T_SCRIPTS" c-908 "$T_TMP/seed.md" "$T_TMP/p8")"
hasnt "rotation seed of a seat with no channel: no rules line" "CHANNEL RULES" "$s"

# A dry run without a plan dir exports nothing and names the live path.
out="$(CHANNEL_RULES_EXPORT_CMD='exit 7' bash "$T_SCRIPTS/spawn-claude.sh" c-909 "$T_TMP/plain" "$T_TMP/ops.md" rules 2>&1)"
has "dry run, no plan dir: the line names the live file" "read $SPOOL_ROOT/c-909/lifetime/channel-rules.md" "$out"

CTL="$T_TMP/ctl/spawn-agents"; mkdir -p "$CTL"
cp -r "$T_FEAT/scripts" "$T_FEAT/lib" "$T_FEAT/assets" "$CTL/" 2>/dev/null
sed -i 's/\${CHANNEL_RULES:+\${CHANNEL_RULES} }//' "$CTL/scripts/spawn-core.inc.sh"
c="$(seed "$CTL/scripts" c-910 "$T_TMP/ops.md" "$T_TMP/ctl-p")"
has "control renders a seed" "Your spool agent id is c-910" "$c"
hasnt "control (no CHANNEL_RULES slot): the line is missing -> FAIL" "CHANNEL RULES" "$c"
t_done
