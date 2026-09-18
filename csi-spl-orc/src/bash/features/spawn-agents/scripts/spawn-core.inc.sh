#!/usr/bin/env bash
# spawn-core.inc.sh — the ONE agent launcher behind spawn-claude.sh,
# spawn-grok.sh and spawn-agy.sh.
#
# Forked from the box engine's launcher core and adapted to the spool specs
# (csi-spl-doc specs 002 / 004, contracts/trust-modes.md,
# doc/md/SPEC-spool-identity-routing.md):
#
#   - the message root is $SPOOL_ROOT (default /var/spool-hub): the agent's
#     dirs are $SPOOL_ROOT/<ID>/{inbox,outbox,archive} and it is on the roster
#     because that dir exists (trust-modes §4). The registry of spawns
#     (id, kind, pane, rundir, spawned-utc) is $SPOOL_ROOT/registry.tsv.
#   - TITLE is a spool agent id: ^[A-Z]{2,4}-[0-9]+$, never a BOX- prefix,
#     and it must match the adapter's own prefix.
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
#   SPAWN_KIND           claude | grok | agy
#   SPAWN_ID_PREFIX      CLE | GRK | AGY
#   SPAWN_BIN_VAR        CLAUDE_BIN | GROK_BIN | AGY_BIN (resolved by spool-env)
#   SPAWN_NAME_FLAG      the flag that names the session, or ""
#   SPAWN_PROMPT_FLAG    the flag before the seed prompt, or "" (positional)
#   SPAWN_PERM_FLAGS     permission / autonomy flags
#   SPAWN_RESUME_FLAG    SPAWN_RESUME_ID   how the CLI resumes one session
#   SPAWN_CONTINUE_FLAG  how it resumes the most recent one in a directory
#   spawn_rename_how     function: the instruction that makes the agent
#                        retitle itself (may use $TITLE and $_SP_DIR)
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

# RUNDIR REPO BRANCH WORKTREE_DIR DEFBRANCH, creating the worktree when live.
_spawn_worktree() {
  local rv n cand main_br main_dirty safe_slug
  RUNDIR="$WORKDIR"
  REPO=""; BRANCH=""; WORKTREE_DIR=""; DEFBRANCH="master"

  REPO="$(git -C "$WORKDIR" rev-parse --show-toplevel 2>/dev/null)"
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
  _sp_live && git -C "$REPO" fetch origin "$DEFBRANCH" >/dev/null 2>&1
  _sp_plan fetch "git -C ${REPO} fetch origin ${DEFBRANCH}"
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
    _sp_live && echo "INFO: reusing existing worktree ${WORKTREE_DIR}"
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
  fi
  _sp_plan worktree "add ${WORKTREE_DIR} -b ${BRANCH} origin/${DEFBRANCH}"
  RUNDIR="$WORKTREE_DIR"
}

