#!/usr/bin/env bash
# The codex launcher (spec 161 4.1 item 3 / 4.2 item 2, letter o; SPL-4746):
# spawn-window.sh codex plans the codex launch line with the bypass flags and
# an o-NNN id, and codex stays OFF on a box without the codex CLI or its
# login (owner HUM-10 msg 9c70e4f7): one REFUSED line, exit 13, no claim, no
# window, no pane.
#
# Hermetic: a throwaway SPOOL_ROOT, a private tmux server, a fake codex
# binary (CODEX_BIN) and a fake agent HOME holding (or not) the login
# marker. The vendor probe is the REAL one (spool_vendor_clis, as the agent
# user = this user), not the sandbox's SPOOL_VENDOR_CLIS_CMD stub. No codex
# is installed or run.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
unset SPOOL_VENDOR_CLIS_CMD OPENAI_API_KEY CODEX_API_KEY
SW="$T_SCRIPTS/spawn-window.sh"
TM=(tmux -S "$SPOOL_TMUX_SOCKET")
echo brief > "$T_TMP/brief.md"
ORC="$T_TMP/orc"; mkdir -p "$ORC"
printf '#!/usr/bin/env bash\necho "$*" >> "%s/lane.calls"\n' "$T_TMP" > "$ORC/run"; chmod +x "$ORC/run"
export LANE_MAP_ORC="$ORC"
git init -q --bare "$T_TMP/origin.git"
git init -q -b master "$T_TMP/repo"
git -C "$T_TMP/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
git -C "$T_TMP/repo" remote add origin "$T_TMP/origin.git"
git -C "$T_TMP/repo" push -q origin master 2>/dev/null

# The fake codex and the agent HOME with its login marker (the default
# .codex/auth.json; the cnf may name it, SPOOL_CODEX_AUTH_MARKER pins it here).
BIN="$T_TMP/bin/codex"; mkdir -p "${BIN%/*}"
printf '#!/bin/sh\necho "codex-cli 0.0.0-fake"\n' > "$BIN"; chmod +x "$BIN"
AH="$T_TMP/home"; mkdir -p "$AH/.codex"; : > "$AH/.codex/auth.json"
export SPOOL_CODEX_AUTH_MARKER=.codex/auth.json SPOOL_BIN=/opt/x/spool
ready() { env HOME="$AH" CODEX_BIN="$BIN" SPAWN_DRY_RUN=1 "$@"; }

# ---- the plan --------------------------------------------------------------
mkdir -p "$T_TMP/plan"
PLANT="planted-fake-$$"   # an exported API key must not reach the plan
out="$(ready SPAWN_PLAN_DIR="$T_TMP/plan" OPENAI_API_KEY="$PLANT" timeout 60 bash "$SW" codex auto "$T_TMP/repo" "$T_TMP/brief.md" codex-proof 2>&1)"; rc=$?
eq "plan: spawn-window codex auto exits 0" 0 "$rc"
id="$(sed -n 's/^PLAN claim  *\(o-[0-9]\{3\}\) .*/\1/p' <<<"$out")"
check "plan: claims an o-NNN id (got '${id}')" test -n "$id"
lc="$(cat "$T_TMP/plan/launch.cmd" 2>/dev/null)"
has "plan: the codex launch line with the bypass flags, telemetry and update check off, the seed positional" \
  "--mirror -- '$BIN' --dangerously-bypass-approvals-and-sandbox -c analytics.enabled=false -c check_for_update_on_startup=false \"Read and follow your seed: $T_TMP/plan/prompt.txt\"" "$lc"
has "plan: the launch unsets the API keys (the subscription login only)" "exec env -u OPENAI_API_KEY -u CODEX_API_KEY bash '" "$lc"
hasnt "plan: an exported OPENAI_API_KEY is in no plan output" "$PLANT" "$out$lc"
has "plan: the pane env is named after the kind" "export CODEX_TMUX_PANE=" "$lc"
has "plan: the adapter line" "kind=codex prefix=<none> bin=$BIN" "$out"
has "plan: the resume stub" "env -u OPENAI_API_KEY -u CODEX_API_KEY codex --dangerously-bypass-approvals-and-sandbox -c analytics.enabled=false -c check_for_update_on_startup=false resume <SESSION_ID>" "$out"
has "plan: the worktree gets rwX for the agent user" "PLAN acl" "$out"
has "plan: the seed retitles through riname --agent" "riname.sh --agent ${id:-o-}" "$(cat "$T_TMP/plan/prompt.txt" 2>/dev/null)"
check "plan: the dry run made no spool dir" test ! -e "$SPOOL_ROOT/${id:-o-x}"
out="$(ready bash "$SW" codex o-077 "$T_TMP/repo" "$T_TMP/brief.md" x 2>&1)"; rc=$?
eq "plan: a named o-077 exits 0" 0 "$rc"
has "plan: ... and plans o-077" "PLAN claim      o-077" "$out"
eq "next-agent-id --kind codex: an o- id" o "$(bash "$T_SCRIPTS/next-agent-id.sh" --kind codex --no-reserve | cut -c1)"
eq "next-agent-id --prefix o: an o- id" o "$(bash "$T_SCRIPTS/next-agent-id.sh" --prefix o --no-reserve | cut -c1)"

