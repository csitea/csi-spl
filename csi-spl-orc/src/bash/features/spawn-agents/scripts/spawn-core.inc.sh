#!/usr/bin/env bash
# spawn-core.inc.sh — the ONE agent launcher behind spawn-claude.sh,
# spawn-grok.sh, spawn-agy.sh, spawn-qwen.sh and spawn-mistral.sh.
#
# Forked from the box engine's launcher core and adapted to the spool specs
# (csi-spl-doc specs 002 / 004, contracts/trust-modes.md,
# doc/md/SPEC-spool-identity-routing.md):
#
#   - the message root is $SPOOL_ROOT (default /var/spool-hub): the agent's
#     dirs are $SPOOL_ROOT/<ID>/{inbox,outbox,archive} and it is on the roster
#     because that dir exists (trust-modes §4). The registry of spawns
#     (id, kind, pane, rundir, spawned-utc, requester) is $SPOOL_ROOT/registry.tsv.
#     The requester is last, so a reader of columns 1-5 is unchanged. "-" is a
#     shell with no agent id. spawn-window.sh gates who may spawn; a direct
#     launcher call gates here before any directory is created.
#   - TITLE is a spool agent id (c-004, or the legacy CLE-07: specs/061),
#     never a BOX- prefix, and its letter / prefix must name the adapter's kind.
#   - the seed prompt teaches the SPOOL protocol instead of the markdown inbox:
#     `spool recv --as <ID>` to read, `spool-send.sh` (spool send + tmux poke)
#     to write, v:1 objects, unsigned in local mode.
#   - no key and no pin at spawn: local mode is unsigned (trust-modes §2); hub
#     mode keys are per BOX, minted once, never per agent.
#
# Kept unchanged from the reference because it is box-level, not spec-level:
# the tmux visibility rule (windows go DETACHED into the box user's
# attached session; spawn-window.sh), the per-agent git worktree off
# origin/<trunk>, the scope / integration / leak-gate seed blocks, run-as-agent
# and the `exec bash` fall-through that keeps a finished window visible.
#
# AN ADAPTER SETS, then calls `spawn_main "$@"`:
#   SPAWN_ADAPTER        "${BASH_SOURCE[0]}" of the adapter
#   SPAWN_KIND           claude | grok | agy | qwen | mistral
#   SPAWN_ID_PREFIX      CLE | GRK | AGY | QWN, or "" for a kind with no legacy
#                        prefix (mistral, specs/110 3.1): the pane env name is
#                        then the kind's (MISTRAL_TMUX_PANE) and the title is
#                        checked by SPAWN_ID_LETTER alone
#   SPAWN_ID_LETTER      the id letter (m); read only when SPAWN_ID_PREFIX is ""
#   SPAWN_BIN_VAR        CLAUDE_BIN | GROK_BIN | AGY_BIN | QWEN_BIN | MISTRAL_BIN (resolved by spool-env)
#   SPAWN_NAME_FLAG      the flag that names the session, or ""
#   SPAWN_PROMPT_FLAG    the flag before the seed prompt, or "" (positional)
#   SPAWN_RESUME_FLAG    SPAWN_RESUME_ID   how the CLI resumes one session
#   SPAWN_CONTINUE_FLAG  how it resumes the most recent one in a directory
#   spawn_rename_how     function: the instruction that makes the agent
#                        retitle itself (may use $TITLE and $_SP_DIR)
# and MAY set (unset = nothing added, so the other launch lines stay byte-identical):
#   SPAWN_EXEC_PREFIX    words before the CLI: in the launch, before spool-harness
#                        (so the harness still sees the CLI as its command), and
#                        in the resume stub (mistral: env -u MISTRAL_API_KEY ...)
#   SPAWN_EXTRA_FLAGS    flags after the permission flags (mistral: --max-price N)
#
# DRY RUN: SPAWN_DRY_RUN=1 performs NO side effect and prints the plan: one
# `PLAN <step> …` line per side effect, then the seed prompt between
# PROMPT-BEGIN / PROMPT-END. With SPAWN_PLAN_DIR set it also writes the exact
# launch command (launch.cmd) and prompt (prompt.txt) there.
#
# Usage (through an adapter): spawn-<kind>.sh <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]
#   BRIEF_FILE  task brief the seed prompt points at; omit for a plain session
#   SLUG        short work description; the branch is "<TITLE>-<slug>"
#
# ISOLATION: when WORKDIR is inside a git repo with an `origin`, the session
# gets its OWN worktree at "<repo>-wt/<TITLE>" on a branch off origin/<trunk>;
# the shared checkout is touched only by fetch, a clean fast-forward and
# `worktree add`. Otherwise the session runs in WORKDIR itself (no git
# closing steps in the prompt).

