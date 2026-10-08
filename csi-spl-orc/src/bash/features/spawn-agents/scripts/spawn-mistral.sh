#!/usr/bin/env bash
# spawn-mistral.sh — invoked as a tmux window's command: runs the Mistral Vibe CLI (vibe) as
# the agent user, in its own worktree (or WORKDIR), from a task brief, speaking the spool.
#
# The mistral ADAPTER of the launcher core, spawn-core.inc.sh: this file declares
# only what is mistral-specific (specs/110 3.3). A twin of spawn-qwen.sh.
#
# Authentication is NOT the launcher's business: vibe reads its key from the
# agent user's own <home>/.vibe/.env, set once by do_set_mistral_key. No key
# ever travels on this command line, where ps would show it, and the launch
# runs under `env -u MISTRAL_API_KEY`: an exported MISTRAL_API_KEY beats the
# .env file, so a stray export would silently swap the account (spec 2.3).
#
# Measured on vibe 2.26.0 (spec 2.1 / 2.5, T005):
#   - a positional PROMPT starts the TUI with the prompt sent and keeps it up,
#     so the seed is positional (no flag);
#   - vibe loads a trusted project's AGENTS.md, never its CLAUDE.md (the
#     project rules here), so the first action reads CLAUDE.md and the post rule;
#   - --max-price is enforced in programmatic mode (-p) only: in this
#     interactive seat it is the cnf value for the record, the console spend
#     limit is the cap that holds;
#   - VIBE_<FIELD> overrides any config.toml field, so the launch turns off
#     telemetry (+ Sentry), the update check / prompt and the experiments
#     fetch without touching the agent user's config.toml. The model is
#     config.toml's active_model (install pins it; a hand-set one is kept).
#
# Usage: spawn-mistral.sh <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]
#   TITLE is a spool agent id with the letter m, e.g. m-004 (no legacy prefix).
#   SPAWN_DRY_RUN=1 prints the plan instead of launching.
#   SPOOL_MISTRAL_MAX_PRICE overrides cnf env.box.mistral_vibe.max_price.
# shellcheck disable=SC2034  # the SPAWN_* declarations are read by spawn-core.inc.sh
set -uo pipefail
SPAWN_ADAPTER="${BASH_SOURCE[0]}"
SPAWN_KIND=mistral
SPAWN_ID_PREFIX=
SPAWN_ID_LETTER=m
SPAWN_BIN_VAR=MISTRAL_BIN
# vibe cannot NAME a session, so the tmux window alone carries the name.
SPAWN_NAME_FLAG=
SPAWN_PROMPT_FLAG=
SPAWN_RESUME_FLAG=--resume
SPAWN_RESUME_ID=SESSION_ID
SPAWN_CONTINUE_FLAG=--continue
# SPT_NOENV=1: vibe renames itself "Vibe CLI" with setproctitle, which by default
# zeroes /proc/<pid>/environ, so SPOOL_AGENT_ID vanished and the agent run
# report (spl_lease_live_ids) never listed an m- lane: roster running = f.
SPAWN_EXEC_PREFIX="env -u MISTRAL_API_KEY VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false VIBE_EXPERIMENTS__ENABLE=false SPT_NOENV=1"
spawn_rename_how() {
  # $SLUG is embedded already escaped for a double-quoted argument, so the
  # agent copy-pastes a command that cannot run $(...) from the title.
  local desc_esc
  spool_dq_escape desc_esc "${SLUG:-}"
  printf '%s' "retitle your tmux window to the shortest possible description of the work you are about to implement (2-5 words) by running: bash ${_SP_DIR}/riname.sh --agent ${TITLE} \"${desc_esc}\" (vibe cannot name its own session, so the window name is the one a human reads); then read the workdir's CLAUDE.md, if it has one, and csi-spl-doc/doc/help/how-to-post.md: vibe loads only AGENTS.md, so CLAUDE.md's rules (commit identity, explicit pathspecs, ./run actions, the pre-push gate, hygiene) reach you only this way"
}
_sp_core="$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/spawn-core.inc.sh"
# shellcheck source=spawn-core.inc.sh
. "$_sp_core" || { echo "ERROR: cannot load $_sp_core" >&2; exec bash; }

# env.box.mistral_vibe.max_price of this checkout's cnf (the awk of
# spool-install's cnf_mistral), else empty.
_sp_cnf_max_price() {
  local cnf
  cnf="$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/../../../../../../csi-spl-cnf/csi-spl/all.env.yaml"
  [ -r "$cnf" ] || return 0
  awk '
    /^[[:space:]]*mistral_vibe:[[:space:]]*$/ { match($0, /^[[:space:]]*/); ind = RLENGTH; on = 1; next }
    on { match($0, /^[[:space:]]*/); if (RLENGTH <= ind && $0 ~ /[^[:space:]]/) exit }
    on && /^[[:space:]]*max_price:/ { sub(/^[[:space:]]*max_price:[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, ""); gsub(/["'\'']/, ""); print; exit }
  ' "$cnf"
}
_sp_max_price="${SPOOL_MISTRAL_MAX_PRICE:-$(_sp_cnf_max_price)}"
[[ "$_sp_max_price" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  || _sp_fail "no cost cap: cnf env.box.mistral_vibe.max_price (or SPOOL_MISTRAL_MAX_PRICE) must be a dollar amount, got '${_sp_max_price}' (specs/110 2.5)"
SPAWN_EXTRA_FLAGS="--max-price ${_sp_max_price}"
spawn_main "$@"
