#!/bin/bash
#------------------------------------------------------------------------------
# @description Land a lane's commits on master WITHOUT holding one tool call for
# @description the whole pre-push hook (SPL-1578). Three lanes were killed by the
# @description watchdog's 15-min cap on a single call, each time the foreground
# @description `git push`: the hook ran for minutes, master moved meanwhile, the
# @description push was refused, rebase, hook again. PUSH_CMD=start (default)
# @description checks the tree, detaches one worker (setsid, its own log) and
# @description returns at once; PUSH_CMD=status prints the verdict, for short polls.
# @description The worker loops: FETCH (git-fetch-fresh.sh, --force on a retry)
# @description -> `git -c user.name -c user.email rebase origin/<branch>` (origin/master
# @description when <branch> is not on origin yet: the push creates it, SPL-4317) -> the
# @description identity check (%ae and %ce, --no-mailmap) -> the R7 review-line
# @description check (a round row `<type>(rNN-NN-...`, or bNN-NN / pNN-NN for a bug / perf round, needs a `review: ... PASS
# @description <40-hex sha> ... | log: <id>@<box>:<path>` body line whose sha
# @description resolves after fetching `review/rNN-NN`, and that do_spl_review_line_check's
# @description syntax path (REVIEW_LINE_SYNTAX=1) passes, so `ran:` names a test, SPL-4066;
# @description rounds-rulebook.md 2.7.4) -> `git push <remote>
# @description <sha>:<branch>`, the sha it logged, never HEAD (a lane rotation switched
# @description c-462's tree mid-push: HEAD was origin's head, read PUSHED; SPL-2574);
# @description a push refused because the branch moved is retried
# @description up to PUSH_RETRIES times. It ends by writing ONE status file:
# @description `PUSHED <sha>` only when <sha> is on <remote>/<branch> after a fresh
# @description fetch (+ `landed_rc=` of `git-fetch-fresh.sh --landed`), else GAVE-UP;
# @description a HEAD that moved during the push is logged whatever the verdict;
# @description `REFUSED <reason>` (+ the tail of the push/hook output),
# @description `GAVE-UP <reason>` or `NOTHING-TO-PUSH <sha>`: 0 commits ahead of
# @description origin/<branch> after the rebase, so nothing landed (SPL-2312).
# @description Each PUSHED also appends `<iso time> <base>..<sha>` to the
# @description append-only <state>/pushes.log (<base> = origin/<branch> right
# @description before that push; spec 157 Rule 2, read by do_spl_accepted_close).
# @description A lane's AGENT_ID must push from that lane's own worktree (spawn's
# @description <main>-wt/<AGENT_ID>, or a linked worktree on branch <AGENT_ID>-*):
# @description any other tree, the main checkout included, is a FATAL at start
# @description (m-181 pushed the main checkout, origin's own head, and read LANDED).
# @description An origin url or pushurl with embedded credentials (`https://<user>[:<token>]@...`) is a FATAL at start
# @description too, naming the repo and the `git -C <repo> remote set-url` fix, the userinfo masked; it never rewrites the URL (SPL-3766). It never forces, never sets SPL_PREPUSH_OVERRIDE
# @description (it unsets it, and AGENT_ID: the hook sees a hand push's env) and never edits a file; a rebase conflict is aborted.
# @description Its push is MARKED (SPL-2211: a one-push token while the worker holds the lock):
# @description the pre-push hook refuses a lane's unmarked hand push to master before the gate.
# @description The why: csi-spl-doc/doc/md/lane-integration-rules.md section 3.3.
# @description status exit: 0 PUSHED, 1 REFUSED / GAVE-UP / DIED, 3 RUNNING, 4 none, 5 NOTHING-TO-PUSH.
# @param PUSH_CMD (optional) - start (default) or status
# @param PUSH_WORKTREE (optional) - the lane's checkout; default the current dir; held to the AGENT_ID worktree rule too
# @param PUSH_STATE_DIR (optional) - default <SPOOL_ROOT>/<AGENT_ID>/lifetime/push-master when that lifetime dir exists, else <git-dir>/spl-push-master
# @param AGENT_ID (optional) - the lane id: picks the default state dir; a lane id must push from its own worktree
# @param PUSH_REMOTE (optional) - default origin
# @param PUSH_BRANCH (optional) - default master
# @param PUSH_RETRIES (optional) - pushes refused because the branch moved, retried; default 4
# @param PUSH_GIT_NAME, PUSH_GIT_EMAIL (optional) - the identity for the rebase and the check; default HEAD's author
# @example AGENT_ID=c-050 ./run -a do_spl_push_master
# @example AGENT_ID=c-050 PUSH_CMD=status ./run -a do_spl_push_master
#------------------------------------------------------------------------------

