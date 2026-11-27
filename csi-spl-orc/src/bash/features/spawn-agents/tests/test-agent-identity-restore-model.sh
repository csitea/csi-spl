#!/usr/bin/env bash
# test-agent-identity-restore-model.sh — spec 184 row L3 (owner Q4 "rot"): a
# restore re-resolves its model from the setting in force, never from the
# lifetime/model.txt the spawn wrote, and runs the live check (Q3 "liv").
# Each case renders the real adapter (RESTORE_PRINT=1) against a fixture cnf
# (SPOOL_AGENT_MODEL_CNF, contract 7.1.1) and stub CLIs.
#
#   1. a seat spawned with sonnet (model.txt), the cnf then set to opus: the
#      restore line carries --model 'opus' once, after the permission flags
#   2. the setting emptied: no --model at all, the line is today's
#   3. the task kind of lifetime/category.json picks its by_kind cell;
#      SPAWN_TASK_KIND beats it
#   4. live check: a model the CLI's list does not hold starts on the CLI
#      default with one WARN; a full claude name passes on syntax alone (G8);
#      a vendor with no list (no CLI to read) skips the check
#   5. a model failing the syntax of 7.1.2 never reaches the line
#   6. grok: --model '<m>' from its models cache
#   7. mistral (restore-mistral.sh): VIBE_ACTIVE_MODEL='<m>' in the env
#      prefix, before spool-harness, with the vibe off switches kept
#   8. lifetime/model.txt (7.1.4) after the resolve: the model started on, or
#      cli-default when emptied, refused by the live list or for a vendor with
#      no model words (qwen); written when lifetime/ does not exist yet
# Red control: _rs_model reading lifetime/model.txt instead -> case 1 fails.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
unset TMUX TMUX_PANE SPOOL_BOX_TAG BOX_TAG SPOOL_AGENT_ID MCP_BOT_AGENT_ID SPAWN_MODEL SPAWN_MODEL_MAP SPAWN_TASK_KIND
H="$T_TMP/home"; B="$T_TMP/bin"; RD="$T_TMP/rundir"
mkdir -p "$H/.grok" "$H/.vibe" "$B" "$RD"
# spool_env_resolve sets SPOOL_AGENT_HOME from getent: a stub getent gives
# every user the fixture home, so no case reads this box's real ~/.grok or
# ~/.vibe.
printf '#!/bin/sh\n[ "$1" = passwd ] && echo "${2:-u}:x:0:0::%s:/bin/sh"\n' "$H" > "$B/getent"
chmod +x "$B/getent"
export PATH="$B:$PATH" SPOOL_AGENT_HOME="$H"

# The stub claude: its --help names the aliases, as 2.1.323 does.
cat > "$B/claude" <<'EOS'
#!/bin/sh
case "$1" in
  --version) echo "2.1.323 (Claude Code)" ;;
  --help) printf '%s\n' "Options:" "  --model <model>  Model for the current session. Provide an alias for the latest" \
            "                   model (e.g. 'fable', 'opus', or 'sonnet') or a model's full name." "  --name <name>    Name" ;;
esac
EOS
printf '#!/bin/sh\necho "grok 1.0.92"\n' > "$B/grok"
printf '#!/bin/sh\necho "vibe 2.26.0"\n' > "$B/vibe"
chmod +x "$B/claude" "$B/grok" "$B/vibe"
printf '{"models": {"grok-4.7": {}, "grok-4.6": {}}}\n' > "$H/.grok/models_cache.json"
printf '[[models]]\nname = "mistral-large"\nalias = "large"\n' > "$H/.vibe/config.toml"

cnf() {  # DEFAULT-CLAUDE [BY_KIND-YAML]
  printf 'env:\n  box:\n    agent_model:\n      default: { claude: "%s", agy: "", grok: "grok-4.6", mistral: "large", qwen: "", codex: "" }\n      by_kind: %s\n' \
    "$1" "${2:-"{}"}" > "$T_TMP/cnf.yaml"
}
export SPOOL_AGENT_MODEL_CNF="$T_TMP/cnf.yaml"
L="$SPOOL_ROOT/c-950/lifetime"; mkdir -p "$L"
echo sonnet > "$L/model.txt"  # the spawn's record: never an input
rc() { env RESTORE_PRINT=1 CLAUDE_BIN="$B/claude" "$@" bash "$T_SCRIPTS/restore-claude.sh" c-950 "$RD" s-950 2>&1; }
line() { grep -m1 'spool-harness.sh' <<<"$1"; }

# --- 1, 2 --------------------------------------------------------------------------
cnf opus
out="$(line "$(rc)")"
has "1. a seat spawned with sonnet, the cnf now opus: the restore carries --model 'opus'" "--dangerously-skip-permissions --model 'opus' --resume s-950" "$out"
hasnt "1. ... never the spawn's sonnet from lifetime/model.txt" "sonnet'" "$out"
eq "1. ... once" 1 "$(grep -o -- "--model" <<<"$out" | wc -l)"
cnf ""
out="$(line "$(rc)")"
hasnt "2. the setting emptied: no --model" "--model" "$out"
has "2. ... the line is today's" "--dangerously-skip-permissions --resume s-950" "$out"