# ---- red controls: kind and letter ----------------------------------------
out="$(ready bash "$SW" codexx auto "$T_TMP/repo" 2>&1)"; rc=$?
eq "control: an unknown vendor is refused (usage)" 2 "$rc"
has "control: ... the usage names codex" "<claude|grok|agy|qwen|mistral|codex>" "$out"
out="$(ready bash "$SW" codex c-077 "$T_TMP/repo" 2>&1)"; rc=$?
eq "control: spawn-window codex refuses a c- id" 2 "$rc"
has "control: ... named" "c-077 is not a codex id" "$out"
out="$(ready bash "$T_SCRIPTS/spawn-codex.sh" m-077 "$T_TMP/repo" 2>&1)"; rc=$?
eq "control: the codex adapter refuses an m- id" 1 "$rc"
has "control: ... by letter" "does not carry the codex letter o-" "$out"
out="$(ready MISTRAL_BIN=/opt/x/vibe bash "$T_SCRIPTS/spawn-mistral.sh" o-077 "$T_TMP/repo" 2>&1)"; rc=$?
eq "control: the mistral adapter refuses an o- id" 1 "$rc"

# ---- red controls: codex is off without the CLI or the login ---------------
win_before="$("${TM[@]}" list-windows -a -F '#{window_name}' | sort)"
off() {  # DESC ENV...
  local d="$1" o r; shift
  o="$(env "$@" timeout 60 bash "$SW" codex auto "$T_TMP/repo" "$T_TMP/brief.md" off-proof 2>&1)"; r=$?
  eq "off ($d): exit 13" 13 "$r"
  has "off ($d): one REFUSED line" "codex is off on this box" "$o"
  eq "off ($d): ... exactly one line" 1 "$(grep -c . <<<"$o")"
  hasnt "off ($d): no id claimed" "PLAN claim" "$o"
}
off "no binary, dry run" HOME="$AH" CODEX_BIN="$T_TMP/bin/nope" SPAWN_DRY_RUN=1
off "no login, dry run" HOME="$T_TMP/nohome" CODEX_BIN="$BIN" SPAWN_DRY_RUN=1
# Live (no SPAWN_DRY_RUN): the refusal comes before the claim and the window.
off "no login, live" HOME="$T_TMP/nohome" CODEX_BIN="$BIN" SPAWN_START_CHECK=0
eq "off (live): no window was made" "$win_before" "$("${TM[@]}" list-windows -a -F '#{window_name}' | sort)"
eq "off (live): no o- id claimed" "" "$(cd "$SPOOL_ROOT" && ls -d o-* 2>/dev/null)"
out="$(env HOME="$T_TMP/nohome" CODEX_BIN="$BIN" SPAWN_DRY_RUN=1 bash "$T_SCRIPTS/spawn-codex.sh" o-078 "$T_TMP/repo" 2>&1)"; rc=$?
eq "off: the adapter called directly refuses too (exit 13)" 13 "$rc"
hasnt "off: ... before any plan" "PLAN " "$out"

# ---- restore ---------------------------------------------------------------
mkdir -p "$T_TMP/rundir"
out="$(env HOME="$AH" CODEX_BIN="$BIN" RESTORE_PRINT=1 bash "$T_SCRIPTS/restore-codex.sh" o-077 "$T_TMP/rundir" sid-161 2>&1)"; rc=$?
eq "restore: prints its line" 0 "$rc"
has "restore: resumes the session with the launch flags" "exec env -u OPENAI_API_KEY -u CODEX_API_KEY bash '$T_SCRIPTS/spool-harness.sh' --as 'o-077' --mirror -- '$BIN' --dangerously-bypass-approvals-and-sandbox -c analytics.enabled=false -c check_for_update_on_startup=false resume sid-161" "$out"
has "restore: ... with the brief kick" "Read and follow your restore note: $SPOOL_ROOT/o-077/lifetime/kick.txt" "$out"
has "restore: no session id resumes the last one" " resume --last" \
  "$(env HOME="$AH" CODEX_BIN="$BIN" RESTORE_PRINT=1 bash "$T_SCRIPTS/restore-codex.sh" o-077 "$T_TMP/rundir" - 2>&1)"
out="$(env HOME="$T_TMP/nohome" CODEX_BIN="$BIN" RESTORE_PRINT=1 bash "$T_SCRIPTS/restore-codex.sh" o-077 "$T_TMP/rundir" sid-161 2>&1)"; rc=$?
eq "restore off: no login, exit 13" 13 "$rc"
has "restore off: ... named" "codex is off on this box" "$out"

t_done
