#!/usr/bin/env bash
# The seed names a spool binary the AGENT USER can run (c-908 msg 22a471ef).
# The spawner's SPOOL_BIN sits under its own home, whose .local is 0700: an
# agent user that differs got rc 126 / Permission denied from the seed's
# literal recv line. Renders a seed (SPAWN_DRY_RUN=1) for an agent user other
# than the spawner and asserts the named binary is not under the spawner's
# home. Red control: the same render on the source before the fix (the seed
# quoting SPOOL_BIN) -> FAIL.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 MISTRAL_BIN=/opt/x/vibe SPOOL_MISTRAL_MAX_PRICE=1
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
export HOME="$T_TMP/spawner-home"
mkdir -p "$HOME/.local/bin" "$T_TMP/plain" "$T_TMP/stub"
SPAWNER_BIN="$HOME/.local/bin/spool"
echo brief > "$T_TMP/brief.md"

seed() {  # PLAN [ENV=VAL ...] -> prints the rendered seed
  local plan="$1"; shift
  mkdir -p "$plan"
  env "$@" SPAWN_PLAN_DIR="$plan" bash "$T_SCRIPTS/spawn-claude.sh" c-079 "$T_TMP/plain" "$T_TMP/brief.md" "spool bin" >"$plan/out" 2>&1
  cat "$plan/prompt.txt" 2>/dev/null
}

# 1. No sudo answer (no such user, here): the spawner's home path is refused, bare spool.
s="$(seed "$T_TMP/p1" SPOOL_BIN="$SPAWNER_BIN" SPOOL_AGENT_USER=spl-test-no-such-agent)"
has   "other agent user: a seed is rendered" "Your spool agent id is c-079" "$s"
hasnt "other agent user: the seed names no binary under the spawner's home" "$HOME/" "$s"
has   "other agent user, no resolve: the recv line runs bare spool" "SPOOL_ROOT=${SPOOL_ROOT} spool recv --as c-079" "$s"

# 2. Resolved AS the agent user: its own binary (sudo stubbed to answer as it would).
printf '#!/bin/sh\necho /agent-home/.local/bin/spool\n' > "$T_TMP/stub/sudo"; chmod +x "$T_TMP/stub/sudo"
s="$(seed "$T_TMP/p2" PATH="$T_TMP/stub:$PATH" SPOOL_BIN="$SPAWNER_BIN" SPOOL_AGENT_USER=spl-test-no-such-agent)"
hasnt "resolved as agent: no spawner-home binary" "$HOME/" "$s"
has   "resolved as agent: the recv line names the agent user's spool" "SPOOL_ROOT=${SPOOL_ROOT} /agent-home/.local/bin/spool recv --as c-079" "$s"
has   "resolved as agent: the plan shows the seed binary" "seed-bin=/agent-home/.local/bin/spool" "$(cat "$T_TMP/p2/out")"

# 3. A binary outside the spawner's home, no resolve: kept as it is.
s="$(seed "$T_TMP/p3" SPOOL_BIN=/opt/x/spool SPOOL_AGENT_USER=spl-test-no-such-agent)"
has   "shared path, no resolve: kept" "SPOOL_ROOT=${SPOOL_ROOT} /opt/x/spool recv --as c-079" "$s"

# 4. Agent user = spawner: unchanged, SPOOL_BIN as before.
s="$(seed "$T_TMP/p4" SPOOL_BIN="$SPAWNER_BIN")"
has   "same user: the seed keeps SPOOL_BIN" "SPOOL_ROOT=${SPOOL_ROOT} ${SPAWNER_BIN} recv --as c-079" "$s"
t_done
