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
#   SPAWN_PROMPT_FLAG    the flag before the seed pointer, or "" (positional)
#   SPAWN_RESUME_FLAG    SPAWN_RESUME_ID   how the CLI resumes one session
#   SPAWN_CONTINUE_FLAG  how it resumes the most recent one in a directory
#   spawn_rename_how     function: the instruction that makes the agent
#                        retitle itself (may use $TITLE and $_SP_DIR)
# and MAY set (unset = nothing added, so the other launch lines stay byte-identical):
#   SPAWN_EXEC_PREFIX    words before the CLI: in the launch, before spool-harness
#                        (so the harness still sees the CLI as its command), and
#                        in the resume stub (mistral: env -u MISTRAL_API_KEY ...)
#   SPAWN_EXTRA_FLAGS    flags after the permission flags (mistral: --max-price N)
#   SPAWN_UMASK          the CLI's umask (spool-harness --umask, and the restore
#                        stub), or unset for the harness's 0002 (qwen: 077)
#   spawn_teardown_how   function: closing step (8) of the seed, in place of
#                        the default "keep the worktree" (mistral: names why: vibe runs its hooks in it)
#   spawn_scope_how      function FETCH_CMD: the SCOPE block of a git lane, in place of the
#                        shared one; keeps its header and rules (a)-(d) (grok: tighter)
#   spawn_seed_note      function: the kind's own block, rendered after SCOPE as
#                        "HARNESS NOTE (<kind>): <text>", one sentence (grok: brevity)
#   SPAWN_AGENT_ACL      the agent user's ACL on its own worktree, default rX
#                        (its writes route through `sudo -u <box user>`); mistral
#                        sets rwX: vibe's write_file / search_replace are its only
#                        quoting-safe write path (spawn-mistral.sh)
#
# DRY RUN: SPAWN_DRY_RUN=1 performs NO side effect and prints the plan: one
# `PLAN <step> …` line per side effect, then the seed prompt between
# PROMPT-BEGIN / PROMPT-END. With SPAWN_PLAN_DIR set it also writes the exact
# launch command (launch.cmd) and prompt (prompt.txt) there. The seed is never
# in argv: the CLI gets "Read and follow your seed: <file>" (_spawn_seed_file).
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
# The seed's closing line, every kind: a lane closes itself only on the
# reviewer's ACCEPTED, so a send-back still finds it running (owner HUM-10 msg
# 3b4d2cb9, "implement it in the loop"). Closing on its own done, every m- lane
# of 2026-10-10 was closed by an orchestrator (c-001 msg 0df92cb9), and c-878 /
# a-884 retired before the verdict, which then bounced (c-002 msg f711ec97).
# No self-poll while waiting: a scheduled inbox poll repeats one call and one
# result, so the watchdog S5 rule restarts the lane (m-353 2026-10-19, SPL-2608).
SPAWN_EXIT_RULE="When your task is verified done: send your result, then stay idle and answer send-backs. Run /exit-clean (the exit-clean skill) ONLY on a spool message on your task whose body starts with ACCEPTED (dispatch holder or spawner), never on your own done. While waiting, never schedule your own poll (vendor loop, /loop, cron, sleep): the spool poke wakes you."
_sp_plan() { _sp_live || printf 'PLAN %-10s %s\n' "$1" "$2"; }

# A live window stays open on its error so a human can read it; a dry run
# fails like any other command.
_sp_fail() {
  echo "ERROR: $*" >&2
  if _sp_live; then exec bash --norc; fi
  exit 1
}