# SCOPE INTEGRATION SPOOL_PROTO — the seed-prompt blocks every kind receives.
_spawn_seed_blocks() {
SCOPE=""; INTEGRATION=""
if [ -n "$WORKTREE_DIR" ]; then
  INTEGRATION="INTEGRATION / CLOSING STEPS (non-negotiable). You are working in your OWN git worktree at ${WORKTREE_DIR}, on branch ${BRANCH}, created off origin/${DEFBRANCH}. (1) Work ONLY inside this worktree; NEVER 'cd ${REPO}', and NEVER run 'git switch'/'reset'/'checkout' against the shared tree. (2) Commit your work on ${BRANCH} in small increments, staging explicit pathspecs (never 'git add -A' / '-a'), running all git as the box user ('sudo -u ${SPOOL_BOX_USER}'). PUT THE PATHSPEC ON THE `add`, THEN COMMIT WITH NO PATHSPEC: 'git commit -- <path>' is a PARTIAL COMMIT - it re-reads those paths from the WORKTREE and commits that, discarding an index mode set by 'git add --chmod=+x'. Measured on this box 2026-09-12: index 100755 after the add, COMMITTED 100644, with and without core.fileMode=false. And to make a file executable do BOTH: 'chmod +x <path>' on disk AND 'git add --chmod=+x <path>' in the index. NEITHER ALONE IS ENOUGH. A bare 'chmod +x' with NO PENDING EDIT to that file is mode-only churn by definition - worktree bit set, index 100644, no content delta - so a repair tool clears it; that is the COMMON shape, an existing script that should have been executable all along. (A bare chmod on a path whose edit is STAGED is the safe sub-case: the tool cannot tell it from churn either, so it refuses and names it instead of guessing.); and '--chmod=+x' alone leaves the worktree bit unset, which git reports as an UNSTAGED 'mode change 100755 => 100644' - that is an unstaged change, so it blocks the next rebase, and a churn detector reads it as churn (measured 2026-09-12: worktree 664, index 100755, 'git diff --summary' -> mode change, detector exit 3). With the bit in both places the two agree and nothing reports anything. COMMIT AND PUSH CONTINUOUSLY (this is a hard rule, not advice, and it OVERRIDES any instinct to deliver one clean atomic change at the end). Pushing is CONTINUOUS: every commit is rebased and pushed to trunk immediately after it is made. There is no such thing as a final push. You must NEVER hold more than ONE unpushed commit, and never hold a finished, tested change while you go on to work on something else. If more than 20 minutes have passed since your last push, STOP whatever you are doing, land everything that is green as its own commit, push it, and only then continue. THE EXACT SCENARIO THIS EXISTS TO PREVENT: you are given several related changes, some fast (manifest, prompt, config, docs, scripts, tests) and some slow (image generation, rendering, uploads, large builds, batch API calls that get rate limited). You finish the fast ones in minutes, then hold them uncommitted for an hour while the slow one grinds, so the owner sees NOTHING land, trunk moves dozens of commits under you, and the rebase becomes unresolvable. That is a defect, every time. The fast changes go in FIRST, as their own commit, pushed BEFORE the slow artefact exists - they stand on their own, they cannot break what they do not touch, and they are usually the part the owner is actually waiting to read. Then the slow part lands as a second commit when it is ready. The same applies to review and verification: if you are checking N items and item 3 fails, push the other N-1 and report the one you are still working - a failing item is never a reason to withhold the passing ones. Re-fetch trunk on this same cadence, not only at integration time. (3) REBASE ONTO TRUNK BEFORE EVERY PUSH — the first push and every retry alike, no exceptions: 'git fetch origin ${DEFBRANCH}' then 'git rebase origin/${DEFBRANCH}'; resolve any conflicts, then RE-RUN the module tests — a rebased result is untested code. IF THE REBASE REFUSES WITH 'cannot rebase: You have unstaged changes' AND YOU DID NOT LEAVE THAT DIRT, it is probably the fleet's MODE-ONLY CHURN, not your work: something outside your lane moves the OWNER EXECUTE BIT on tracked files, which is the one mode bit git records, and 158 paths went that way on 2026-09-12 with ZERO content changed. Check rather than guess: 'git diff --summary' lists 'mode change' lines, and mode-only churn is a path that appears there with NO content hunk in 'git diff'. Repair YOUR OWN worktree by setting each such path's worktree bit back to what the index records ('git ls-files -s <path>': 100755 -> chmod +x, 100644 -> chmod -x), re-run the rebase, and NEVER stage those paths - staging one lands a spurious '100644 => 100755' next to your change and nothing warns you. Do not hunt the writer: report it in your summary and carry on. Never run 'git push' unless the immediately preceding commands were that fetch + rebase onto origin/${DEFBRANCH}. (4) INTEGRATE to trunk and push, with the race-retry loop (others may have pushed while you worked): after the rebase your branch tip sits directly on top of origin/${DEFBRANCH}, so push it onto trunk as a pure fast-forward with 'git push origin HEAD:${DEFBRANCH}' (this keeps trunk LINEAR and never checks out the trunk branch in the shared tree). If the push is REJECTED as non-fast-forward, run 'git fetch origin ${DEFBRANCH}; git rebase origin/${DEFBRANCH}', RE-TEST, then push again. DECIDE WHETHER IT LANDED FROM THE REPOSITORY STATE, NEVER FROM THE PUSH OUTPUT: a REJECTED push ALSO prints 'HEAD -> ${DEFBRANCH}' - the full line is '! [rejected] HEAD -> ${DEFBRANCH} (fetch first)' - so a retry loop that greps the output for that string reports success for a push that never landed. Measured on this box on 2026-09-12: two shas were reported PUSHED and published as on trunk, and were not there. After every push, ask the repository: 'git fetch origin ${DEFBRANCH}' then 'git merge-base --is-ancestor HEAD origin/${DEFBRANCH}' and read its EXIT CODE - 0 means your work is genuinely on trunk, non-zero means the push did not land whatever it printed. That is the same check step (8) requires before teardown, so running it here costs nothing and turns a silent non-push into an immediate retry. NEVER 'git push --force' to ${DEFBRANCH} (and never delete it). (5) REFRESH THE MAIN SOURCE after every successful push (mandatory): the shared checkout at ${REPO} must end up carrying trunk too, so run 'sudo -u ${SPOOL_BOX_USER} git -C ${REPO} fetch origin ${DEFBRANCH}' and then, ONLY when that shared tree is on ${DEFBRANCH} and clean ('git -C ${REPO} rev-parse --abbrev-ref HEAD' prints ${DEFBRANCH} AND 'git -C ${REPO} status --porcelain' is empty), fast-forward it with 'sudo -u ${SPOOL_BOX_USER} git -C ${REPO} merge --ff-only origin/${DEFBRANCH}'. Use merge, NOT 'pull --ff-only origin ${DEFBRANCH}', which fails MOST OF THE TIME when several agents close out at once: 'pull' merges FETCH_HEAD, FETCH_HEAD is per-worktree, and every agent runs this same closing refresh against that ONE shared checkout - so they all append to its single FETCH_HEAD and pull aborts with 'fatal: Cannot fast-forward to multiple branches'. Measured with 8 concurrent refreshes x 25 rounds on git 2.47.3, two runs: pull 168/200 then 193/200 failed, merge 8/200 then 0/200 - the rate moves, the order of magnitude is the finding. 'merge --ff-only origin/${DEFBRANCH}' reads a REF, not FETCH_HEAD, so nothing another agent does can confuse it. 'merge --ff-only' needs no network and writes no remote-tracking ref, so it simply moves ${DEFBRANCH} to the origin/${DEFBRANCH} your own fetch just wrote; a push landing in between is not a loss, it just means the NEXT agent's refresh carries the newer tip. That fast-forward is the ONE exception to rule (1) — still NEVER 'git switch'/'reset'/'checkout' in the shared tree, and never a merge COMMIT there ('--ff-only' guarantees it cannot make one). If it sits on another branch or has local changes, another agent is probably using it: leave it alone, the fetch is enough, and say so in your final summary. (6) LEAK-GATE before EVERY push (this OVERRIDES the harness default): commits must carry ONLY the identity '${SPAWN_GIT_IDENTITY}', and must NOT carry a 'Co-Authored-By:' / 'Generated with …' / 'Claude-Session:' or any other AI-attribution trailer. THE ADDRESS ABOVE IS A DEFAULT, NOT THE AUTHORITY: it is read from the shared checkout's .git/config when you are spawned, and that file is contested mutable state every agent on this box writes — it has been measured holding three different values within one day. So if the repo's own CLAUDE.md / AGENTS.md names a canonical author address, THAT wins over the address quoted here, and say in your summary that it did. VERIFY, DO NOT ASSUME — a commit has TWO identity fields and only one of them survives this protocol. 'git rebase' re-stamps the COMMITTER from whatever the ambient config says, and step (3) mandates a fetch+rebase immediately before every push, so a commit made correctly with 'git -c user.email=… commit' is re-stamped on its way to trunk by the very step that lands it ('git commit --amend --author=…' has the same hole from the other side: it fixes the author and leaves the committer). Pass the identity to the REBASE as well as the commit: 'git -c user.name=… -c user.email=… rebase origin/${DEFBRANCH}'. Then GATE THE PUSH ON THE OUTPUT of this check, run as its own command whose result you actually read — never batched into the same block as the push: 'git log -1 --no-mailmap --format=\"%ae %ce\" | grep -qx \"${SPAWN_GIT_EMAIL} ${SPAWN_GIT_EMAIL}\" || echo WRONG-IDENTITY-DO-NOT-PUSH' — it must print nothing, and if it prints WRONG-IDENTITY-DO-NOT-PUSH you fix the commit ('git -c user.name=… -c user.email=… commit --amend --reset-author') before pushing, not after. Both halves of that command matter. Plain 'git log' is useless here — a root .mailmap maps the old addresses onto the canonical one, so a wrong commit renders as correct and the mapping hides exactly the thing you need to look at; '--no-mailmap' is the control. And '%ae' alone reports green on a field it never read, which is how commits reading author=canonical, committer=stale reach trunk unnoticed. Finally, do NOT set the identity with 'git config --local' from your worktree: where extensions.worktreeConfig is unset every worktree shares one common .git/config, so that silently changes the identity for the shared checkout and for every other agent too. Use per-command '-c', or 'git config --worktree' after explicitly enabling that extension. THAT SHARING IS NOT SPECIFIC TO THE IDENTITY - it is every setting. 'git config core.fileMode false' from a worktree disables fileMode for the shared checkout and every other lane (measured on this box: 'git config --get extensions.worktreeConfig' is empty, and 'rev-parse --git-common-dir' from a worktree points at the shared .git). If you need core.fileMode=false at all, pass it as '-c' on the single 'git add' that needs it - on the 'commit' it is worse than useless, because a partial commit re-reads the WORKTREE and the flag makes git ignore the very bit it would have read (measured 2026-09-12: index 100755 after 'git add --chmod=+x', COMMITTED 100644). (7) CI AND EVERY ENVIRONMENT (mandatory, do NOT /exit or tear down while this is red): after the push, watch GitHub Actions on THAT sha until the runs your change can affect are green - use 'gh run list --commit <sha>' then 'gh run watch <id>' (GH_TOKEN comes from disk). Where the pipeline deploys per environment, green is not the finish line: the change is not done until it has DEPLOYED to every environment that pipeline targets (typically dev AND prd), so confirm the deploy jobs for both, and where the project provides a deployed-state check (for example './run -a do_check_deploy_lag' with your sha) run it and require it to report current rather than trusting the run colour - a run can read cancelled while your commit ships later riding somebody else's deploy. The project CLAUDE.md / AGENTS.md names the exact workflows for that repo; read it rather than guessing. A red run is never something you walk past. It is YOURS when the failure names a module you touched, OR when your commit introduced it - including when your change made a dormant assertion fire for the first time in a file you never opened: fix it in THIS worktree, fetch, rebase, push, watch again. When it is plainly someone else's - it names a module outside your scope and the same failure is already on the sha before yours - you are still NOT finished: open the failing log before deciding whose it is ('my module is not named' is a judgement about a failure you have not read, not a verdict you can reach from the run's colour), identify the owner ('git worktree list' and 'git branch --list' name every live agent and the scope its branch carries), tell them with spool-send.sh (kind note), and say in your summary that you did. Never leave trunk red in silence and never assume a sibling agent will babysit your sha - reporting it to a named owner is the discharge, noticing it and moving on is not. (8) TEAR DOWN only after step (7) is green for a commit that actually contains your work: confirm HEAD is on origin/${DEFBRANCH}, then 'git -C ${REPO} worktree remove ${WORKTREE_DIR}' and 'git -C ${REPO} branch -d ${BRANCH}'. Leaving a merged worktree behind in <repo>-wt/ is a defect - it clutters 'git worktree list', which is the map every other agent reads to see who owns what. Never remove a sibling agent's worktree and never delete ${DEFBRANCH}."
  SCOPE="SCOPE + COLLISION CONTROL (you are ONE of several agents working this repo in parallel, each in its own worktree off the same trunk). Implement the scope in your brief - that and no more. When you hit a blocker OUTSIDE it (a broken build, a red unrelated workflow, another module's bug, stale docs elsewhere), do NOT fix it reflexively. (a) FIRST 'git fetch origin ${DEFBRANCH}' and re-check the symptom against origin/${DEFBRANCH}: trunk moves under you constantly and very often already carries someone else's fix. (b) THEN run 'git -C ${REPO} worktree list' and 'git -C ${REPO} branch --list' - every other live agent appears there and its branch name carries its scope (e.g. CLE-21-051-order-metrics-api), so you can see who owns the area. If trunk already fixes it, or a branch name says another agent owns it, REPORT it in your final summary and move on. Duplicated work is wasted tokens plus a rebase conflict for someone - it is NOT harmless, and 'I fixed it too' is a mess-up, not a bonus. When ownership is unclear, prefer reporting over fixing. (c) ONLY if the blocker genuinely blocks YOUR OWN tests AND nobody else owns it, fix it - in a SEPARATE commit with a narrow pathspec, so it drops cleanly if it turns out to be redundant. (d) Re-fetch trunk periodically during long work, not only at integration time."
fi

# The spool protocol (spec 002 cli.md + trust-modes §2). The file is the
# record; the tmux poke is only the doorbell.
SPOOL_PROTO="THE SPOOL MESSAGING PROTOCOL (how the orchestrator and your peers talk to you). Your spool agent id is ${TITLE}; the spool root is ${SPOOL_ROOT} and your dirs are ${MSGDIR}/{inbox,outbox,archive}. Messages are v:1 JSON objects (fields v, msg_id, task_id, ts, from, to, kind, body, files; kind is one of task|result|note|reject; local mode is UNSIGNED - there is no sig and you never generate or handle a key). The spool binary is ${SPOOL_BIN}; always run it with SPOOL_ROOT=${SPOOL_ROOT} in its environment. READ: 'SPOOL_ROOT=${SPOOL_ROOT} ${SPOOL_BIN} recv --as ${TITLE}' prints your inbox as a JSON array; add '--ack' once you have acted on them to move them to archive/. A thread is a task_id: 'SPOOL_ROOT=${SPOOL_ROOT} ${SPOOL_BIN} tail --task <task_id>' shows it oldest-first across every agent. SEND: 'bash ${SPAWN_SCRIPTS_DIR}/spool-send.sh --from ${TITLE} --to <PEER-ID> --kind <task|result|note|reject> [--task <task_id>] --body \"<text>\"' - it runs spool send (writing the v:1 object into the peer's inbox and a copy into your outbox), prints {delivery, msg_id, task_id, ts}, then rings the peer's tmux window with a short shell-inert poke line. Reply on the SAME --task as the message you answer, so the thread stays one task_id. The terminal only ever shows a poke line (': 'SPOOL ${TITLE}: ...''); the poke is a doorbell, the spool FILE is the message - when poked, at natural breakpoints, and before declaring yourself done, run spool recv. Report questions, blockers, status and your final summary to the orchestrator ${SPOOL_ORCHESTRATOR_ID} with spool-send.sh (kind result for the final summary, note otherwise). Every agent on this box has a dir under ${SPOOL_ROOT} and a row in ${SPOOL_ROOT}/registry.tsv (id, kind, tmux-pane, rundir, spawned-utc). Message peers ONLY for your task, blocker handoffs and scope collisions, never open-ended chatter; never type message payloads into tmux windows."
}