# --- 3 -----------------------------------------------------------------------------
cnf opus '{ tests: { claude: "fable" } }'
printf '{"work_kind": "tests", "category_path": "x"}\n' > "$L/category.json"
has "3. the task kind of lifetime/category.json picks its by_kind cell" "--model 'fable'" "$(line "$(rc)")"
has "3. ... SPAWN_TASK_KIND beats category.json" "--model 'opus'" "$(line "$(rc SPAWN_TASK_KIND=simple_coding)")"
rm -f "$L/category.json"

# --- 4 -----------------------------------------------------------------------------
cnf haiku
full="$(rc)"
hasnt "4. a model the live list does not hold: no --model" "--model" "$(line "$full")"
has "4. ... one WARN naming it" "WARN model haiku refused by claude, started on the CLI default" "$full"
eq "4. ... once" 1 "$(grep -c 'WARN model haiku' <<<"$full")"
cnf claude-opus-5-5
has "4. a full claude name passes on syntax alone (G8)" "--model 'claude-opus-5-5'" "$(line "$(rc)")"
cnf haiku
out="$(env RESTORE_PRINT=1 CLAUDE_BIN="$B/none" bash "$T_SCRIPTS/restore-claude.sh" c-950 "$RD" s-950 2>&1)"
has "4. no list to read (no CLI): the check is skipped, the CLI decides" "--model 'haiku'" "$(line "$out")"
hasnt "4. ... and no WARN" "WARN model" "$out"

# --- 5 -----------------------------------------------------------------------------
printf 'env:\n  box:\n    agent_model:\n      default: { claude: "a b" }\n' > "$T_TMP/cnf.yaml"
out="$(rc)"
hasnt "5. a model failing 7.1.2 never reaches the line" "--model" "$(line "$out")"
has "5. ... the restore still renders" "--resume s-950" "$(line "$out")"

# --- 6 -----------------------------------------------------------------------------
cnf ""
out="$(env RESTORE_PRINT=1 GROK_BIN="$B/grok" bash "$T_SCRIPTS/restore-grok.sh" g-950 "$RD" s-g950 2>&1)"
has "6. grok: --model from its models cache, after the permission flags" "--permission-mode bypassPermissions --model 'grok-4.6'" "$(line "$out")"

# --- 7 -----------------------------------------------------------------------------
out="$(env RESTORE_PRINT=1 MISTRAL_BIN="$B/vibe" SPOOL_MISTRAL_MAX_PRICE=3.50 bash "$T_SCRIPTS/restore-mistral.sh" m-950 "$RD" - 2>&1)"
has "7. mistral: VIBE_ACTIVE_MODEL in the env prefix, before spool-harness" "SPT_NOENV=1 VIBE_ACTIVE_MODEL='large' bash '$T_SCRIPTS/spool-harness.sh'" "$(line "$out")"
hasnt "7. ... never a --model flag" "--model" "$(line "$out")"
printf 'env:\n  box:\n    agent_model:\n      default: { mistral: "" }\n' > "$T_TMP/cnf.yaml"
out="$(env RESTORE_PRINT=1 MISTRAL_BIN="$B/vibe" SPOOL_MISTRAL_MAX_PRICE=3.50 bash "$T_SCRIPTS/restore-mistral.sh" m-950 "$RD" - 2>&1)"
hasnt "7. ... emptied: no VIBE_ACTIVE_MODEL" "VIBE_ACTIVE_MODEL" "$(line "$out")"

# --- 8 -----------------------------------------------------------------------------
# A real restore exec-s the CLI, so the case calls the core's own _rs_model and
# _rs_write_model, the pair restore_main runs before the exec.
wm() {  # KIND ID [ENV...] -> lifetime/model.txt
  local k="$1" id="$2"; shift 2
  env RESTORE_KIND="$k" CLAUDE_BIN="$B/claude" "$@" bash -c '. "$1/restore-core.inc.sh" && _rs_model "$2" 2>/dev/null && _rs_write_model "$2"' _ "$T_SCRIPTS" "$id"
  cat "$SPOOL_ROOT/$id/lifetime/model.txt" 2>/dev/null || echo MISSING
}
cnf opus
eq "8. model.txt records the model the restore started on, not the spawn's sonnet" opus "$(wm claude c-950)"
cnf ""
eq "8. ... emptied: cli-default" cli-default "$(wm claude c-950)"
cnf haiku
eq "8. ... refused by the live list: cli-default" cli-default "$(wm claude c-950)"
eq "8. ... qwen has no model words: cli-default, never the unpassed name" cli-default "$(wm qwen q-950 SPAWN_MODEL=qwen3-coder)"
rm -rf "$SPOOL_ROOT/c-951"
cnf opus
eq "8. ... written when lifetime/ does not exist yet" opus "$(wm claude c-951)"

t_done