# The agent user's ACL on its worktree DIR: SPAWN_AGENT_ACL (default rX, the
# r-x it has on the shared repo). Non-fatal, a no-op when the agent is the box
# user; a set SPAWN_AGENT_ACL is a plan line (an unset one keeps the plan as it was).
_sp_agent_acl() {
  local acl="${SPAWN_AGENT_ACL:-rX}"
  [ -z "${SPAWN_AGENT_ACL:-}" ] || _sp_plan acl "setfacl -R -m u:${SPOOL_AGENT_USER}:${acl} (+ default) $1"
  _sp_live || return 0
  [ "$SPOOL_AGENT_USER" != "$SPOOL_BOX_USER" ] && command -v setfacl >/dev/null 2>&1 || return 0
  setfacl -R -m "u:${SPOOL_AGENT_USER}:${acl}" -m "d:u:${SPOOL_AGENT_USER}:${acl}" "$1" 2>/dev/null
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

# DIR is a git work tree of its own, not a plain dir (nor one nested in
# some other checkout).
_spawn_is_worktree() {
  local top
  [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || return 1
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ "$(cd "$1" && pwd -P)" = "$(cd "$top" && pwd -P)" ]
}

# DIR is a worktree to reuse (SPL-2281). A retired id's dir the 24 h sweep
# left behind (only .claude/) spawned with no worktree and no branch: any dir
# that is not a work tree is moved aside, never deleted (it may hold a
# transcript), and the caller makes a fresh worktree in its place.
_spawn_reusable() {
  local stale
  [ -d "$1" ] || return 1
  _spawn_is_worktree "$1" && return 0
  stale="${1}.stale-$(date -u +%Y%m%dT%H%M%SZ)"
  _sp_plan worktree "stale ${1}: not a git work tree, move to ${stale}"
  _sp_live || return 1
  mv "$1" "$stale" || _sp_fail "mv ${1} ${stale} FAILED"
  echo "INFO: ${1} was not a git work tree - moved to ${stale}"
  return 1
}

# The reused worktree (SPL-2281) moves to the NEW lane's branch, BRANCH as
# _spawn_worktree named it, made off origin/<trunk>: its HEAD was the previous
# life's branch, and the lane map row and the seed carried that (c-770,
# c-001 msg e97c945e, 2026-10-17). The old branch and its commits stay. Kept:
# a HEAD already on this lane's branch (BRANCH or BRANCH-<n>), and a tree with
# tracked changes, which are never carried into a new lane (WARN; BRANCH is
# then the branch the tree is really on). Untracked files ride along.
# SPL-2692: a respawn of the SAME lane (SPAWN_REUSE_ID=1: a rotation with
# slug "rotate", a watchdog restart, a takeover) also keeps a branch with
# commits not on origin/<trunk>: a rotation moved c-594 off its brief branch
# and voided its pre-push gate (c-594 note 864cb54a). Counted against trunk,
# not an upstream: a lane pushes HEAD:master, its work is safe only there.
_spawn_reuse_branch() {
  local cur cand n ahead
  cur="$(git -C "$WORKTREE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$cur" ] && { [ "$cur" = "$BRANCH" ] || [[ "$cur" =~ ^${BRANCH}-[0-9]+$ ]]; }; then
    BRANCH="$cur"
    _sp_plan worktree "reuse ${WORKTREE_DIR} (branch ${BRANCH})"
    return 0
  fi
  ahead="$(git -C "$WORKTREE_DIR" rev-list --count "origin/${DEFBRANCH}..HEAD" 2>/dev/null)"
  if [ "${SPAWN_REUSE_ID:-0}" = 1 ] && [ -n "$cur" ] && [ "$cur" != HEAD ] && [ "${ahead:-0}" -gt 0 ]; then
    BRANCH="$cur"
    _sp_plan worktree "reuse ${WORKTREE_DIR} (branch ${BRANCH}, ${ahead} unpushed commits kept)"
    return 0
  fi
  if [ -n "$(git -C "$WORKTREE_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "WARN: ${WORKTREE_DIR} has tracked changes on ${cur:-?}: kept on it, not moved to ${BRANCH}" >&2
    BRANCH="${cur:-$TITLE}"
    _sp_plan worktree "reuse ${WORKTREE_DIR} (branch ${BRANCH}, tracked changes kept)"
    return 0
  fi
  cand="$BRANCH"; n=1
  while git -C "$REPO" show-ref --verify --quiet "refs/heads/${cand}"; do
    n=$((n + 1)); cand="${BRANCH}-${n}"
  done
  BRANCH="$cand"
  _sp_plan worktree "reuse ${WORKTREE_DIR} (branch ${cur:-?} -> ${BRANCH} off origin/${DEFBRANCH})"
  _sp_live || return 0
  if git -C "$WORKTREE_DIR" switch -q -c "$BRANCH" "origin/${DEFBRANCH}" 2>/dev/null; then
    echo "INFO: ${WORKTREE_DIR} moved from ${cur:-?} to ${BRANCH} off origin/${DEFBRANCH}"
  else
    echo "WARN: ${WORKTREE_DIR} would not switch to ${BRANCH}: kept on ${cur:-?}" >&2
    BRANCH="${cur:-$TITLE}"
  fi
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
  # SPL-2864: it runs in the new pane, and an https origin that wants a login
  # (a non-csi-spl seat's repo) printed "Username for ..." on the pane's tty
  # and held the launcher until the rotation's 120 s start wait failed. So:
  # never a prompt (GIT_TERMINAL_PROMPT=0), bounded (SPAWN_FETCH_TIMEOUT),
  # and a failed fetch is one WARN: the worktree starts from the last fetch.
  if _sp_live; then
    GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never timeout "${SPAWN_FETCH_TIMEOUT:-60}" \
      bash "${_SP_DIR}/git-fetch-fresh.sh" -C "$REPO" --branch "$DEFBRANCH" >/dev/null 2>&1 ||
      echo "WARN: spawn fetch: git fetch origin ${DEFBRANCH} in ${REPO} failed or timed out (exit $?, prompts off); the worktree starts from the last fetched origin/${DEFBRANCH}" >&2
  fi
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
  safe_slug="$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | tr ' _/' '---' | tr -cd 'a-z0-9-')"
  safe_slug="$(printf '%s' "$safe_slug" | sed -E 's/-+/-/g; s/^-//; s/-$//')"
  if [ -n "$safe_slug" ]; then BRANCH="${TITLE}-${safe_slug}"; else BRANCH="$TITLE"; fi
  if _spawn_reusable "$WORKTREE_DIR"; then
    _spawn_reuse_branch
    RUNDIR="$WORKTREE_DIR"
    if _sp_live; then
      echo "INFO: reusing existing worktree ${WORKTREE_DIR}"
      bash "${_SP_DIR}/install-pre-push-hook.sh" "$WORKTREE_DIR" >/dev/null 2>&1 || true
    fi
    # A respawn into a worktree made before SPAWN_AGENT_ACL gets it now.
    [ -z "${SPAWN_AGENT_ACL:-}" ] || _sp_agent_acl "$WORKTREE_DIR"
    return 0
  fi

  cand="$BRANCH"; n=1
  while git -C "$REPO" show-ref --verify --quiet "refs/heads/${cand}"; do
    n=$((n + 1)); cand="${BRANCH}-${n}"
  done
  BRANCH="$cand"

  if _sp_live; then
    mkdir -p "$(dirname "$WORKTREE_DIR")" || _sp_fail "mkdir -p $(dirname "$WORKTREE_DIR") FAILED"
    git -C "$REPO" worktree add -b "$BRANCH" "$WORKTREE_DIR" "origin/${DEFBRANCH}"; rv=$?
    [ $rv -eq 0 ] || _sp_fail "git worktree add FAILED (rv=$rv)"
    echo "INFO: created worktree ${WORKTREE_DIR} on branch ${BRANCH} off origin/${DEFBRANCH}"
    # SPL-1252: install the deploy-gate pre-push hook for THIS worktree only
    # (worktree-local core.hooksPath). Non-fatal: a spawn must not fail for it.
    bash "${_SP_DIR}/install-pre-push-hook.sh" "$WORKTREE_DIR" >/dev/null 2>&1 \
      || echo "WARN: pre-push hook not installed for ${WORKTREE_DIR} (non-fatal)"
  fi
  _sp_plan worktree "add ${WORKTREE_DIR} -b ${BRANCH} origin/${DEFBRANCH}"
  _sp_agent_acl "$WORKTREE_DIR"
  _sp_plan pre-push-hook "install-pre-push-hook.sh ${WORKTREE_DIR}"
  RUNDIR="$WORKTREE_DIR"
}

# The agent's row in the fleet-wide lane map (CLE-77920, specs/058 N2):
# <TITLE>@<box>, repo, branch, scope, files, topic, state live. Best effort and
# in the background: a spawn never waits on, or fails for, the hub. Without a
# fleet configured it is a logged no-op. SPAWN_LANE_SCOPE (default the
# brief's first heading, else SLUG), SPAWN_LANE_FILES (comma-separated paths,
# default the brief's first `Files:` line, so `--check` sees the lane's files
# from spawn on) and SPAWN_LANE_TOPIC fill the row.
# Spec 153 3.4: the topic is SPAWN_LANE_TOPIC, else LANE_ISSUE_TOPIC, else the
# brief's first HUB topic written `topic:<id>`, `topic <id>` or `/t/<id>` (a
# full uuid, or an 8-hex short id the hub resolves at put); never a bare uuid,
# which may be a spool task alias's. The issue is lifetime/issue (written
# before this put), else SPAWN_ISSUE, else the brief's `Issue:` line; a key
# the hub would refuse is left out so the row still lands.
_spawn_lane_put() {
  local scope="${SPAWN_LANE_SCOPE:-}" repo="" log
  local topic="${SPAWN_LANE_TOPIC:-${LANE_ISSUE_TOPIC:-}}" issue=""
  if [ -z "$topic" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
    topic="$(grep -oE '([Tt]opic[: ]+`?|/t/)[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?([^0-9A-Za-z-]|$)' "$BRIEF" 2>/dev/null |
      head -1 | grep -oE '[0-9a-f]{8}(-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?' | head -1)"
  fi
  if [ -n "$BRIEF" ] && . "${_SP_DIR}/../lib/lane-issue.inc.sh" 2>/dev/null; then
    issue="$(li_key_of_agent "$SPOOL_ROOT" "$TITLE")"
    [ -n "$issue" ] || issue="${SPAWN_ISSUE:-$(li_key_from_brief "$BRIEF")}"
  fi
  [[ "$issue" =~ ^[A-Z][A-Z0-9]{1,9}-[0-9]{1,9}$ ]] || issue=""
  if [ -z "$scope" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
    scope="$(grep -m1 -E '^#+ ' "$BRIEF" 2>/dev/null | sed -E 's/^#+ +//; s/^Brief: *//')"
  fi
  if [ -z "${SPAWN_LANE_FILES:-}" ] && [ -n "$BRIEF" ] && [ -r "$BRIEF" ]; then
    SPAWN_LANE_FILES="$(grep -m1 -E '^Files: *' "$BRIEF" 2>/dev/null | sed -E 's/^Files: *//' |
      tr ',' '\n' | sed -E 's/^[ `]+//; s/[ `.]+$//' | grep -v '^$' | paste -sd, -)"
  fi
  scope="${scope:-$SLUG}"
  [ -n "$REPO" ] && repo="$(basename "$REPO")"
  _sp_plan lane "lane-map.sh put --agent ${TITLE} --repo ${repo:-<none>} --branch ${BRANCH:-<none>} --scope '${scope}' --files '${SPAWN_LANE_FILES:-}' --topic '${topic}' --issue '${issue}'"
  _sp_live || return 0
  log="${SPOOL_ROOT}/${TITLE}/lane.log"
  ( timeout 60 bash "${_SP_DIR}/lane-map.sh" put --agent "$TITLE" --repo "$repo" --branch "$BRANCH" \
      --scope "$scope" --files "${SPAWN_LANE_FILES:-}" --topic "$topic" --issue "$issue" >"$log" 2>&1 & ) 2>/dev/null
}

# SCOPE INTEGRATION SPOOL_PROTO — the seed-prompt blocks every kind receives.
_spawn_seed_blocks() {
SCOPE=""; INTEGRATION=""; DEPLOY_GATE=""; DEV_GUIDE=""
# NO_FORCE: the ONE home of the never-force-push rule (fleet-rules-index.md
# section 2). Every kind's seed renders it, worktree or not; owner HUM-10
# 2026-10-10 msgs 853a4084, 9c482b22, 1cdfa5ba ("all of the other agent types
# as well"), 097f9de3 (the why), 1ca01c83 + 3e095a04 (only with the owner's
# approval of that one push, often done by hand). Guard:
# tests/test-seed-no-force-push.sh.
NO_FORCE="NO FORCE-PUSH. No agent force-pushes master (\`--force\`, \`--force-with-lease\`, \`+ref\`) without the owner's explicit approval of that one push; even then the owner decides who does it, often by hand. Ask and wait; an approval is never permission to go ahead alone. A refused push means someone landed first: fetch, rebase onto origin/${DEFBRANCH:-master}, re-test, push again; never SPL_PREPUSH_OVERRIDE it through. Owner: \"Everyone respects the work of the others. We are team and not a bunch of selfish cawboys\" (2026-10-10)."
# SEED_BOX_PKG: the ONE home of the package-install line (fleet-rules-index.md
# section 2; spec 142 row B8, owner t1 06871e35: agents keep the right to
# install, through one named action). Every kind, worktree or not.
# Guard: tests/test-seed-box-pkg.sh.
SEED_BOX_PKG="PACKAGES: install one with 'cd ${SPAWN_SCRIPTS_DIR%/csi-spl-orc/src/bash/features/spawn-agents/scripts}/csi-spl-iac && BOX_PKG=<pkg> BOX_PKG_REASON=\"<why>\" AGENT_ID=${TITLE} ./run -a do_box_pkg_install'; you keep sudo, the action records it."
if [ -n "$WORKTREE_DIR" ]; then
  # The rules only; why each one exists, with its measurements, is the doc
  # below (owner token plan, practice 02: a seed states rules, not history).
  _sp_rules_doc="${SPAWN_SCRIPTS_DIR%/csi-spl-orc/src/bash/features/spawn-agents/scripts}/csi-spl-doc/doc/md/lane-integration-rules.md"
  [ -d "${REPO}/csi-spl-doc" ] && _sp_rules_doc="csi-spl-doc/doc/md/lane-integration-rules.md"
  # git fetch origin <trunk>, skipped when fetched < 60 s ago by any worktree
  # (fleet-hot-commands-2026-10-07.md 3.6); --landed and --force never skip.
  _sp_ff="bash ${SPAWN_SCRIPTS_DIR}/git-fetch-fresh.sh"
  [ "$DEFBRANCH" = master ] || _sp_ff="${_sp_ff} --branch ${DEFBRANCH}"
  # Owner t1 37349c9b msg ec060ebc: a lane keeps its work after the push; the
  # retire lists it (workdir-register.sh), the disk sweep removes it after 24 h.
  _sp_teardown="TEAR DOWN after (7) is green: HEAD on origin/${DEFBRANCH}; KEEP ${WORKTREE_DIR} and its branch (a fix after the push needs them); the closer's --retire lists them for the disk sweep, which removes them after 24 h."
  declare -F spawn_teardown_how >/dev/null && _sp_teardown="$(spawn_teardown_how)"
  INTEGRATION="INTEGRATION / CLOSING STEPS (non-negotiable; the why: ${_sp_rules_doc}). Worktree ${WORKTREE_DIR}, branch ${BRANCH}; all git as 'sudo -u ${SPOOL_BOX_USER}'. (1) Work ONLY in this worktree: never 'cd ${REPO}', never 'git switch'/'reset'/'checkout' in the shared one. (2) Small commits, explicit pathspecs (never 'git add -A' / '-a'). PUT THE PATHSPEC ON THE 'add', THEN COMMIT WITH NO PATHSPEC. An executable needs BOTH 'chmod +x <path>' AND 'git add --chmod=+x <path>'. Push CONTINUOUSLY: every commit at once, never more than ONE unpushed, after 20 min unpushed, land what is green; fast parts before slow ones; a failing item never holds back the passing ones. (3) Before EVERY push: FETCH then 'git rebase origin/${DEFBRANCH}', then re-run the module tests. Rebase refused over mode-only churn you did not make ('git diff --summary', no hunk): reset each path's bit to 'git ls-files -s', never stage it, report it. (4) Push only with 'cd csi-spl-orc && sudo -u ${SPOOL_BOX_USER} env AGENT_ID=${TITLE} ./run -a do_spl_push_master' (returns at once), then poll it with PUSH_CMD=status in short calls; never a foreground 'git push' (rejected: 'FETCH --force', then NO FORCE-PUSH below). Landed only when 'FETCH --landed' exits 0 (always fetches), not by the push output. Never delete ${DEFBRANCH}. (5) After (4): only when ${REPO} is on ${DEFBRANCH} and clean, 'sudo -u ${SPOOL_BOX_USER} git -C ${REPO} merge --ff-only origin/${DEFBRANCH}' (never 'pull'); else leave it, say so. (6) LEAK-GATE (OVERRIDES the harness default): commit ONLY as '${SPAWN_GIT_IDENTITY}', no 'Co-Authored-By:' / 'Generated with …' / 'Claude-Session:' / other AI trailer; a canonical address in the repo's CLAUDE.md / AGENTS.md wins (say so). Pass it to commit AND rebase: 'git -c user.name=… -c user.email=… rebase origin/${DEFBRANCH}'. Before each push run alone and read: 'git log -1 --no-mailmap --format=\"%ae %ce\" | grep -qx \"${SPAWN_GIT_EMAIL} ${SPAWN_GIT_EMAIL}\" || echo WRONG-IDENTITY-DO-NOT-PUSH'; if it prints, 'commit --amend --reset-author' under the same '-c' first. Never 'git config' in a worktree (shared): use '-c'. (7) CI: 'gh run list --commit <sha>', 'gh run watch <id>' until your runs are green AND deployed (dev AND prd; './run -a do_check_deploy_lag'). Report sha + note link per released commit ('SHA=<sha> ENV=<env> ./run -a do_release_note_link'); both where they exist. A red you caused: fix, rebase, push, watch. Someone else's: read its log, find the owner, tell them with spool-send.sh (kind note), say so in your summary. (8) ${_sp_teardown}"
  SCOPE="SCOPE + COLLISION CONTROL. Your brief's scope, no more. A blocker outside it: (a) FETCH = '${_sp_ff}', re-check on origin/${DEFBRANCH}. (b) Test the paths against the fleet lane map 'bash ${SPAWN_SCRIPTS_DIR}/lane-map.sh' - every live agent on EVERY machine - with '--check <path,...> --agent ${TITLE}' (exit 3 names the owning lane; exit 4 = 'unknown:' lanes that recorded no files and have edits: ask them first, never treat it as free; exit 5 = 'LOCAL-ONLY:' hub silent, other machines unread: not free, ask c-001). Fixed or owned: report it, do not fix it. (c) Only if it blocks YOUR tests and nobody owns it: fix it in a SEPARATE narrow commit. (d) FETCH again during long work."
  declare -F spawn_scope_how >/dev/null && SCOPE="$(spawn_scope_how "$_sp_ff")"
  # Step 0 (owner t1 4e373f5d msg 56d7073e): read the developer guide and
  # confirm it; the pre-push hook refuses a push without the ack
  # (spawn-agents/lib/dev-guide-ack.inc.sh). Guard: tests/test-seed-dev-guide.sh.
  if [ -f "${REPO}/csi-spl-doc/doc/md/developer-guide.md" ]; then DEV_GUIDE="STEP 0, before any edit: read csi-spl-doc/doc/md/developer-guide.md, then confirm: 'cd csi-spl-orc && sudo -u ${SPOOL_BOX_USER} env AGENT_ID=${TITLE} DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack'. No ack, no push."; fi
  DEPLOY_GATE="DEPLOY-GATE (SPL-1250; detail: repo CLAUDE.md). (a) 'cd csi-spl-iac && ./run -a do_check_pre_push' before EVERY push and AGAIN after the mandatory rebase; lint only: './run -a do_check_pre_push_lint'; missing scanner: './run -a do_install_lint_tools'. The pre-push hook enforces it; SPL_PREPUSH_OVERRIDE only on the owner's go for that one push, never an agent's. After the push also check 'gh run list --commit <sha>': 61..67 and 85: a scanner red on your sha is your red. (b) Store/hub/auth tests must run on POSTGRES: a store/migration change runs 'PRE_PUSH_TIER=full ./run -a do_check_pre_push'. (c) No literal domain or host: read BASE_DOMAIN / the cnf. (d) INTEGRATION (3) and (6), every push. (e) NEVER run 'do_spl_desk_up' or any prd mutation your safety check REFUSES: send ${SPOOL_ORCHESTRATOR_ID} the exact command and wait."
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
# The binary the AGENT USER runs, not the spawner's (lib/spool-env.inc.sh).
_sp_spool_bin="$(spool_agent_spool_bin)"
# SEED_NOTE: the adapter's own block (spawn_seed_note), worktree or not; a
# kind that declares none renders the shared seed byte for byte (SPL-2176).
SEED_NOTE=""
declare -F spawn_seed_note >/dev/null && SEED_NOTE="HARNESS NOTE (${SPAWN_KIND}): $(spawn_seed_note)"
SPOOL_PROTO="THE SPOOL MESSAGING PROTOCOL. Your spool agent id is ${TITLE}; the spool root is ${SPOOL_ROOT} and your dirs are ${MSGDIR}/{inbox,outbox,archive}. Messages are v:1 JSON, UNSIGNED locally: you never handle a key. The spool binary is ${_sp_spool_bin}, always run with SPOOL_ROOT=${SPOOL_ROOT}. READ: 'SPOOL_ROOT=${SPOOL_ROOT} ${_sp_spool_bin} recv --as ${TITLE}' prints your inbox (JSON); add '--ack' once acted on (to archive/). A topic is a task_id: 'SPOOL_ROOT=${SPOOL_ROOT} ${_sp_spool_bin} tail --task <task_id>' shows it oldest-first, all agents. SEND: 'bash ${SPAWN_SCRIPTS_DIR}/spool-send.sh --from ${TITLE} --to <PEER-ID> --kind <task|result|note|reject|blocker|msg> [--task <task_id>] --body \"<text>\"' writes the peer's inbox and your outbox and pokes its tmux window. Reply on the SAME --task as the message you answer. A poke line (': 'SPOOL ${TITLE}: ...'') is only a doorbell, the spool FILE is the message: run spool recv when poked, at breakpoints and before declaring done. ${_sp_report}: orchestrator = the fleet lease's orch holder, any machine (today ${SPOOL_ORCHESTRATOR_ID} here); a peer on another machine is relayed through the hub. OWNER TEXT (a post meant for the owner, e.g. in a t1 topic) goes to whoever holds the dispatch lease RIGHT NOW, read with 'cd ${SPAWN_ORC_DIR} && sudo -u ${SPOOL_BOX_USER} env SPOOL_ROOT=${SPOOL_ROOT} LEASE_CMD=show ./run -a do_spl_dispatch_lease', never to a fixed dispatcher id and never to the dispatcher that last posted in that topic. Message peers ONLY for your task, blocker handoffs and scope collisions, never open-ended chatter; never type message payloads into tmux windows. HOW TO WRITE A POST: markdown, no \`\`\`md fence; the one rule is csi-spl-doc/doc/help/how-to-post.md."
_spawn_issue_block
}

# ISSUE_BLOCK: the lane's issue in its seed (owner HUM-10, t1 5ea2e615 msg
# 346238a8; the rule's one home: csi-spl-doc/doc/md/lane-issue-and-docs.md).
# spawn-window.sh placed it (lifetime/issue) before this pane started; a dry
# run reads SPAWN_ISSUE or the brief's `Issue:` line. The recorded brief gets
# the `Issue:` line too. No key (a plain session, a respawn of a lane placed
# before the rule): no block. Guard: tests/test-lane-issue.sh.
_spawn_issue_block() {
  ISSUE_BLOCK="" ISSUE_KEY=""
  [ -n "$BRIEF" ] && [ -n "$WORKTREE_DIR" ] || return 0
  # shellcheck source=../lib/lane-issue.inc.sh
  . "${_SP_DIR}/../lib/lane-issue.inc.sh" || return 0
  ISSUE_KEY="$(li_key_of_agent "$SPOOL_ROOT" "$TITLE")"
  [ -n "$ISSUE_KEY" ] || ISSUE_KEY="${SPAWN_ISSUE:-$(li_key_from_brief "$BRIEF")}"
  [ -n "$ISSUE_KEY" ] || { _sp_plan issue "none: the seed names no issue"; return 0; }
  if _sp_live && [ -w "${MSGDIR}/lifetime/brief.md" ] && ! li_key_from_brief "${MSGDIR}/lifetime/brief.md" >/dev/null; then
    printf '\nIssue: %s\n' "$ISSUE_KEY" >>"${MSGDIR}/lifetime/brief.md" 2>/dev/null || true
  fi
  _sp_plan issue "${ISSUE_KEY} in the seed"
  ISSUE_BLOCK="YOUR ISSUE: ${ISSUE_KEY} (status wip), the tracked record of this task; rule: csi-spl-doc/doc/md/lane-issue-and-docs.md. Cite it in every commit subject scope, e.g. 'feat(orc, ${ISSUE_KEY}): ...'. What CLOSES it on landing, only these two forms: a fix|feat|perf|refactor subject with ${ISSUE_KEY} in its scope, or a 'Closes: ${ISSUE_KEY}' trailer in the body (docs/test/chore/ci subjects, reverts, 'Fixes:'/'Refs:' and bare mentions never close). DOCS: a commit that changes behaviour (code under csi-spl-api, -orc, -iac or -wui) lands with its csi-spl-doc/ change, or its message carries the line 'Docs: none (<why>)'. Ending without landing (dropped by a gate, superseded): '$(li_end_cmd "$TITLE")'. /exit-clean refuses a wip issue with no landed commit and no end reason, and a behaviour change with neither docs nor that line."
}

# One registry.tsv row. The requester is last so columns 1-5 stay put.
spawn_registry_line() {  # TITLE KIND PANE RUNDIR STAMP REQUESTER
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6"
}

# A copy of the brief at <spool root>/<id>/lifetime/brief.md, so a restore
# hands the task back (restore-mistral.sh reads it; c-632 found no spawn
# recorded one). A copy, not a link: a dispatch brief may be moved later.
# A respawn of the id (SPAWN_REUSE_ID=1, the watchdog's restart) keeps the
# brief it has: its BRIEF is the restart seed, and a seed copied in nests in
# the next restart's seed (c-539@sat 2026-10-09: four reboots, four seeds
# deep, the real brief cut off; it read its handoff and stopped idle).
spawn_record_brief() {  # MSGDIR BRIEF
  [ -n "$2" ] && [ -r "$2" ] || return 0
  [ "${SPAWN_REUSE_ID:-0}" = 1 ] && [ -s "$1/lifetime/brief.md" ] && return 0
  mkdir -p "$1/lifetime" 2>/dev/null && chmod 0775 "$1/lifetime" 2>/dev/null
  cp -f "$2" "$1/lifetime/brief.md" 2>/dev/null && chmod 0664 "$1/lifetime/brief.md" 2>/dev/null
  return 0
}

# TOPIC TEXT (SPL-2107, owner HUM-10 topic e055195c): a brief that links an
# owner topic (https://<host>/t/<uuid>) gets a "Topic text" section with that
# topic's human posts, read through this box's desk (topic-text.sh), at the
# end of the recorded brief, and the seed then points at that copy. A lane
# seated elsewhere, or not at all, cannot open the link. Nothing to read: one
# line says so; never fails the spawn. A respawn keeps the brief it has. Off
# switch SPAWN_TOPIC_TEXT=0; seam TOPIC_TEXT_READ_CMD (topic-text.sh).
# Guard: tests/test-spawn-topic-text.sh.
spawn_topic_text() {  # MSGDIR -> 0 when the section was added
  local f="$1/lifetime/brief.md" out
  [ "${SPAWN_TOPIC_TEXT:-1}" != 0 ] && [ "${SPAWN_REUSE_ID:-0}" != 1 ] && [ -w "$f" ] || return 1
  out="$(timeout "${SPAWN_TOPIC_TEXT_TIMEOUT:-60}" bash "${_SP_DIR}/topic-text.sh" --spool-root "$SPOOL_ROOT" "$f" 2>/dev/null)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" >>"$f" 2>/dev/null
}

# The brief's copy (and its topic text); BRIEF_READ = the path the seed names.
_spawn_brief_step() {
  BRIEF_READ="$BRIEF"
  if _sp_live; then
    spawn_record_brief "$MSGDIR" "$BRIEF"
    ! spawn_topic_text "$MSGDIR" || BRIEF_READ="${MSGDIR}/lifetime/brief.md"
  fi
  _sp_plan brief "${BRIEF} -> ${MSGDIR}/lifetime/brief.md 0664"
  ! grep -qE 'https?://[A-Za-z0-9.-]+/t/[0-9a-f]{8}-' "$BRIEF" 2>/dev/null ||
    _sp_plan topictext "the linked topics' human posts -> ${MSGDIR}/lifetime/brief.md (section Topic text), the seed reads that copy"
}

# CHANNEL RULES (SPL-3500, owner HUM-10 msg 4501003a; lib/channel-rules.inc.sh):
# a seat whose brief names a mapped channel reads that channel's rules doc
# before it acts, at every seed. The channel is read BEFORE the record step:
# a rotation or restart hands a seed file as BRIEF, and lifetime/brief.md is
# still the task brief until spawn_record_brief copies BRIEF over it.
_spawn_channel_find() {
  _SP_CHANNEL=""
  [ -n "$BRIEF" ] || return 0
  # shellcheck source=../lib/channel-rules.inc.sh
  . "${_SP_DIR}/../lib/channel-rules.inc.sh" || return 0
  _SP_CHANNEL="$(cr_channel_of "$BRIEF" "${MSGDIR}/lifetime/brief.md")" || _SP_CHANNEL=""
}

# The export next to the seed (a dry run: into SPAWN_PLAN_DIR, else none) and
# CHANNEL_RULES, the seed's line. A failed or empty export stops the spawn.
_spawn_channel_rules() {
  CHANNEL_RULES=""
  [ -n "$_SP_CHANNEL" ] || { _sp_plan rules "none: the brief names no channel"; return 0; }
  local out="${MSGDIR}/lifetime/channel-rules.md" exp=1 rc=0
  if ! _sp_live; then
    if [ -n "${SPAWN_PLAN_DIR:-}" ]; then out="${SPAWN_PLAN_DIR}/channel-rules.md"; else exp=0; fi
  fi
  # shellcheck disable=SC2086 # "<tenant> <channel>", two words
  CR_EXPORT="$exp" cr_prepare "$out" $_SP_CHANNEL || rc=$?
  case "$rc" in
    0) CHANNEL_RULES="$CR_LINE"; _sp_plan rules "${_SP_CHANNEL}: its doc -> ${out}, the seed names it" ;;
    1) _sp_plan rules "none: no map row for ${_SP_CHANNEL} in $(cr_map)" ;;
    *) _sp_fail "channel rules for ${_SP_CHANNEL}: the FATAL above; no seed written" ;;
  esac
}