spawn_main() {
  TITLE="${1:-}"; WORKDIR="${2:-}"; BRIEF="${3:-}"; SLUG="${4:-}"
  local _sp_cli _sp_idl _sp_name_args="" _sp_prompt_args="" _sp_shown

  # SPAWN_SCRIPTS_DIR: where the adapter was INVOKED from (what the prompt
  # quotes). _SP_DIR: its real directory, where the helpers are.
  SPAWN_SCRIPTS_DIR="$(cd "$(dirname "$SPAWN_ADAPTER")" && pwd)"
  _SP_DIR="$(cd "$(dirname "$(readlink -f "$SPAWN_ADAPTER")")" && pwd)"

  # shellcheck source=../lib/spool-env.inc.sh
  . "${_SP_DIR}/../lib/spool-env.inc.sh" || _sp_fail "cannot load ${_SP_DIR}/../lib/spool-env.inc.sh"
  spool_env_resolve
  SPAWN_BIN="${!SPAWN_BIN_VAR}"

  # Guard: TITLE is the agent's spool id. An empty or garbled one would
  # collapse WORKTREE_DIR to "<repo>-wt/" and MSGDIR to the spool root itself.
  spool_valid_id "$TITLE" 2>/dev/null \
    || _sp_fail "invalid session TITLE '${TITLE}' — expected a spool agent id like ${SPAWN_ID_PREFIX}-07 (^[A-Z]{2,4}-[0-9]+\$, never BOX-)."
  [ "${TITLE%%-*}" = "$SPAWN_ID_PREFIX" ] \
    || _sp_fail "TITLE '${TITLE}' does not carry the ${SPAWN_KIND} prefix ${SPAWN_ID_PREFIX}-"
  [ -n "$WORKDIR" ] || _sp_fail "usage: ${SPAWN_ADAPTER##*/} <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]"

  _sp_plan adapter "kind=${SPAWN_KIND} prefix=${SPAWN_ID_PREFIX} bin=${SPAWN_BIN} name-flag=${SPAWN_NAME_FLAG:-<none>} prompt-flag=${SPAWN_PROMPT_FLAG:-<positional>} resume=${SPAWN_RESUME_FLAG} <${SPAWN_RESUME_ID}> continue=${SPAWN_CONTINUE_FLAG} perm=${SPAWN_PERM_FLAGS}"
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
  _spawn_seed_blocks

  PROMPT=""
  if [ -n "$BRIEF" ]; then
    PROMPT="As your VERY FIRST action, $(spawn_rename_how). Then read your full task brief at ${BRIEF} and implement it end to end. That file is your complete, authoritative instructions: follow it exactly, inspect the real code first, and keep any module tests green. ${SCOPE:+${SCOPE} }${SPOOL_PROTO}${INTEGRATION:+ ${INTEGRATION}} Honour the project CLAUDE.md / AGENTS.md distribution-hygiene rules (org-neutral, no personal names)."
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
  if _sp_live; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$TITLE" "$SPAWN_KIND" "${PANE}" "$RUNDIR" "$(date -u +%Y%m%dT%H%M%SZ)" >> "$REGISTRY" 2>/dev/null || true
    chmod a+rw "$REGISTRY" 2>/dev/null || true
  fi
  _sp_plan registry "${TITLE} ${SPAWN_KIND} ${PANE:-<no pane>} ${RUNDIR} -> ${REGISTRY}"

  # Pre-accept the "do you trust this folder?" dialog, which would otherwise
  # block the agent in a pane nobody watches. Never fatal.
  if _sp_live; then bash "${_SP_DIR}/trust-workdir.sh" "$RUNDIR" "$SPOOL_AGENT_USER" "$SPAWN_KIND" || true; fi
  _sp_plan trust "trust-workdir.sh ${RUNDIR} ${SPOOL_AGENT_USER} ${SPAWN_KIND}"

  _sp_cli="${SPAWN_BIN##*/}"
  _sp_idl="${SPAWN_RESUME_ID,,}"; _sp_idl="${_sp_idl//_/ }"
  RESTORE="$(spool_agent_cmd_text) -c 'cd \"${RUNDIR}\" ; ${_sp_cli} ${SPAWN_RESUME_FLAG} "
  _sp_plan restore "${RESTORE}<${SPAWN_RESUME_ID}>'"

  # PROMPT travels inside a double-quoted argument of the agent's login shell,
  # where " \ $ and ` are live: spool_dq_escape keeps every byte.
  [ -n "${SPAWN_NAME_FLAG:-}" ] && _sp_name_args="${SPAWN_NAME_FLAG} '${DISPLAY_NAME}' "
  PROMPT_ESC=""
  if [ -n "$PROMPT" ]; then
    spool_dq_escape PROMPT_ESC "$PROMPT"
    _sp_prompt_args=" ${SPAWN_PROMPT_FLAG:+${SPAWN_PROMPT_FLAG} }\"${PROMPT_ESC}\""
  fi
  LAUNCH="export ${SPAWN_ID_PREFIX}_TMUX_PANE='${PANE}' ${SPAWN_ID_PREFIX}_TMUX_SOCK='${SOCK}' SPOOL_ROOT='${SPOOL_ROOT}' SPOOL_AGENT_ID='${TITLE}'; cd '${RUNDIR}' && exec '${SPAWN_BIN}' ${_sp_name_args}${SPAWN_PERM_FLAGS}${_sp_prompt_args}"

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
  echo "   $(spool_agent_cmd_text) -c 'cd \"${RUNDIR}\" ; ${_sp_cli} ${SPAWN_CONTINUE_FLAG}'"
  if [ -n "$WORKTREE_DIR" ]; then
    echo " Worktree: ${WORKTREE_DIR}  Branch: ${BRANCH} (off origin/${DEFBRANCH})"
    echo " Tear down when merged: git -C '${REPO}' worktree remove '${WORKTREE_DIR}'"
  fi
  echo "════════════════════════════════════════════════════════════════════"
  HIST_TARGET="${HISTFILE:-$HOME/.bash_history}"
  [ -n "$HIST_TARGET" ] && printf '%s\n' "${RESTORE}" >>"$HIST_TARGET" 2>/dev/null
  exec bash
}
