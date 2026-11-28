#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 184 row L5, the one sandbox the rotation, peer restart and
#          lane rotation tests share to prove a respawn takes the model of the
#          setting in force. ml_setup builds it under DIR: a claude stub whose
#          --help names the aliases (claude 2.1.323), a cnf with
#          default.claude sonnet and by_kind.tests.claude opus, a private tmux
#          server, a stub lane map, a throwaway checkout with an origin, and
#          the lane ID's lifetime/category.json "tests" (its first spawn's
#          record). ROTATE_SPAWN="$ML/bin/spawn-dry" then runs the REAL
#          spawn-window.sh as a dry run (SPAWN_DRY_RUN=1) with the env and args
#          the caller gave it, appends its output to $ML/spawn.out (one
#          "=== <args>" line first) and prints "<ID> %77" as a live spawn does.
#          ml_model_stub makes ROTATE_SPAWN="$ML/bin/spawn-model": no
#          spawn-window, it records the model spool_agent_model resolves from
#          that env in lifetime/model.txt (as the launcher does) and one
#          "<model> <SPAWN_REUSE_ID>" line in $ML/launches.
# Usage:   . model-launch.inc.sh; ml_setup "$DIR" c-901   (exports ML, SPOOL_ROOT, ...)
#------------------------------------------------------------------------------
ML_FEAT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents" && pwd)"

ml_setup() {  # DIR ID
  ML="$1"; mkdir -p "$ML/bin" "$ML/orc" "$ML/spool/$2/lifetime"
  unset TMUX TMUX_PANE MCP_BOT_AGENT_ID SPOOL_AGENT_ID SPAWN_MODEL SPAWN_MODEL_MAP SPAWN_TASK_KIND DRY_RUN CLE_TMUX_PANE CLE_TMUX_SOCK SPOOL_BOX_ENV
  local me; me="$(id -un)"
  export ML ML_FEAT SPOOL_ROOT="$ML/spool" SPOOL_TMUX_SOCKET="$ML/tmux.sock" SPOOL_BOX_USER="$me" SPOOL_AGENT_USER="$me" \
    SPOOL_BOX_TAG="" SPAWN_TEST_SANDBOX=1 SPOOL_TEST=1 SPOOL_VENDOR_CLIS_CMD="echo claude,grok,agy,qwen,mistral" \
    RETIRE_LANE=0 SPOOL_BIN=/opt/x/spool CLAUDE_BIN="$ML/bin/claude" ROTATE_CLAUDE_BIN="$ML/bin/claude" \
    SPOOL_AGENT_MODEL_CNF="$ML/model.yaml" LANE_MAP_ORC="$ML/orc"
  printf '{"work_kind":"tests","category_path":""}\n' >"$SPOOL_ROOT/$2/lifetime/category.json"
  ml_cnf opus
  cat >"$ML/bin/claude" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf '%s\n' "  --model <model>   Model for the current session. Provide an alias for" \
            "                    the latest model (e.g. 'opus' or 'sonnet') or a full name" ;;
  --version) echo "2.1.323 (Claude Code)" ;;
esac
EOS
  printf '#!/usr/bin/env bash\nexit 0\n' >"$ML/orc/run"
  cat >"$ML/bin/spawn-dry" <<'EOS'
#!/usr/bin/env bash
echo "=== $*" >>"$ML/spawn.out"
SPAWN_DRY_RUN=1 timeout 60 bash "$ML_FEAT/scripts/spawn-window.sh" "$@" >>"$ML/spawn.out" 2>&1
echo "$2 %77"
EOS
  chmod +x "$ML/bin/claude" "$ML/orc/run" "$ML/bin/spawn-dry"
  tmux -S "$SPOOL_TMUX_SOCKET" -f /dev/null new-session -d -s t -n home 'sleep 600'
  git init -q --bare "$ML/origin.git"
  git init -q -b master "$ML/repo"
  git -C "$ML/repo" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  git -C "$ML/repo" remote add origin "$ML/origin.git"
  git -C "$ML/repo" push -q origin master 2>/dev/null
}

# ml_cnf TESTS_MODEL: default.claude sonnet, by_kind.tests.claude TESTS_MODEL.
ml_cnf() {
  printf 'env:\n  box:\n    agent_model:\n      default: { claude: "sonnet" }\n      by_kind: { tests: { claude: "%s" } }\n' "$1" >"$ML/model.yaml"
}

ml_model_stub() {
  cat >"$ML/bin/spawn-model" <<'EOS'
#!/usr/bin/env bash
. "$ML_FEAT/lib/spool-env.inc.sh"
k="$(jq -r '.work_kind // empty' "$SPOOL_ROOT/$2/lifetime/category.json" 2>/dev/null)"
m="$(spool_agent_model claude "$k" 2>/dev/null)"
printf '%s\n' "${m:-cli-default}" >"$SPOOL_ROOT/$2/lifetime/model.txt"
printf '%s %s\n' "${m:-cli-default}" "${SPAWN_REUSE_ID:-0}" >>"$ML/launches"
echo "$2 %77"
EOS
  chmod +x "$ML/bin/spawn-model"
}

# ml_launch: the PLAN launch lines of $ML/spawn.out; ml_models: their --model words.
ml_launch() { grep '^PLAN launch' "$ML/spawn.out" 2>/dev/null; }
ml_models() { ml_launch | grep -oE -- "--model '[^']*'" | paste -sd' '; }
ml_cleanup() { tmux -S "$SPOOL_TMUX_SOCKET" kill-server 2>/dev/null || true; }