# The seed travels in a FILE; the CLI's argv carries only a pointer to it
# (c-698 2026-10-09: one 'pkill -f "git push"' matched the seed on 12
# seats' argv and killed them all; vibe, whose seed was not in argv, lived).
# Live: <spool root>/<id>/lifetime/prompt.txt. A dry run writes nothing here;
# with SPAWN_PLAN_DIR the pointer names <plan dir>/prompt.txt, written below.
# SPAWN_PROMPT_HEAD_FILE: lines the session must act on first, put ahead of
# the seed (a rotation's ACK-COMMAND: a pointer to it went unread, n=4 on
# 10-11). A file, not a string: spawn-window hands env to the pane through tmux.
# Sets SEED_FILE, PROMPT_ESC (the escaped pointer) and _sp_prompt_args.
_spawn_seed_file() {
  PROMPT_ESC=""; SEED_FILE="${MSGDIR}/lifetime/prompt.txt"
  [ -n "$PROMPT" ] || return 0
  if [ -s "${SPAWN_PROMPT_HEAD_FILE:-}" ]; then
    # the truth rule (SPL-2097) leads every seed, once: ahead of a head that
    # lacks it, and not a second time from the seed after the head
    local rule head
    rule="$(spool_truth_rule)"; head="$(cat "$SPAWN_PROMPT_HEAD_FILE")"
    [ -z "$rule" ] || [[ "$head" == "$rule"* ]] || head="${rule}"$'\n\n'"${head}"
    PROMPT="${head}"$'\n\n'"${PROMPT#"$rule "}"
  fi
  if ! _sp_live; then
    [ -n "${SPAWN_PLAN_DIR:-}" ] && SEED_FILE="${SPAWN_PLAN_DIR}/prompt.txt"
  else
    mkdir -p "${SEED_FILE%/*}" 2>/dev/null && chmod 0775 "${SEED_FILE%/*}" 2>/dev/null
    printf '%s' "$PROMPT" 2>/dev/null > "$SEED_FILE" || _sp_fail "cannot write the seed to ${SEED_FILE}"
    chmod 0664 "$SEED_FILE" 2>/dev/null || true
  fi
  _sp_plan seed "${#PROMPT} bytes -> ${SEED_FILE} 0664 (argv carries only its path)"
  spool_dq_escape PROMPT_ESC "Read and follow your seed: ${SEED_FILE}"
  _sp_prompt_args=" ${SPAWN_PROMPT_FLAG:+${SPAWN_PROMPT_FLAG} }\"${PROMPT_ESC}\""
}