do_spl_push_master() {
  # spec 165 3.3 (SPL-4344): a watcher seat is read-only, read from the chain
  declare -F spl_watcher_refuse >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  spl_watcher_refuse do_spl_push_master || return 1
  local cmd="${PUSH_CMD:-start}" wt state
  wt="$(git -C "${PUSH_WORKTREE:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" ||
    { echo "FATAL PUSH: ${PUSH_WORKTREE:-$PWD} is not a git checkout"; return 1; }
  state="$(_spl_push_master_state_dir "$wt")" || return 1
  case "$cmd" in
    start) _spl_push_master_start "$wt" "$state" ;;
    status) _spl_push_master_status "$state" ;;
    *) echo "FATAL PUSH: PUSH_CMD must be start or status, got '$cmd'"; return 1 ;;
  esac
}

# _spl_push_master_state_dir <worktree> - prints (and creates) the state dir.
_spl_push_master_state_dir() {
  local wt="$1" d="${PUSH_STATE_DIR:-}" life
  if [[ -z "$d" ]]; then
    life="${SPOOL_ROOT:-/var/spool-hub}/${AGENT_ID:-}/lifetime"
    if [[ "${AGENT_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ && -d "$life" ]]; then
      d="$life/push-master"
    else
      d="$(git -C "$wt" rev-parse --absolute-git-dir)/spl-push-master"
    fi
  fi
  mkdir -p "$d" || { echo "FATAL PUSH: cannot create the state dir $d" >&2; return 1; }
  echo "$d"
}

# _spl_push_master_start <worktree> <state> - refuses fast, else detaches the
# worker and returns at once.
_spl_push_master_start() {
  local wt="$1" state="$2" self name email
  _spl_push_master_own_tree "$wt" || return 1
  _spl_push_master_url_creds "$wt" || return 1
  [[ "${PUSH_RETRIES:-4}" =~ ^[1-9][0-9]?$ ]] || { echo "FATAL PUSH: PUSH_RETRIES must be 1..99"; return 1; }
  if ! flock -n "$state/lock" true 2>/dev/null; then
    echo "PUSH: a push is already running for $wt"; _spl_push_master_status "$state"; return 3
  fi
  if ! git -C "$wt" diff --quiet || ! git -C "$wt" diff --cached --quiet; then
    echo "FATAL PUSH: uncommitted tracked changes in $wt: commit them (explicit pathspecs) or set them aside first"; return 1
  fi
  git -C "$wt" symbolic-ref -q HEAD >/dev/null || { echo "FATAL PUSH: detached HEAD in $wt"; return 1; }
  name="${PUSH_GIT_NAME:-$(git -C "$wt" log -1 --no-mailmap --format=%an)}"
  email="${PUSH_GIT_EMAIL:-$(git -C "$wt" log -1 --no-mailmap --format=%ae)}"
  self="$(readlink -f "${BASH_SOURCE[0]}")"
  printf 'RUNNING\nsince=%s\n' "$(date -u +%FT%TZ)" >"$state/status.tmp" && mv -f "$state/status.tmp" "$state/status"
  : >"$state/log"
  # The worker closes every inherited fd above 2: a lock fd of the caller held
  # open by a detached child blocks the caller's next run (and tmux servers).
  # No redirect on that loop: bash saves fd 2 to a high fd for a `2>/dev/null`,
  # the loop closed that copy and fd 2 stayed on /dev/null, so no stderr line
  # ever reached the log (SPL-4437). Closing a closed fd prints nothing.
  PUSH_WT="$wt" PUSH_STATE="$state" PUSH_NAME="$name" PUSH_EMAIL="$email" \
    PUSH_FETCH="${PUSH_FETCH_SCRIPT:-$(dirname "$self")/../features/spawn-agents/scripts/git-fetch-fresh.sh}" \
    setsid -f bash -c '
      for fd in /proc/$$/fd/*; do fd="${fd##*/}"; [[ "$fd" -gt 2 ]] && eval "exec $fd>&-"; done
      source "$1" && _spl_push_master_worker' _ "$self" </dev/null >>"$state/log" 2>&1
  echo "PUSH: started for $(git -C "$wt" rev-parse --short HEAD) in $wt"
  echo "PUSH: poll with PUSH_CMD=status (state $state)"
}

# _spl_push_master_url_creds <worktree> - 0 unless the push remote's url or
# pushurl carries userinfo (`scheme://<user>[:<token>]@host`): FATAL naming the
# repo, the URL with its userinfo masked, and the set-url fix. It never prints
# the userinfo and never rewrites the URL. On 2026-10-26 a box's origin became
# `https://x-access-token:@github.com/...` (empty token): it no longer matched
# the box's `pushInsteadOf https://github.com/`, so every lane's push went
# over https with no password and failed. An ssh URL with a bare user
# (`git@host:...`, `ssh://git@host/...`) is not a credential and passes.
_spl_push_master_url_creds() {
  local wt="$1" remote="${PUSH_REMOTE:-origin}" key u scheme rest auth ui bad=0 flag
  for key in url pushurl; do
    while IFS= read -r u; do
      [[ "$u" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$ ]] || continue
      scheme="${BASH_REMATCH[1]}" rest="${BASH_REMATCH[2]}"
      auth="${rest%%/*}"
      [[ "$auth" == *@* ]] || continue
      ui="${auth%@*}"
      [[ "$scheme" =~ ^(ssh|git\+ssh|ssh\+git)$ && "$ui" != *:* ]] && continue
      flag=""; [[ "$key" == pushurl ]] && flag="--push "
      echo "FATAL PUSH: $wt: $remote URL carries embedded credentials (remote.$remote.$key = $scheme://***@${rest#*"$ui"@}); a push over it fails or leaks the token. Fix it, then push again:"
      echo "  git -C $wt remote set-url $flag$remote $scheme://${rest#*"$ui"@}"
      bad=1
    done < <(git -C "$wt" config --get-all "remote.$remote.$key" 2>/dev/null)
  done
  return "$bad"
}

# _spl_push_master_status <state> - prints the status file; the exit code is
# the verdict (0 PUSHED, 1 REFUSED/GAVE-UP/DIED, 3 RUNNING, 4 none,
# 5 NOTHING-TO-PUSH: 0 commits ahead, nothing landed).
_spl_push_master_status() {
  local state="$1" first
  [[ -f "$state/status" ]] || { echo "NONE: no push started (state $state)"; return 4; }
  first="$(sed -n 1p "$state/status")"
  if [[ "$first" == RUNNING ]] && flock -n "$state/lock" true 2>/dev/null; then
    # The worker holds the lock for its whole life; a just-started one may not
    # have taken it yet, so look once more before calling it dead.
    sleep 2
    first="$(sed -n 1p "$state/status")"
    if [[ "$first" == RUNNING ]] && flock -n "$state/lock" true 2>/dev/null; then
      echo "DIED: the push worker is gone without a verdict; its log tail:"
      tail -n 20 "$state/log" 2>/dev/null; return 1
    fi
  fi
  cat "$state/status"
  case "$first" in
    PUSHED*) return 0 ;;
    NOTHING-TO-PUSH*) return 5 ;;
    RUNNING) echo "log: $(tail -n 1 "$state/log" 2>/dev/null)"; return 3 ;;
    *) return 1 ;;
  esac
}

