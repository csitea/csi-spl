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
# @description -> `git -c user.name -c user.email rebase origin/<branch>` -> the
# @description identity check (%ae and %ce, --no-mailmap) -> the R7 review-line
# @description check (a round row `<type>(rNN-NN-...` needs a `review: ... PASS
# @description <sha> ` body line; rounds-rulebook.md R7) -> `git push <remote>
# @description HEAD:<branch>`; a push refused because the branch moved is retried
# @description up to PUSH_RETRIES times. It ends by writing ONE status file:
# @description `PUSHED <sha>` (+ `landed_rc=` of `git-fetch-fresh.sh --landed`),
# @description `REFUSED <reason>` (+ the tail of the push/hook output) or
# @description `GAVE-UP <reason>`. It never forces, never sets SPL_PREPUSH_OVERRIDE
# @description (it unsets it, and AGENT_ID: the hook sees a hand push's env) and never edits a file; a rebase conflict is aborted.
# @description The why: csi-spl-doc/doc/md/lane-integration-rules.md section 3.3.
# @description status exit: 0 PUSHED, 1 REFUSED / GAVE-UP / DIED, 3 RUNNING, 4 none.
# @param PUSH_CMD (optional) - start (default) or status
# @param PUSH_WORKTREE (optional) - the lane's checkout; default the current dir
# @param PUSH_STATE_DIR (optional) - default <SPOOL_ROOT>/<AGENT_ID>/lifetime/push-master when that lifetime dir exists, else <git-dir>/spl-push-master
# @param AGENT_ID (optional) - the lane id, picks the default state dir
# @param PUSH_REMOTE (optional) - default origin
# @param PUSH_BRANCH (optional) - default master
# @param PUSH_RETRIES (optional) - pushes refused because the branch moved, retried; default 4
# @param PUSH_GIT_NAME, PUSH_GIT_EMAIL (optional) - the identity for the rebase and the check; default HEAD's author
# @example AGENT_ID=c-050 ./run -a do_spl_push_master
# @example AGENT_ID=c-050 PUSH_CMD=status ./run -a do_spl_push_master
#------------------------------------------------------------------------------

do_spl_push_master() {
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
  PUSH_WT="$wt" PUSH_STATE="$state" PUSH_NAME="$name" PUSH_EMAIL="$email" \
    PUSH_FETCH="${PUSH_FETCH_SCRIPT:-$(dirname "$self")/../features/spawn-agents/scripts/git-fetch-fresh.sh}" \
    setsid -f bash -c '
      for fd in /proc/$$/fd/*; do fd="${fd##*/}"; [[ "$fd" -gt 2 ]] && eval "exec $fd>&-"; done 2>/dev/null
      source "$1" && _spl_push_master_worker' _ "$self" </dev/null >>"$state/log" 2>&1
  echo "PUSH: started for $(git -C "$wt" rev-parse --short HEAD) in $wt"
  echo "PUSH: poll with PUSH_CMD=status (state $state)"
}

# _spl_push_master_status <state> - prints the status file; the exit code is
# the verdict (0 PUSHED, 1 REFUSED/GAVE-UP/DIED, 3 RUNNING, 4 none).
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
    RUNNING) echo "log: $(tail -n 1 "$state/log" 2>/dev/null)"; return 3 ;;
    *) return 1 ;;
  esac
}

# _spl_push_master_end <verdict lines> [detail file] - writes the ONE status file.
_spl_push_master_end() {
  {
    echo "$1"
    echo "finished=$(date -u +%FT%TZ)"
    if [[ -n "${2:-}" && -s "$2" ]]; then echo "--- tail ---"; tail -n 30 "$2"; fi
  } >"$PUSH_STATE/status.tmp" && mv -f "$PUSH_STATE/status.tmp" "$PUSH_STATE/status"
  echo "$(date -u +%TZ) END $(head -n 1 <<<"$1")"
}

# _spl_push_master_moved <push output file> - 0 when the push was refused only
# because the branch moved (retry), 1 otherwise (a hook or a rule said no).
_spl_push_master_moved() {
  grep -qE '\[rejected\].*\((fetch first|non-fast-forward)\)|\[remote rejected\].*(cannot lock ref|incorrect old value|failed to update ref|but expected)' "$1"
}