# 0 when ID is a KIND id, or a role seat (c-001/c-002/c-003) respawned
# under another vendor with SPAWN_REUSE_ID=1 (ROTATE_ROLE_VENDOR, SPL-1605).
_sp_kind_ok() {  # ID KIND
  [ "$(spl_kind_of_agent_id "$1")" = "$2" ] && return 0
  [ "${SPAWN_REUSE_ID:-0}" = 1 ] && spool_spawn_is_seat "$1"
}

# Step 1 of spawn_main: refuse a test sandbox, resolve the spool env, the
# permission flags and the identity, and validate TITLE and WORKDIR.
spawn_guards_env() {
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
  _sp_kind_ok "$TITLE" "$SPAWN_KIND" \
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
  _sp_plan spool "SPOOL_ROOT=${SPOOL_ROOT} SPOOL_BIN=${SPOOL_BIN} seed-bin=$(spool_agent_spool_bin)"

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
}

# Step 2: the spool dirs, the brief, the worktree, the lane row and the seed text.
spawn_init_dirs() {
  # The agent's spool dirs. next-agent-id.sh normally claimed them already;
  # creating them again is idempotent (0775, local-folder-layout.md).
  MSGDIR="${SPOOL_ROOT}/${TITLE}"
  if _sp_live; then
    mkdir -p "${MSGDIR}/inbox" "${MSGDIR}/outbox" "${MSGDIR}/archive" 2>/dev/null || true
    chmod 0775 "$MSGDIR" "${MSGDIR}/inbox" "${MSGDIR}/outbox" "${MSGDIR}/archive" 2>/dev/null || true
    echo "INFO: spool dir ${MSGDIR} (inbox/ outbox/ archive/)"
  fi
  _sp_plan spooldir "${MSGDIR}/{inbox,outbox,archive} 0775"
  _spawn_channel_find
  if [ -n "$BRIEF" ]; then
    _spawn_brief_step
  fi

  _spawn_worktree
  _spawn_lane_put
  _spawn_seed_blocks
  _spawn_channel_rules

  PROMPT=""
  if [ -n "$BRIEF" ]; then
    # c-440 (2026-10-06): one 'pkill -f do_check_pre_push' matched the action
    # name in every agent's argv (this prompt) and killed 15 sessions in 0.7 s.
    STOP_RULE="Stop a run with its stop action (e.g. './run -a do_stop_pre_push') or its own pid, never 'pkill -f', 'killall' or 'pgrep -f | xargs kill' on a pattern: it matches other agents' processes."
    PROMPT="$(spool_truth_rule) As your VERY FIRST action, $(spawn_rename_how). Then read your full task brief at ${BRIEF_READ:-$BRIEF} and implement it end to end. That file is your complete, authoritative instructions: follow it exactly, inspect the real code first, and keep any module tests green. ${CHANNEL_RULES:+${CHANNEL_RULES} }Never post greetings, welcomes or social messages; only post what your brief asks for. You do ONE small task. If someone sends you a different task, refuse it and tell ${SPOOL_ORCHESTRATOR_ID} so it spawns a new lane. ${SPAWN_EXIT_RULE} ${DEV_GUIDE:+${DEV_GUIDE} }${ISSUE_BLOCK:+${ISSUE_BLOCK} }${SCOPE:+${SCOPE} }${SEED_NOTE:+${SEED_NOTE} }${SPOOL_PROTO}${INTEGRATION:+ ${INTEGRATION}}${DEPLOY_GATE:+ ${DEPLOY_GATE}} ${NO_FORCE} ${SEED_BOX_PKG} ${STOP_RULE} Honour the project CLAUDE.md / AGENTS.md distribution-hygiene rules (org-neutral, no personal names)."
  fi
  _sp_plan rename-how "$(spawn_rename_how)"
}