# _spl_push_master_own_tree <toplevel> - 0 unless AGENT_ID names a lane and
# <toplevel> is not that lane's own worktree: a linked worktree named after
# the id (spawn-core makes <main>-wt/<id>) or on a branch <id>-* (spawn's
# branch). m-181 pushed from the main checkout, already on origin/master: the
# push was origin's own head and read LANDED, its 3 commits on no ref (SPL-2312).
_spl_push_master_own_tree() {
  local wt="$1" id="${AGENT_ID:-}" want br
  [[ "$id" =~ ^([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)$ ]] || return 0
  [[ "$(_spl_push_master_lane_tree "$wt")" == "$id" ]] && return 0
  br="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)"
  [[ "$br" == "$id"-* && "$(git -C "$wt" rev-parse --absolute-git-dir)" != \
     "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)" ]] && return 0
  want="$(_spl_push_master_lane_wt "$wt" "$id")"
  echo "FATAL PUSH: AGENT_ID=$id pushes only from its own worktree $want, not from $wt. Fix: cd $want/csi-spl-orc and start the push there"
  return 1
}

# _spl_push_master_lane_wt <tree> <id> - prints the lane's worktree: the
# `git worktree list` entry named <id>, else the one on a branch <id>-*, else
# where spawn-core would make it, <main checkout>-wt/<id>.
_spl_push_master_lane_wt() {
  local line p="" hit="" cd
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) p="${line#worktree }"; [[ "${p##*/}" == "$2" ]] && { echo "$p"; return 0; } ;;
      "branch refs/heads/$2-"*) [[ -n "$hit" ]] || hit="$p" ;;
    esac
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null)
  [[ -n "$hit" ]] && { echo "$hit"; return 0; }
  cd="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  echo "$(dirname "$cd")-wt/$2"
}