_sp_live() { [ "${SPAWN_DRY_RUN:-0}" != 1 ]; }
_sp_plan() { _sp_live || printf 'PLAN %-10s %s\n' "$1" "$2"; }

# A live window stays open on its error so a human can read it; a dry run
# fails like any other command.
_sp_fail() {
  echo "ERROR: $*" >&2
  if _sp_live; then exec bash; fi
  exit 1
}

# The checkout WORKDIR belongs to; inside a linked worktree, its MAIN checkout
# (the do_spl_dispatch_setup rule): one "<repo>-wt/<TITLE>" per id. A rotation
# restarts a dispatcher from its own worktree, and the toplevel of that made
# "<wt>-wt/<TITLE>": a fresh worktree without the settings setup wrote.
_spawn_main_checkout() {
  local top common
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 0
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  case "$common" in */.git) [ -d "${common%/.git}" ] && top="${common%/.git}" ;; esac
  echo "$top"
}

# RUNDIR REPO BRANCH WORKTREE_DIR DEFBRANCH, creating the worktree when live.
_spawn_worktree() {
  local rv n cand main_br main_dirty safe_slug
  RUNDIR="$WORKDIR"
  REPO=""; BRANCH=""; WORKTREE_DIR=""; DEFBRANCH="master"

  REPO="$(_spawn_main_checkout "$WORKDIR")"
  if [ -z "$REPO" ] || ! git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    REPO=""
    _sp_plan worktree "none: ${WORKDIR} is not a git checkout with an origin; the session runs in it"
    return 0
  fi
  DEFBRANCH="$(git -C "$REPO" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  DEFBRANCH="${DEFBRANCH#origin/}"
  [ -n "$DEFBRANCH" ] || DEFBRANCH="master"

  # Keep the MAIN source in sync with trunk: fetch always, fast-forward only
  # when it is on trunk and clean. NEVER switch/reset it, never a merge commit.
  # git-fetch-fresh.sh: skipped when origin/<trunk> was fetched < 60 s ago.
  _sp_live && bash "${_SP_DIR}/git-fetch-fresh.sh" -C "$REPO" --branch "$DEFBRANCH" >/dev/null 2>&1
  _sp_plan fetch "git-fetch-fresh.sh -C ${REPO} --branch ${DEFBRANCH}"
  main_br="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  main_dirty="$(git -C "$REPO" status --porcelain 2>/dev/null)"
  if [ "$main_br" = "$DEFBRANCH" ] && [ -z "$main_dirty" ]; then
    if _sp_live; then
      git -C "$REPO" merge --ff-only "origin/${DEFBRANCH}" >/dev/null 2>&1 \
        && echo "INFO: main source ${REPO} fast-forwarded to origin/${DEFBRANCH}" \
        || echo "WARN: main source ${REPO} would not fast-forward - left untouched" >&2
    fi
    _sp_plan main-ff "git -C ${REPO} merge --ff-only origin/${DEFBRANCH}"
  else
    _sp_plan main-ff "none: ${REPO} is on '${main_br:-?}' or has local changes"
  fi

  WORKTREE_DIR="${REPO}-wt/${TITLE}"
  if [ -d "$WORKTREE_DIR" ]; then
    BRANCH="$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ -n "$BRANCH" ] || BRANCH="$TITLE"
    RUNDIR="$WORKTREE_DIR"
    if _sp_live; then
      echo "INFO: reusing existing worktree ${WORKTREE_DIR}"
      bash "${_SP_DIR}/install-pre-push-hook.sh" "$WORKTREE_DIR" >/dev/null 2>&1 || true
    fi
    _sp_plan worktree "reuse ${WORKTREE_DIR} (branch ${BRANCH})"
    return 0
  fi

  safe_slug="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr ' _/' '---' | tr -cd 'a-z0-9-')"
  safe_slug="$(printf '%s' "$safe_slug" | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  if [ -n "$safe_slug" ]; then BRANCH="${TITLE}-${safe_slug}"; else BRANCH="$TITLE"; fi
  cand="$BRANCH"; n=1
  while git -C "$REPO" show-ref --verify --quiet "refs/heads/${cand}"; do
    n=$((n + 1)); cand="${BRANCH}-${n}"
  done
  BRANCH="$cand"

  if _sp_live; then
    mkdir -p "$(dirname "$WORKTREE_DIR")" || _sp_fail "mkdir -p $(dirname "$WORKTREE_DIR") FAILED"
    git -C "$REPO" worktree add -b "$BRANCH" "$WORKTREE_DIR" "origin/${DEFBRANCH}"; rv=$?
    [ $rv -eq 0 ] || _sp_fail "git worktree add FAILED (rv=$rv)"
    # The agent user gets the same r-x it has on the shared repo; its writes
    # route through `sudo -u $SPOOL_BOX_USER`. Non-fatal.
    if [ "$SPOOL_AGENT_USER" != "$SPOOL_BOX_USER" ] && command -v setfacl >/dev/null 2>&1; then
      setfacl -R -m "u:${SPOOL_AGENT_USER}:rX" -m "d:u:${SPOOL_AGENT_USER}:rX" "$WORKTREE_DIR" 2>/dev/null
    fi
    echo "INFO: created worktree ${WORKTREE_DIR} on branch ${BRANCH} off origin/${DEFBRANCH}"
    # SPL-1252: install the deploy-gate pre-push hook for THIS worktree only
    # (worktree-local core.hooksPath). Non-fatal: a spawn must not fail for it.
    bash "${_SP_DIR}/install-pre-push-hook.sh" "$WORKTREE_DIR" >/dev/null 2>&1 \
      || echo "WARN: pre-push hook not installed for ${WORKTREE_DIR} (non-fatal)"
  fi
  _sp_plan worktree "add ${WORKTREE_DIR} -b ${BRANCH} origin/${DEFBRANCH}"
  _sp_plan pre-push-hook "install-pre-push-hook.sh ${WORKTREE_DIR}"
  RUNDIR="$WORKTREE_DIR"
}

# The agent's row in the fleet-wide lane map (CLE-77920, specs/058 N2):
# <TITLE>@<box>, repo, branch, scope, files, topic, state live. Best effort and
# in the background: a spawn never waits on, or fails for, the hub. Without a
# fleet configured it is a logged no-op. SPAWN_LANE_SCOPE (default the
# brief's first heading, else SLUG), SPAWN_LANE_FILES (comma-separated paths)
# and SPAWN_LANE_TOPIC fill the row.
_spawn_lane_put() {
  local scope="${SPAWN_LANE_SCOPE:-}" repo="" log
  if [ -z "$scope" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
    scope="$(grep -m1 -E '^#+ ' "$BRIEF" 2>/dev/null | sed -E 's/^#+ +//; s/^Brief: *//')"
  fi
  scope="${scope:-$SLUG}"
  [ -n "$REPO" ] && repo="$(basename "$REPO")"
  _sp_plan lane "lane-map.sh put --agent ${TITLE} --repo ${repo:-<none>} --branch ${BRANCH:-<none>} --scope '${scope}' --files '${SPAWN_LANE_FILES:-}' --topic '${SPAWN_LANE_TOPIC:-}'"
  _sp_live || return 0
  log="${SPOOL_ROOT}/${TITLE}/lane.log"
  ( timeout 60 bash "${_SP_DIR}/lane-map.sh" put --agent "$TITLE" --repo "$repo" --branch "$BRANCH" \
      --scope "$scope" --files "${SPAWN_LANE_FILES:-}" --topic "${SPAWN_LANE_TOPIC:-}" >"$log" 2>&1 & ) 2>/dev/null
}

# SCOPE INTEGRATION SPOOL_PROTO — the seed-prompt blocks every kind receives.
_spawn_seed_blocks() {
SCOPE=""; INTEGRATION=""; DEPLOY_GATE=""
if [ -n "$WORKTREE_DIR" ]; then
  # The rules only; why each one exists, with its measurements, is the doc
  # below (owner token plan, practice 02: a seed states rules, not history).
  _sp_rules_doc="${SPAWN_SCRIPTS_DIR%/csi-spl-orc/src/bash/features/spawn-agents/scripts}/csi-spl-doc/doc/md/lane-integration-rules.md"
  [ -d "${REPO}/csi-spl-doc" ] && _sp_rules_doc="csi-spl-doc/doc/md/lane-integration-rules.md"
  # git fetch origin <trunk>, skipped when fetched < 60 s ago by any worktree
  # (fleet-hot-commands-2026-10-07.md 3.6); --landed and --force never skip.
  _sp_ff="bash ${SPAWN_SCRIPTS_DIR}/git-fetch-fresh.sh"
  [ "$DEFBRANCH" = master ] || _sp_ff="${_sp_ff} --branch ${DEFBRANCH}"
  INTEGRATION="INTEGRATION / CLOSING STEPS (non-negotiable; the why: ${_sp_rules_doc}). Worktree ${WORKTREE_DIR}, branch ${BRANCH}; all git as 'sudo -u ${SPOOL_BOX_USER}'. (1) Work ONLY in this worktree: never 'cd ${REPO}', never 'git switch'/'reset'/'checkout' in the shared one. (2) Small commits, explicit pathspecs (never 'git add -A' / '-a'). PUT THE PATHSPEC ON THE 'add', THEN COMMIT WITH NO PATHSPEC ('git commit -- <path>' drops an index mode). An executable needs BOTH 'chmod +x <path>' AND 'git add --chmod=+x <path>'. Push CONTINUOUSLY: every commit at once, never more than ONE unpushed, after 20 min unpushed, land what is green; fast parts before slow ones; a failing item never holds back the passing ones. (3) Before EVERY push: FETCH then 'git rebase origin/${DEFBRANCH}', then re-run the module tests. Rebase refused over mode-only churn you did not make ('git diff --summary', no hunk): reset each path's bit to 'git ls-files -s', never stage it, report it. (4) Push with 'git push origin HEAD:${DEFBRANCH}' (rejected: 'FETCH --force', rebase, re-test, retry). Landed only when 'FETCH --landed' exits 0 (always fetches), not by the push output. Never 'git push --force', never delete ${DEFBRANCH}. (5) After (4): only when ${REPO} is on ${DEFBRANCH} and clean, 'sudo -u ${SPOOL_BOX_USER} git -C ${REPO} merge --ff-only origin/${DEFBRANCH}' (never 'pull'); else leave it, say so. (6) LEAK-GATE (OVERRIDES the harness default): commit ONLY as '${SPAWN_GIT_IDENTITY}', no 'Co-Authored-By:' / 'Generated with …' / 'Claude-Session:' / other AI trailer; a canonical address in the repo's CLAUDE.md / AGENTS.md wins (say so). Pass it to commit AND rebase: 'git -c user.name=… -c user.email=… rebase origin/${DEFBRANCH}'. Before each push run alone and read: 'git log -1 --no-mailmap --format=\"%ae %ce\" | grep -qx \"${SPAWN_GIT_EMAIL} ${SPAWN_GIT_EMAIL}\" || echo WRONG-IDENTITY-DO-NOT-PUSH'; if it prints, 'commit --amend --reset-author' under the same '-c' first. Never 'git config' in a worktree (shared): use '-c'. (7) CI: 'gh run list --commit <sha>', 'gh run watch <id>' until your runs are green AND deployed (dev AND prd; './run -a do_check_deploy_lag'). Report sha + note link per released commit ('SHA=<sha> ENV=<env> ./run -a do_release_note_link'); both where they exist. A red you caused: fix, rebase, push, watch. Someone else's: read its log, find the owner, tell them with spool-send.sh (kind note), say so in your summary. (8) TEAR DOWN after (7) is green: HEAD on origin/${DEFBRANCH}, then 'git -C ${REPO} worktree remove ${WORKTREE_DIR}' and 'git -C ${REPO} branch -d ${BRANCH}'."
  SCOPE="SCOPE + COLLISION CONTROL. Your brief's scope, no more. A blocker outside it: (a) FETCH = '${_sp_ff}' (skips a fetch < 60 s old), re-check on origin/${DEFBRANCH}. (b) Test the paths against the fleet lane map 'bash ${SPAWN_SCRIPTS_DIR}/lane-map.sh' - every live agent on EVERY machine - with '--check <path,...> --agent ${TITLE}' (exit 3 names the owning lane). Fixed or owned: report it, do not fix it. (c) Only if it blocks YOUR tests and nobody owns it: fix it in a SEPARATE narrow commit. (d) FETCH again during long work."
  DEPLOY_GATE="DEPLOY-GATE (SPL-1250; detail: repo CLAUDE.md). (a) 'cd csi-spl-iac && ./run -a do_check_pre_push' before EVERY push and AGAIN after the mandatory rebase; lint only: './run -a do_check_pre_push_lint'; missing scanner: './run -a do_install_lint_tools'. The pre-push hook enforces it; emergency bypass only: 'SPL_PREPUSH_OVERRIDE=1 git push …', and tell ${SPOOL_ORCHESTRATOR_ID}. After the push also check 'gh run list --commit <sha>': 61..67 and 85: a scanner red on your sha is your red. (b) Store/hub/auth tests must run on POSTGRES: a store/migration change runs 'PRE_PUSH_TIER=full ./run -a do_check_pre_push'. (c) No literal domain or host: read BASE_DOMAIN / the cnf. (d) INTEGRATION (3) and (6), every push. (e) NEVER run 'do_spl_desk_up' or any prd mutation your safety check REFUSES: send ${SPOOL_ORCHESTRATOR_ID} the exact command and wait."
fi

# The spool protocol (spec 002 cli.md + trust-modes §2). The file is the
# record; the tmux poke is only the doorbell.
# SPAWN_ORC_DIR: the orc module the invoked scripts dir sits in (lease show).
SPAWN_ORC_DIR="${SPAWN_SCRIPTS_DIR%/src/bash/features/spawn-agents/scripts}"
# A lane reports to the seat that spawned it, as <requester>@<box> (spec 101
# R3); decisions and prd stay with the orchestrator. No requester ("-", a
# human shell): every report goes to the orchestrator, as before.
_sp_report="Report questions, blockers, status and your final summary to the orchestrator with spool-send.sh --to orchestrator (kind result for the final summary, note otherwise)"
if [ -n "${SPAWN_REQUESTER:-}" ] && [ "$SPAWN_REQUESTER" != "-" ]; then
  _sp_report="Report status, blockers and your final summary to your spawner: spool-send.sh --to $(spool_decorate "$SPAWN_REQUESTER") (kind result for the final summary, else note); decisions and prd go --to orchestrator"
fi
SPOOL_PROTO="THE SPOOL MESSAGING PROTOCOL (how the orchestrator and your peers talk to you). Your spool agent id is ${TITLE}; the spool root is ${SPOOL_ROOT} and your dirs are ${MSGDIR}/{inbox,outbox,archive}. Messages are v:1 JSON objects (fields v, msg_id, task_id, ts, from, to, kind, body, files; kind is one of task|result|note|reject|blocker|msg; local mode is UNSIGNED - there is no sig and you never generate or handle a key). The spool binary is ${SPOOL_BIN}; always run it with SPOOL_ROOT=${SPOOL_ROOT} in its environment. READ: 'SPOOL_ROOT=${SPOOL_ROOT} ${SPOOL_BIN} recv --as ${TITLE}' prints your inbox as a JSON array; add '--ack' once you have acted on them to move them to archive/. A topic is a task_id: 'SPOOL_ROOT=${SPOOL_ROOT} ${SPOOL_BIN} tail --task <task_id>' shows it oldest-first across every agent. SEND: 'bash ${SPAWN_SCRIPTS_DIR}/spool-send.sh --from ${TITLE} --to <PEER-ID> --kind <task|result|note|reject|blocker|msg> [--task <task_id>] --body \"<text>\"' - it runs spool send (writing the v:1 object into the peer's inbox and a copy into your outbox), prints {delivery, msg_id, task_id, ts}, then rings the peer's tmux window with a short shell-inert poke line. Reply on the SAME --task as the message you answer, so the topic stays one task_id. The terminal only ever shows a poke line (': 'SPOOL ${TITLE}: ...''); the poke is a doorbell, the spool FILE is the message - when poked, at natural breakpoints, and before declaring yourself done, run spool recv. ${_sp_report}: it resolves to whoever holds the fleet lease's orch role, on this machine or another (today ${SPOOL_ORCHESTRATOR_ID} here), and a peer id on another machine is relayed through the hub. OWNER TEXT (a post meant for the owner, e.g. in a t1 topic) goes to whoever holds the dispatch lease RIGHT NOW, read with 'cd ${SPAWN_ORC_DIR} && sudo -u ${SPOOL_BOX_USER} env SPOOL_ROOT=${SPOOL_ROOT} LEASE_CMD=show ./run -a do_spl_dispatch_lease' (prints '<ID>@<box> <age-seconds>'), never to a fixed dispatcher id and never to the dispatcher that last posted in that topic. Every agent on this box has a dir under ${SPOOL_ROOT} and a row in ${SPOOL_ROOT}/registry.tsv (id, kind, tmux-pane, rundir, spawned-utc, requester). Message peers ONLY for your task, blocker handoffs and scope collisions, never open-ended chatter; never type message payloads into tmux windows. HOW TO WRITE A POST: a longer body uses markdown (headers, bold, lists, GFM pipe tables with one row per line) and needs no \`\`\`md fence; the one rule is csi-spl-doc/doc/help/how-to-post.md."
}

# One registry.tsv row. The requester is last so columns 1-5 stay put.
spawn_registry_line() {  # TITLE KIND PANE RUNDIR STAMP REQUESTER
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

spawn_main() {
  TITLE="${1:-}"; WORKDIR="${2:-}"; BRIEF="${3:-}"; SLUG="${4:-}"
  local _sp_cli _sp_idl _sp_name_args="" _sp_prompt_args="" _sp_shown

  # A test sandbox (tests/lib.inc.sh t_sandbox) never launches a real agent:
  # without SPAWN_DRY_RUN=1 it is refused before any side effect (2026-10-01,
  # a debug run without the flag created a stray worktree + spool dir).
  if [ "${SPAWN_TEST_SANDBOX:-0}" = 1 ] && _sp_live; then
    echo "ERROR: spawn refused: SPAWN_TEST_SANDBOX=1 without SPAWN_DRY_RUN=1 (a test must never launch a real agent)" >&2
    exit 3
  fi

  # SPAWN_SCRIPTS_DIR: where the adapter was INVOKED from (what the prompt
  # quotes). _SP_DIR: its real directory, where the helpers are.
  SPAWN_SCRIPTS_DIR="$(cd "$(dirname "$SPAWN_ADAPTER")" && pwd)"
  _SP_DIR="$(cd "$(dirname "$(readlink -f "$SPAWN_ADAPTER")")" && pwd)"

  # shellcheck source=../lib/spool-env.inc.sh
  . "${_SP_DIR}/../lib/spool-env.inc.sh" || _sp_fail "cannot load ${_SP_DIR}/../lib/spool-env.inc.sh"
  spool_env_resolve
  SPAWN_BIN="${!SPAWN_BIN_VAR}"
  # The permission flags come from the ONE helper (060 FR-061), never the adapter.
  SPAWN_PERM_FLAGS="$(spool_claude_perm_flags "$SPAWN_KIND")" || _sp_fail "no permission flags for ${SPAWN_KIND}"
  # The <P>_TMUX_PANE / _SOCK env names, and how a title of this kind looks.
  # A kind with no legacy prefix (specs/110 3.1) names them after itself.
  _sp_pane_env="${SPAWN_ID_PREFIX:-$(printf '%s' "$SPAWN_KIND" | tr '[:lower:]' '[:upper:]')}"
  _sp_id_eg="${SPAWN_ID_PREFIX}-07" _sp_id_mark="prefix ${SPAWN_ID_PREFIX}-"
  [ -n "${SPAWN_ID_PREFIX:-}" ] || { _sp_id_eg="${SPAWN_ID_LETTER}-004"; _sp_id_mark="letter ${SPAWN_ID_LETTER}-"; }

  # Guard: TITLE is the agent's spool id. An empty or garbled one would
  # collapse WORKTREE_DIR to "<repo>-wt/" and MSGDIR to the spool root itself.
  spool_valid_id "$TITLE" 2>/dev/null \
    || _sp_fail "invalid session TITLE '${TITLE}' — expected a spool agent id like ${_sp_id_eg} (${SPOOL_ID_RE}, never BOX-)."
  [ "$(spl_kind_of_agent_id "$TITLE")" = "$SPAWN_KIND" ] \
    || _sp_fail "TITLE '${TITLE}' does not carry the ${SPAWN_KIND} ${_sp_id_mark}"
  [ -n "$WORKDIR" ] || _sp_fail "usage: ${SPAWN_ADAPTER##*/} <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]"

  # spawn-window already resolved the caller and passed it in. A direct
  # launcher call resolves and refuses a lane here, before a spool dir or a
  # worktree exists. "-" is a shell with no agent id.
  if [ -z "${SPAWN_REQUESTER:-}" ]; then
    SPAWN_REQUESTER="$(spool_spawn_gate)" || exit $?
  fi

  _sp_plan adapter "kind=${SPAWN_KIND} prefix=${SPAWN_ID_PREFIX:-<none>} bin=${SPAWN_BIN} name-flag=${SPAWN_NAME_FLAG:-<none>} prompt-flag=${SPAWN_PROMPT_FLAG:-<positional>} resume=${SPAWN_RESUME_FLAG} <${SPAWN_RESUME_ID}> continue=${SPAWN_CONTINUE_FLAG} perm=${SPAWN_PERM_FLAGS}${SPAWN_EXTRA_FLAGS:+ extra=${SPAWN_EXTRA_FLAGS}}${SPAWN_EXEC_PREFIX:+ exec-prefix=${SPAWN_EXEC_PREFIX}}"
  _sp_plan run-as "$(spool_agent_cmd_text) (SPOOL_RUN_AS_AGENT=${SPOOL_RUN_AS_AGENT})"
  _sp_plan spool "SPOOL_ROOT=${SPOOL_ROOT} SPOOL_BIN=${SPOOL_BIN}"

  # The identity the target repo already has, never a placeholder: a
  # placeholder author breaks blame and attribution for good.
  if [ -z "${SPAWN_GIT_IDENTITY:-}" ]; then
    _bgi_n="$(git -C "$WORKDIR" config user.name  2>/dev/null || true)"
    _bgi_e="$(git -C "$WORKDIR" config user.email 2>/dev/null || true)"
    if [ -n "$_bgi_n" ] && [ -n "$_bgi_e" ]; then
      SPAWN_GIT_IDENTITY="$_bgi_n <$_bgi_e>"
    else
      SPAWN_GIT_IDENTITY="the identity already configured in this repository (do NOT override it)"
    fi
    unset _bgi_n _bgi_e
  fi
  SPAWN_GIT_EMAIL="$(printf '%s' "$SPAWN_GIT_IDENTITY" | sed -n 's/.*<\(.*\)>.*/\1/p')"

  # $TITLE is the id (dirs, worktree, branch); $DISPLAY_NAME is what a human
  # reads in the tmux bar.
  DISPLAY_NAME="$(spool_decorate "$TITLE")"

  # The agent's spool dirs. next-agent-id.sh normally claimed them already;
  # creating them again is idempotent (0775, local-folder-layout.md).
  MSGDIR="${SPOOL_ROOT}/${TITLE}"
  if _sp_live; then
    mkdir -p "${MSGDIR}/inbox" "${MSGDIR}/outbox" "${MSGDIR}/archive" 2>/dev/null || true
    chmod 0775 "$MSGDIR" "${MSGDIR}/inbox" "${MSGDIR}/outbox" "${MSGDIR}/archive" 2>/dev/null || true
    echo "INFO: spool dir ${MSGDIR} (inbox/ outbox/ archive/)"
  fi
  _sp_plan spooldir "${MSGDIR}/{inbox,outbox,archive} 0775"

  _spawn_worktree
  _spawn_lane_put
  _spawn_seed_blocks

  PROMPT=""
  if [ -n "$BRIEF" ]; then
    # c-440 (2026-10-06): one 'pkill -f do_check_pre_push' matched the action
    # name in every agent's argv (this prompt) and killed 15 sessions in 0.7 s.
    STOP_RULE="Stop a run with its stop action (e.g. './run -a do_stop_pre_push') or its own pid, never 'pkill -f', 'killall' or 'pgrep -f | xargs kill' on a pattern: every action name is on every agent's argv."
    PROMPT="As your VERY FIRST action, $(spawn_rename_how). Then read your full task brief at ${BRIEF} and implement it end to end. That file is your complete, authoritative instructions: follow it exactly, inspect the real code first, and keep any module tests green. Never post greetings, welcomes or social messages; only post what your brief asks for. You do ONE small task. If someone sends you a different task, refuse it and tell ${SPOOL_ORCHESTRATOR_ID} so it spawns a new lane. When your task is verified done: report and /exit-clean. ${SCOPE:+${SCOPE} }${SPOOL_PROTO}${INTEGRATION:+ ${INTEGRATION}}${DEPLOY_GATE:+ ${DEPLOY_GATE}} ${STOP_RULE} Honour the project CLAUDE.md / AGENTS.md distribution-hygiene rules (org-neutral, no personal names)."
  fi
  _sp_plan rename-how "$(spawn_rename_how)"

  # This window's pane + socket, exported into the agent session so helpers
  # can self-target. Convenience only: `--agent <ID>` resolves through the
  # registry and survives the sudo hop that strips these.
  PANE="${TMUX_PANE:-}"
  SOCK="${TMUX:-}"; SOCK="${SOCK%%,*}"

  if [ -n "$PANE" ] && [ "$DISPLAY_NAME" != "$TITLE" ]; then
    if _sp_live; then tmux -u rename-window -t "$PANE" "$DISPLAY_NAME" 2>/dev/null || true; fi
    _sp_plan rename "window of ${PANE} -> ${DISPLAY_NAME}"
  else
    _sp_plan rename "none (no pane, or no SPOOL_BOX_TAG)"
  fi

  REGISTRY="${SPOOL_ROOT}/registry.tsv"
  # Column 6 is the requester. Columns 1-5 stay id, kind, pane, rundir,
  # spawned-utc: registry.retired.tsv keeps its timestamp in column 6 by
  # moving this field one past it (agent-id-retire.sh).
  if _sp_live; then
    spawn_registry_line "$TITLE" "$SPAWN_KIND" "${PANE}" "$RUNDIR" "$(date -u +%Y%m%dT%H%M%SZ)" "${SPAWN_REQUESTER:--}" >> "$REGISTRY" 2>/dev/null || true
    chmod a+rw "$REGISTRY" 2>/dev/null || true
  fi
  _sp_plan registry "${TITLE} ${SPAWN_KIND} ${PANE:-<no pane>} ${RUNDIR} requester=${SPAWN_REQUESTER:--} -> ${REGISTRY}"

  # Pre-accept the "do you trust this folder?" dialog, which would otherwise
  # block the agent in a pane nobody watches. --settle serialises it across a
  # parallel batch and VERIFIES it before the launch (a starting claude
  # rewrites ~/.claude.json unlocked and dropped a sibling's entry: 2 of 8
  # spawns stuck on the prompt, 2026-10-01). Unverified -> loud stop, never a
  # silently blocked pane.
  if _sp_live; then
    bash "${_SP_DIR}/trust-workdir.sh" --settle "$RUNDIR" "$SPOOL_AGENT_USER" "$SPAWN_KIND"
    _sp_trc=$?
    [ "$_sp_trc" -eq 3 ] && _sp_fail "trust for ${RUNDIR} did not verify -- ${SPAWN_KIND} would stop on its trust prompt"
  fi
  _sp_plan trust "trust-workdir.sh --settle ${RUNDIR} ${SPOOL_AGENT_USER} ${SPAWN_KIND}"

  _sp_cli="${SPAWN_BIN##*/}"
  _sp_idl="${SPAWN_RESUME_ID,,}"; _sp_idl="${_sp_idl//_/ }"
  # The resume stub carries the same permission flags as the launch. A grok
  # resumed without them falls back to whatever config.toml says; claude's
  # own restore in the box engine repeats its own permission mode (auto for claude).
  RESTORE="$(spool_agent_cmd_text) -c 'cd \"${RUNDIR}\" ; ${SPAWN_EXEC_PREFIX:+${SPAWN_EXEC_PREFIX} }${_sp_cli} ${SPAWN_PERM_FLAGS}${SPAWN_EXTRA_FLAGS:+ ${SPAWN_EXTRA_FLAGS}} ${SPAWN_RESUME_FLAG} "
  _sp_plan restore "${RESTORE}<${SPAWN_RESUME_ID}>'"

  # PROMPT travels inside a double-quoted argument of the agent's login shell,
  # where " \ $ and ` are live: spool_dq_escape keeps every byte.
  [ -n "${SPAWN_NAME_FLAG:-}" ] && _sp_name_args="${SPAWN_NAME_FLAG} '${DISPLAY_NAME}' "
  PROMPT_ESC=""
  if [ -n "$PROMPT" ]; then
    spool_dq_escape PROMPT_ESC "$PROMPT"
    _sp_prompt_args=" ${SPAWN_PROMPT_FLAG:+${SPAWN_PROMPT_FLAG} }\"${PROMPT_ESC}\""
  fi
  # specs/012 T013: the CLI starts THROUGH spool-harness (dirs, identity,
  # sidecar in hub mode, SPOOL_* env, and with --mirror the terminal mirror
  # hooks of specs/036), not with the env prepared inline here.
  LAUNCH="export ${_sp_pane_env}_TMUX_PANE='${PANE}' ${_sp_pane_env}_TMUX_SOCK='${SOCK}' SPOOL_ROOT='${SPOOL_ROOT}' SPOOL_AGENT_ID='${TITLE}' ${SPOOL_CLI_ENV}; cd '${RUNDIR}' && exec ${SPAWN_EXEC_PREFIX:+${SPAWN_EXEC_PREFIX} }bash '${SPAWN_SCRIPTS_DIR}/spool-harness.sh' --as '${TITLE}' --mirror -- '${SPAWN_BIN}' ${_sp_name_args}${SPAWN_PERM_FLAGS}${SPAWN_EXTRA_FLAGS:+ ${SPAWN_EXTRA_FLAGS}}${_sp_prompt_args}"

  if ! _sp_live; then
    _sp_shown="$LAUNCH"
    [ -n "$PROMPT_ESC" ] && _sp_shown="${LAUNCH/"$PROMPT_ESC"/<PROMPT>}"
    _sp_plan launch "$(spool_agent_cmd_text) -c \"${_sp_shown}\""
    if [ -n "${SPAWN_PLAN_DIR:-}" ]; then
      printf '%s' "$LAUNCH" > "${SPAWN_PLAN_DIR}/launch.cmd"
      printf '%s' "$PROMPT" > "${SPAWN_PLAN_DIR}/prompt.txt"
    fi
    printf 'PROMPT-BEGIN\n%s\nPROMPT-END\n' "$PROMPT"
    return 0
  fi

  history -s "${RESTORE}" 2>/dev/null || true
  cd "$RUNDIR" || _sp_fail "cd '$RUNDIR' FAILED"
  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " ${TITLE} — launching ${SPAWN_KIND} as ${SPOOL_AGENT_USER} in ${RUNDIR}"
  echo " spool: ${MSGDIR}  (SPOOL_ROOT=${SPOOL_ROOT})"
  echo " Restore stub (append the ${_sp_idl}):"
  echo "   ${RESTORE}<${SPAWN_RESUME_ID}>'"
  echo "════════════════════════════════════════════════════════════════════"
  echo
  spool_agent_exec "$LAUNCH"

  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " ${SPAWN_KIND} session '${TITLE}' ended. Pane kept open so the window stays"
  echo " visible. Press Ctrl-b & to close this window, or scroll back to read."
  echo " Spool dir: ${MSGDIR} (inbox/ outbox/ archive/)"
  echo " To RESUME: ${RESTORE}<${SPAWN_RESUME_ID}>'"
  echo " Or the most recent session in this dir:"
  echo "   $(spool_agent_cmd_text) -c 'cd \"${RUNDIR}\" ; ${SPAWN_EXEC_PREFIX:+${SPAWN_EXEC_PREFIX} }${_sp_cli} ${SPAWN_CONTINUE_FLAG}'"
  if [ -n "$WORKTREE_DIR" ]; then
    echo " Worktree: ${WORKTREE_DIR}  Branch: ${BRANCH} (off origin/${DEFBRANCH})"
    echo " Tear down when merged: git -C '${REPO}' worktree remove '${WORKTREE_DIR}'"
  fi
  echo "════════════════════════════════════════════════════════════════════"
  HIST_TARGET="${HISTFILE:-$HOME/.bash_history}"
  [ -n "$HIST_TARGET" ] && printf '%s\n' "${RESTORE}" >>"$HIST_TARGET" 2>/dev/null
  exec bash
}