# Step 3: the window name, the registry row and the trust pre-accept.
spawn_register_agent() {
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
}

# Step 4: build the launch line; a dry run prints the plan, a live run
# execs the agent.
# The pane ends in `exec bash --norc`: the box user's ~/.bashrc may run
# `git config --global` (an identity loader); a rotation kills this pane a
# second later and left a stale ~/.gitconfig.lock that failed every agent's
# global git config (SPL-1898).
spawn_launch_session() {
  _sp_cli="${SPAWN_BIN##*/}"
  _sp_idl="${SPAWN_RESUME_ID,,}"; _sp_idl="${_sp_idl//_/ }"
  # The resume stub carries the same permission flags as the launch. A grok
  # resumed without them falls back to whatever config.toml says; claude's
  # own restore in the box engine repeats its own permission mode (auto for claude).
  RESTORE="$(spool_agent_cmd_text) -c 'cd \"${RUNDIR}\" ; ${SPAWN_UMASK:+umask ${SPAWN_UMASK} ; }${SPAWN_EXEC_PREFIX:+${SPAWN_EXEC_PREFIX} }${_sp_cli} ${SPAWN_PERM_FLAGS}${SPAWN_EXTRA_FLAGS:+ ${SPAWN_EXTRA_FLAGS}} ${SPAWN_RESUME_FLAG} "
  _sp_plan restore "${RESTORE}<${SPAWN_RESUME_ID}>'"

  # The pointer travels inside a double-quoted argument of the agent's login
  # shell, where " \ $ and ` are live: spool_dq_escape keeps every byte.
  [ -n "${SPAWN_NAME_FLAG:-}" ] && _sp_name_args="${SPAWN_NAME_FLAG} '${DISPLAY_NAME}' "
  _spawn_seed_file
  # specs/012 T013: the CLI starts THROUGH spool-harness (dirs, identity,
  # sidecar in hub mode, SPOOL_* env, and with --mirror the terminal mirror
  # hooks of specs/036), not with the env prepared inline here.
  # SPL-2943: a claude seat under the second login (do_spl_role_failover
  # claude2) runs with that account's own config folder
  _sp_cfg_env=""
  [ "$SPAWN_KIND" = claude ] && [ -n "${SPAWN_CLAUDE_CONFIG_DIR:-}" ] && _sp_cfg_env=" CLAUDE_CONFIG_DIR='${SPAWN_CLAUDE_CONFIG_DIR}'"
  LAUNCH="export ${_sp_pane_env}_TMUX_PANE='${PANE}' ${_sp_pane_env}_TMUX_SOCK='${SOCK}' SPOOL_ROOT='${SPOOL_ROOT}' SPOOL_AGENT_ID='${TITLE}' ${SPOOL_CLI_ENV}${_sp_cfg_env}; cd '${RUNDIR}' && exec ${SPAWN_EXEC_PREFIX:+${SPAWN_EXEC_PREFIX} }bash '${SPAWN_SCRIPTS_DIR}/spool-harness.sh' --as '${TITLE}' --mirror ${SPAWN_UMASK:+--umask '${SPAWN_UMASK}' }-- '${SPAWN_BIN}' ${_sp_name_args}${SPAWN_PERM_FLAGS}${SPAWN_EXTRA_FLAGS:+ ${SPAWN_EXTRA_FLAGS}}${_sp_prompt_args}"

  if ! _sp_live; then
    _sp_plan launch "$(spool_agent_cmd_text) -c \"${LAUNCH}\""
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
  echo "   $(spool_agent_cmd_text) -c 'cd \"${RUNDIR}\" ; ${SPAWN_UMASK:+umask ${SPAWN_UMASK} ; }${SPAWN_EXEC_PREFIX:+${SPAWN_EXEC_PREFIX} }${_sp_cli} ${SPAWN_CONTINUE_FLAG}'"
  if [ -n "$WORKTREE_DIR" ]; then
    echo " Worktree: ${WORKTREE_DIR}  Branch: ${BRANCH} (off origin/${DEFBRANCH})"
    echo " Kept after the close: the retire lists it in workdirs.tsv, the disk sweep removes it after 24 h"
  fi
  echo "════════════════════════════════════════════════════════════════════"
  HIST_TARGET="${HISTFILE:-$HOME/.bash_history}"
  [ -n "$HIST_TARGET" ] && printf '%s\n' "${RESTORE}" >>"$HIST_TARGET" 2>/dev/null
  exec bash --norc
}

# An adapter calls this with <TITLE> <WORKDIR> [BRIEF_FILE] [SLUG]. The steps
# share its locals (bash dynamic scope).
spawn_main() {
  TITLE="${1:-}"; WORKDIR="${2:-}"; BRIEF="${3:-}"; SLUG="${4:-}"
  local _sp_cli _sp_idl _sp_name_args="" _sp_prompt_args=""
  spawn_guards_env
  spawn_init_dirs
  spawn_register_agent
  spawn_launch_session
}