# _spl_push_master_follow - re-points PUSH_STATE (and the worker's `out`) at
# where the state dir is NOW. A lane that closes while its push runs has its
# whole spool dir moved to <SPOOL_ROOT>/.retired/<id>.<ts>/ (agent-id-retire):
# the old path was gone, so the verdict was never written and the status read
# RUNNING for good (m-595, SPL-2264). The worker holds fd 8 on the dir; its
# /proc link names the dir's current path.
_spl_push_master_follow() {
  local now
  [[ "$PUSH_STATE" -ef "/proc/$BASHPID/fd/8" ]] && return 0
  now="$(readlink "/proc/$BASHPID/fd/8" 2>/dev/null)" && [[ -d "$now" ]] || return 0
  echo "$(date -u +%TZ) the state dir moved: $PUSH_STATE -> $now"
  PUSH_STATE="$now"
  [[ -n "${out:-}" ]] && out="$now/push.out"
  return 0
}

# _spl_push_master_end <verdict lines> [detail file] - writes the ONE status
# file, in the state dir where it is now (_spl_push_master_follow).
_spl_push_master_end() {
  _spl_push_master_follow
  [[ -z "${2:-}" || -e "$2" ]] || set -- "$1" "$PUSH_STATE/${2##*/}"
  {
    echo "$1"
    echo "finished=$(date -u +%FT%TZ)"
    if [[ -n "${2:-}" && -s "$2" ]]; then echo "--- tail ---"; tail -n 30 "$2"; fi
  } >"$PUSH_STATE/status.tmp" && mv -f "$PUSH_STATE/status.tmp" "$PUSH_STATE/status"
  echo "$(date -u +%TZ) END $(head -n 1 <<<"$1")"
}

# _spl_push_master_record <base> <sha> - appends `<iso time> <base>..<sha>`
# to <state>/pushes.log, append-only, once per landed push: <base> is
# <remote>/<branch> right before the push, so the range is exactly what this
# push put on trunk. The status file keeps only the last push, and a lane
# pushes every commit at once: an unreviewed commit of push 1 hid behind a
# reviewed push 2 (spec 157 Rule 2 check 3, Z1). do_spl_accepted_close reads
# every range of the lane's lifetime.
_spl_push_master_record() {
  echo "$(date -u +%FT%TZ) $1..$2" >>"$PUSH_STATE/pushes.log" ||
    echo "$(date -u +%TZ) WARN could not append $1..$2 to $PUSH_STATE/pushes.log"
}

