#!/usr/bin/env bash
# spawn-codex.sh — invoked as a tmux window's command: runs the OpenAI Codex CLI (codex) as
# the agent user, in its own worktree (or WORKDIR), from a task brief, speaking the spool.
#
# The codex ADAPTER of the launcher core, spawn-core.inc.sh (spec 161 4.1 item
# 3, letter o: owner msg 4ae81b56). A twin of spawn-mistral.sh.
#
# OFF UNTIL THE OWNER'S LOGIN IS ON THE BOX (owner HUM-10 msg 9c70e4f7,
# 2026-11-03: "build install + launcher, it stays off until your subscription
# key is on the box"): before anything else this adapter asks
# spool_codex_ready, which wants the codex CLI AND the login marker
# (spool_codex_auth_marker, cnf env.box.agent_split.auth_marker.codex) for the
# agent user. Without both it prints one REFUSED line and exits 13 (the
# spawn-window code for "this box has no <kind> CLI"): no worktree, no spool
# dir, no pane. spawn-window.sh asks the same before it claims an id.
#
# Authentication is NOT the launcher's business: codex reads the subscription
# login do_install_openai_codex set up (~/.codex/auth.json). The launch runs
# under `env -u OPENAI_API_KEY -u CODEX_API_KEY`: an exported API key would
# silently swap the subscription for a metered account (spec 161 2.2.5).
#
# The flags, from the Codex CLI reference (developers.openai.com/codex/cli/
# reference, read 2026-11-03; not yet run against a live binary on any box):
#   - --dangerously-bypass-approvals-and-sandbox: "Run every command without
#     approvals or sandboxing" - the fleet's one permission mode, from
#     spool_claude_perm_flags (spec 161 v1.1 named --ask-for-approval never,
#     which still sandboxes the shell);
#   - a positional PROMPT starts the TUI with the prompt sent, so the seed
#     pointer is positional;
#   - `codex resume <SESSION_ID>` / `codex resume --last` resume a session;
#   - -c <key>=<value> overrides one config.toml key for this run:
#     analytics.enabled=false turns telemetry off and
#     check_for_update_on_startup=false the update check (config reference,
#     developers.openai.com/codex/config-reference), without touching the
#     agent user's config.toml. DISABLE_AUTOUPDATER=1 rides along as for
#     every kind (spool-env).
#   - codex loads AGENTS.md, never CLAUDE.md, so the first action reads it.
#
# Usage: spawn-codex.sh <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]
#   TITLE is a spool agent id with the letter o, e.g. o-004 (no legacy prefix).
#   SPAWN_DRY_RUN=1 prints the plan instead of launching.
# shellcheck disable=SC2034  # the SPAWN_* declarations are read by spawn-core.inc.sh
set -uo pipefail
SPAWN_ADAPTER="${BASH_SOURCE[0]}"
SPAWN_KIND=codex
SPAWN_ID_PREFIX=
SPAWN_ID_LETTER=o
SPAWN_BIN_VAR=CODEX_BIN
# codex cannot NAME a session, so the tmux window alone carries the name.
SPAWN_NAME_FLAG=
SPAWN_PROMPT_FLAG=
SPAWN_RESUME_FLAG=resume
SPAWN_RESUME_ID=SESSION_ID
SPAWN_CONTINUE_FLAG="resume --last"
# rwX: with approvals bypassed codex writes the worktree through its own
# apply_patch tool, which needs write access (spec 161 4.1; spawn-mistral.sh
# records what a read-only seat did instead: shell writes that ate quoting).
SPAWN_AGENT_ACL=rwX
SPAWN_EXEC_PREFIX="env -u OPENAI_API_KEY -u CODEX_API_KEY"
SPAWN_EXTRA_FLAGS="-c analytics.enabled=false -c check_for_update_on_startup=false"
spawn_rename_how() {
  # $SLUG is embedded already escaped for a double-quoted argument, so the
  # agent copy-pastes a command that cannot run $(...) from the title.
  local desc_esc
  spool_dq_escape desc_esc "${SLUG:-}"
  printf '%s' "retitle your tmux window to the shortest description of your task (2-5 words): run bash ${_SP_DIR}/riname.sh --agent ${TITLE} \"${desc_esc}\" (codex cannot name its session); then read the workdir's CLAUDE.md, if it has one, and csi-spl-doc/doc/help/how-to-post.md; stay in your own lane (Всяка жаба да си знае гьола): your brief only, a finding outside it goes to the orchestrator, never fix it yourself"
}
_sp_core="$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/spawn-core.inc.sh"
# shellcheck source=spawn-core.inc.sh
. "$_sp_core" || { echo "ERROR: cannot load $_sp_core" >&2; exec env HISTSIZE=-1 HISTFILESIZE=-1 BASHOPTS=histappend bash --norc; }

# The off switch (head): CODEX_BIN and the login, as the agent user, first.
# shellcheck source=../lib/spool-env.inc.sh
. "$(dirname "$(readlink -f "$SPAWN_ADAPTER")")/../lib/spool-env.inc.sh" || exit 1
spool_env_resolve
spool_codex_ready "${1:-}" || exit 13
spawn_main "$@"