# _spl_push_master_unreviewed <range> - prints the short sha of each round row
# in <range> (subject `test|refactor|ci|fix|feat|perf(rNN-NN-...`) whose body
# has no R7 review line (`review: <id>@<box> <vendor> PASS <sha> ...`).
_spl_push_master_unreviewed() {
  local h
  for h in $(git rev-list --reverse "$1"); do
    grep -qE '^(test|refactor|ci|fix|feat|perf)\(r[0-9]+-[0-9]{2}-' <<<"$(git log -1 --format=%s "$h")" || continue
    grep -qE '^review: \S+@\S+ \S+ PASS [0-9a-f]{7,40} ' <<<"$(git log -1 --format=%b "$h")" || git rev-parse --short "$h"
  done
}

_spl_push_master_worker() {
  local remote="${PUSH_REMOTE:-origin}" branch="${PUSH_BRANCH:-master}" max="${PUSH_RETRIES:-4}"
  local try=0 out="$PUSH_STATE/push.out" sha bad landed_rc
  local -a G=(-c "user.name=$PUSH_NAME" -c "user.email=$PUSH_EMAIL") force
  # The hook must see the env of a hand push: no override, and no AGENT_ID
  # (SPL-1583: the lane's id leaked into the orc tests the hook runs). The
  # caller already picked the state dir from AGENT_ID.
  unset SPL_PREPUSH_OVERRIDE AGENT_ID
  exec 9>"$PUSH_STATE/lock"
  flock -n 9 || { echo "another worker holds the lock"; return 0; }
  cd "$PUSH_WT" || { _spl_push_master_end "REFUSED cannot enter $PUSH_WT"; return 1; }
  while (( try < max )); do
    try=$((try + 1)); force=()
    (( try > 1 )) && force=(--force)
    echo "$(date -u +%TZ) try $try/$max: fetch"
    if ! bash "$PUSH_FETCH" -C "$PUSH_WT" --remote "$remote" --branch "$branch" "${force[@]}"; then
      _spl_push_master_end "GAVE-UP the fetch of $remote/$branch failed"; return 1
    fi
    echo "$(date -u +%TZ) try $try/$max: rebase onto $remote/$branch"
    if ! git "${G[@]}" rebase "$remote/$branch" >"$out" 2>&1; then
      git rebase --abort >/dev/null 2>&1
      _spl_push_master_end "REFUSED rebase onto $remote/$branch conflicts (aborted; resolve by hand)" "$out"; return 1
    fi
    bad="$(git log --no-mailmap --format='%h %ae %ce' "$remote/$branch..HEAD" | awk -v e="$PUSH_EMAIL" '$2 != e || $3 != e')"
    if [[ -n "$bad" ]]; then
      printf '%s\n' "$bad" >"$out"
      _spl_push_master_end "REFUSED WRONG-IDENTITY-DO-NOT-PUSH (want $PUSH_EMAIL as author and committer)" "$out"; return 1
    fi
    bad="$(_spl_push_master_unreviewed "$remote/$branch..HEAD")"
    if [[ -n "$bad" ]]; then
      printf '%s\n' "$bad" >"$out"
      _spl_push_master_end "REFUSED round row $(head -n 1 <<<"$bad") has no R7 review line" "$out"; return 1
    fi
    sha="$(git rev-parse HEAD)"
    echo "$(date -u +%TZ) try $try/$max: push $sha -> $remote $branch"
    if git push "$remote" "HEAD:$branch" >"$out" 2>&1; then
      cat "$out"
      bash "$PUSH_FETCH" -C "$PUSH_WT" --remote "$remote" --branch "$branch" --landed; landed_rc=$?
      _spl_push_master_end "PUSHED $sha
landed_rc=$landed_rc
tries=$try"; return 0
    fi
    cat "$out"
    _spl_push_master_moved "$out" || { _spl_push_master_end "REFUSED push of $sha (the hook or a rule said no)" "$out"; return 1; }
    echo "$(date -u +%TZ) try $try/$max: $remote/$branch moved during the push; rebase and retry"
  done
  _spl_push_master_end "GAVE-UP $remote/$branch moved during each of $max pushes" "$out"; return 1
}