# _spl_push_master_moved <push output file> - 0 when the push was refused only
# because the branch moved (retry), 1 otherwise (a hook or a rule said no).
_spl_push_master_moved() {
  grep -qE '\[rejected\].*\((fetch first|non-fast-forward)\)|\[remote rejected\].*(cannot lock ref|incorrect old value|failed to update ref|but expected)' "$1"
}

# _spl_push_master_unreviewed <range> [remote] - prints `<short sha> review line:
# <reason>`, one line per round row in <range> (subject
# `test|refactor|ci|fix|feat|perf(<r|b|p>NN-NN-...`: a refactor, bug or perf
# round) whose R7 review line is void.
_spl_push_master_unreviewed() {
  local h why
  for h in $(git rev-list --reverse "$1"); do
    [[ "$(git log -1 --format=%s "$h")" =~ ^(test|refactor|ci|fix|feat|perf)\(([rbp][0-9]+-[0-9]{2})- ]] || continue
    why="$(_spl_push_master_review_why "$(git log -1 --format=%b "$h")" "${BASH_REMATCH[2]}" "${2:-origin}")"
    [[ -z "$why" ]] || echo "$(git rev-parse --short "$h") review line: $why"
  done
}

# _spl_push_master_review_why <body> <round row, e.g. rNN-NN> <remote> - prints why the body's
# review line is void, nothing when it is checkable: the plan section 1 format
# `review: <id>@<box> <vendor> PASS <40-hex sha> ran: ... | read: ... | log:
# <id>@<box>:<path>`, its sha a commit here after fetching `review/<rNN-NN>`,
# and then whatever the retro checker's syntax path refuses (SPL-4066).
_spl_push_master_review_why() {
  local line sha
  line="$(grep -m 1 -E '^review: \S+@\S+ \S+ PASS ' <<<"$1")" ||
    { echo "none of the form 'review: <id>@<box> <vendor> PASS <sha> ...'"; return 0; }
  sha="$(awk '{print $5}' <<<"$line")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "sha '$sha' is not 40 hex"; return 0; }
  git fetch -q "$3" "+refs/heads/review/$2:refs/remotes/$3/review/$2" >/dev/null 2>&1
  git rev-parse --verify -q "$sha^{commit}" >/dev/null || { echo "sha $sha does not resolve (fetched review/$2)"; return 0; }
  grep -qE '\| log: \S+@\S+:\S+' <<<"$line" || { echo "no '| log: <id>@<box>:<path>'"; return 0; }
  _spl_push_master_review_syntax "$line"
}

# _spl_push_master_review_syntax <line> - prints `checker: <why>` when
# do_spl_review_line_check's syntax path (REVIEW_LINE_SYNTAX=1, the check
# that needs no log) refuses the line, nothing when it passes. It calls the
# checker's own function, never a copy of its regexes: c-585's r36-02 line
# named its tests as `check-pre-push-{...}.tst.sh`, the checker said `MISSING
# ran: names no test` (exit 3) and this gate would have landed it (SPL-4066).
# The sha is read in this checkout (the worker's cwd).
_spl_push_master_review_syntax() {
  local f="${BASH_SOURCE[0]%/*}/spl-review-line-check.func.sh" out
  if ! declare -F _spl_review_line_syntax >/dev/null; then
    # shellcheck source=/dev/null
    source "$f" 2>/dev/null || { echo "checker: cannot read $f"; return 0; }
  fi
  out="$(REVIEW_LINE_REPO="$(git rev-parse --show-toplevel)" _spl_review_line_syntax "$1" 2>&1)" && return 0
  out="$(grep -m 1 '^SYNTAX FAIL ' <<<"$out")"
  echo "checker: ${out#SYNTAX FAIL }"
}

# The marker of the worker's own push (SPL-2211): the pre-push hook refuses a
# lane's hand `git push` to master within a second, before the gate, unless the
# push carries SPL_PUSH_MASTER_TOKEN equal to <state>/push.token while the
# worker holds <state>/lock. The marker never skips the gate itself.

# _spl_push_master_lane_tree <toplevel> - prints the agent id when <toplevel>
# is a LANE: a linked worktree named after an agent id (c-775, m-259-x,
# CLE-3337). Nothing for the main checkout, a human's tree or a reconcile tmp.
_spl_push_master_lane_tree() {
  local base="${1##*/}" id gd cd
  [[ "$base" =~ ^([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)([._-].*)?$ ]] || return 1
  id="${BASH_REMATCH[1]}"
  gd="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  cd="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [[ -n "$gd" && -n "$cd" && "$gd" != "$cd" ]] || return 1
  echo "$id"
}

# _spl_push_master_marked - 0 when this push is the worker's own (see above).
_spl_push_master_marked() {
  local tok="${SPL_PUSH_MASTER_TOKEN:-}" st="${SPL_PUSH_MASTER_STATE:-}"
  [[ -n "$tok" && -n "$st" && -r "$st/push.token" ]] || return 1
  [[ "$(cat "$st/push.token" 2>/dev/null)" == "$tok" ]] || return 1
  ! flock -n "$st/lock" true 2>/dev/null
}

# _spl_push_master_git_push <remote> <branch> <out> [<sha>] - the worker's one
# push of <sha>, never HEAD (a branch switch after the sha was logged pushed
# origin's own head, SPL-2574), marked for the hook; the token lives only as
# long as the push. <sha> defaults to HEAD only for callers that test the hook.
# The destination is a full refname: git refuses a sha pushed to a short name
# that is not on the remote yet ("not a full refname", SPL-4317).
_spl_push_master_git_push() {
  local tok rc
  tok="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  printf '%s\n' "$tok" >"$PUSH_STATE/push.token"
  SPL_PUSH_MASTER_TOKEN="$tok" SPL_PUSH_MASTER_STATE="$PUSH_STATE" git push "$1" "${4:-HEAD}:refs/heads/${2#refs/heads/}" >"$3" 2>&1; rc=$?
  rm -f "$PUSH_STATE/push.token"
  return "$rc"
}

# _spl_push_master_head_moved <sha> - 0 (and logs it) when HEAD is no longer
# <sha>: the tree was switched while the push ran (c-462, SPL-2574).
_spl_push_master_head_moved() {
  local head
  head="$(git rev-parse HEAD 2>/dev/null)"
  [[ "$head" == "$1" ]] && return 1
  echo "$(date -u +%TZ) HEAD moved during the push: $1 -> ${head:-unknown}"
}

# _spl_push_master_fetch <remote> <branch> [--force] - fetches the ref the
# rebase goes onto and prints it: <remote>/<branch>, or <remote>/master when
# <branch> is not on <remote> yet (`ls-remote --exit-code` rc 2: the first push
# of a review/ ref always gave up on that fetch, c-954 msg 3d6597dd, SPL-4317).
# The push then creates <branch>, with no force. Master never asks ls-remote.
# The full refs/heads/<branch>: a bare pattern also matches other/<branch>
# (SPL-4378). Any other ls-remote failure keeps <branch>. It prints the ref it
# fetched even when the fetch fails, so a GAVE-UP names that ref.
_spl_push_master_fetch() {
  local remote="$1" branch="$2"; shift 2
  if [[ "$branch" != master ]]; then
    git ls-remote --exit-code "$remote" "refs/heads/$branch" >/dev/null 2>&1
    (( $? == 2 )) && { echo "$(date -u +%TZ) $branch is not on $remote yet: rebase onto $remote/master" >&2; branch=master; }
  fi
  echo "$remote/$branch"
  bash "$PUSH_FETCH" -C "$PUSH_WT" --remote "$remote" --branch "$branch" "$@" >&2
}

_spl_push_master_worker() {
  local remote="${PUSH_REMOTE:-origin}" branch="${PUSH_BRANCH:-master}" max="${PUSH_RETRIES:-4}"
  local try=0 out="$PUSH_STATE/push.out" sha base bad landed_rc moved onto
  local -a G=(-c "user.name=$PUSH_NAME" -c "user.email=$PUSH_EMAIL") force
  # The hook must see the env of a hand push: no override, and no AGENT_ID
  # (SPL-1583: the lane's id leaked into the orc tests the hook runs). The
  # caller already picked the state dir from AGENT_ID. Nor the PUSH_* knobs,
  # read above: a PUSH_BRANCH=review/<x> push sent the orc tests in the hook
  # to review/<x> on their temp origins (12 FAILs, SPL-4437).
  unset SPL_PREPUSH_OVERRIDE AGENT_ID PUSH_REMOTE PUSH_BRANCH PUSH_RETRIES
  exec 9>"$PUSH_STATE/lock"
  flock -n 9 || { echo "another worker holds the lock"; return 0; }
  exec 8<"$PUSH_STATE"
  cd "$PUSH_WT" || { _spl_push_master_end "REFUSED cannot enter $PUSH_WT"; return 1; }
  while (( try < max )); do
    try=$((try + 1)); force=(); _spl_push_master_follow
    (( try > 1 )) && force=(--force)
    echo "$(date -u +%TZ) try $try/$max: fetch"
    if ! onto="$(_spl_push_master_fetch "$remote" "$branch" "${force[@]}")"; then
      _spl_push_master_end "GAVE-UP the fetch of ${onto:-$remote/$branch} failed"; return 1
    fi
    echo "$(date -u +%TZ) try $try/$max: rebase onto $onto"
    if ! git "${G[@]}" rebase "$onto" >"$out" 2>&1; then
      git rebase --abort >/dev/null 2>&1
      _spl_push_master_end "REFUSED rebase onto $onto conflicts (aborted; resolve by hand)" "$out"; return 1
    fi
    bad="$(git log --no-mailmap --format='%h %ae %ce' "$onto..HEAD" | awk -v e="$PUSH_EMAIL" '$2 != e || $3 != e')"
    if [[ -n "$bad" ]]; then
      printf '%s\n' "$bad" >"$out"
      _spl_push_master_end "REFUSED WRONG-IDENTITY-DO-NOT-PUSH (want $PUSH_EMAIL as author and committer)" "$out"; return 1
    fi
    bad="$(_spl_push_master_unreviewed "$onto..HEAD" "$remote")"
    if [[ -n "$bad" ]]; then
      printf '%s\n' "$bad" >"$out"
      _spl_push_master_end "REFUSED round row $(head -n 1 <<<"$bad")" "$out"; return 1
    fi
    sha="$(git rev-parse HEAD)"
    if [[ "$(git rev-list --count "$onto..HEAD")" == 0 ]]; then
      _spl_push_master_end "NOTHING-TO-PUSH $sha
0 commits ahead of $onto after the rebase: nothing landed (SPL-2312). Are your commits on this branch, in this worktree?"; return 0
    fi
    echo "$(date -u +%TZ) try $try/$max: push $sha -> $remote $branch"
    base="$(git rev-parse "$onto")"
    if _spl_push_master_git_push "$remote" "$branch" "$out" "$sha"; then
      _spl_push_master_follow
      cat "$out"
      moved=""; _spl_push_master_head_moved "$sha" && moved=" (HEAD moved during the push)"
      bash "$PUSH_FETCH" -C "$PUSH_WT" --remote "$remote" --branch "$branch" --landed; landed_rc=$?
      if ! git merge-base --is-ancestor "$sha" "$remote/$branch" 2>/dev/null; then
        _spl_push_master_end "GAVE-UP the push exited 0 but $sha is not on $remote/$branch after a fresh fetch$moved
landed_rc=$landed_rc" "$out"; return 1
      fi
      _spl_push_master_record "$base" "$sha"
      _spl_push_master_end "PUSHED $sha
landed_rc=$landed_rc
tries=$try"; return 0
    fi
    _spl_push_master_follow
    cat "$out"
    _spl_push_master_head_moved "$sha"
    _spl_push_master_moved "$out" || { _spl_push_master_end "REFUSED push of $sha (the hook or a rule said no)" "$out"; return 1; }
    echo "$(date -u +%TZ) try $try/$max: $remote/$branch moved during the push; rebase and retry"
  done
  _spl_push_master_end "GAVE-UP $remote/$branch moved during each of $max pushes" "$out"; return 1
}
