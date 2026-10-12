#!/bin/bash
#------------------------------------------------------------------------------
# @description ONE spool note per red job on master, per red streak (spec 131
# @description C2): nothing turned a red wf 10 job into a message, so L1 and L2
# @description of 2026-10-11 stayed red 4.2 h and 7.3 h until a lane happened
# @description to read the run list. Reads the newest finished run (success,
# @description failure, or a run with a timed-out job; do_report_ci_gate's
# @description readers). A job red there (failure or timeout; a job that
# @description gate-fail-fast.sh stopped is no verdict) that has no open streak
# @description sends ONE blocker to the dispatch lease holder: since which run
# @description and sha it is red, its last green, its signature and the
# @description commits between the two that touch the job's tree (the first
# @description red run is the END of a range: superseded runs hide the rest).
# @description A red job with an open streak sends nothing; a streak job that
# @description is green again sends one `green` line and closes the streak.
# @description Only the box of the lease holder sends, so a box-wide cron
# @description posts once. Never to an owner topic: task dispatch-ci-red.
# @description THE LANE NOTE (spec 133 action 7, L6): every box ALSO tells the
# @description lanes it hosts. A suspect commit of a red job (the commits of
# @description the job's tree in <last green>..<first red>, else the whole
# @description range) that one of this box's lane branches (<id>-<topic>)
# @description made - a `commit` entry of its reflog, or one of the commits a
# @description `rebase (finish) ... onto <base>` entry put on it - sends that
# @description lane ONE note: the job, the first FAIL line, the run link and
# @description its commits in the range. Once per red: keyed by job + first
# @description red sha in CI_RED_NOTE_LANE_STATE, dropped when the job is
# @description green. A lane whose worktree was torn down has no branch left;
# @description the holder's note still names its commits.
# @param CI_RED_NOTE_RUNS (optional) - default 40: runs read back for the range
# @param CI_RED_NOTE_STATE (optional) - the open streaks, default
# @param CI_RED_NOTE_STATE $XDG_STATE_HOME/csi-spl/ci-red-note.tsv
# @param CI_RED_NOTE_TO (optional) - default the dispatch lease holder
# @param CI_RED_NOTE_BOX (optional) - this box's tag, default SPOOL_BOX_TAG or
# @param CI_RED_NOTE_BOX <SPOOL_ROOT>/box.env
# @param CI_RED_NOTE_SEND (optional) - the sender, default orc's spool-send.sh
# @param CI_RED_NOTE_TASK (optional) - default dispatch-ci-red
# @param CI_RED_NOTE_LANES (optional) - 0 = no lane notes, default 1
# @param CI_RED_NOTE_LANE_STATE (optional) - the reds already told, default
# @param CI_RED_NOTE_LANE_STATE $XDG_STATE_HOME/csi-spl/ci-red-lane.tsv
# @param CI_GATE_WORKFLOW / CI_GATE_BRANCH / CI_GATE_REPO - as do_report_ci_gate
# @example ./run -a do_report_ci_red_note
# @example CI_RED_NOTE_TO=c-002 ./run -a do_report_ci_red_note
#------------------------------------------------------------------------------
do_report_ci_red_note() { (
  local wf="${CI_GATE_WORKFLOW:-10_ci-quality.yml}" branch="${CI_GATE_BRANCH-master}"
  local n="${CI_RED_NOTE_RUNS:-40}" top state lstate to box here=1 lanes="${CI_RED_NOTE_LANES:-1}"
  [[ -n "${CI_GATE_REPO:-}" ]] && export GH_REPO="$CI_GATE_REPO"
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { do_log "FATAL gh and jq are required"; return 1; }
  declare -F _rcg_run_jobs >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/report-ci-gate.func.sh"
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { do_log "FATAL not in a git checkout"; return 1; }
  state="${CI_RED_NOTE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/ci-red-note.tsv}"
  lstate="${CI_RED_NOTE_LANE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/ci-red-lane.tsv}"
  mkdir -p "$(dirname "$state")" "$(dirname "$lstate")" && touch "$state" "$lstate" || { do_log "FATAL cannot write $state or $lstate"; return 1; }
  to="${CI_RED_NOTE_TO:-$(_crn_holder "$top")}"
  [[ -n "$to" ]] || { do_log "FATAL no dispatch lease holder to send to"; return 1; }
  box="${CI_RED_NOTE_BOX:-$(_crn_box)}"
  if [[ "$to" == *@* && "${to#*@}" != "$box" ]]; then
    echo "OK ci-red-note: the holder $to is not on this box ($box); its box sends"; here=0
    [[ "$lanes" == 1 ]] || return 0
  fi

  local tmp; tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' EXIT
  gh run list --workflow "$wf" ${branch:+--branch "$branch"} --limit "$n" \
    --json databaseId,conclusion,createdAt,headSha,startedAt,updatedAt \
    --jq '.[] | [.databaseId, (if (.conclusion // "") == "" then "running" else .conclusion end), .createdAt, .headSha[0:8],
                 (if .startedAt and .updatedAt then ((.updatedAt | fromdate) - (.startedAt | fromdate)) else 0 end)] | @tsv' \
    >"$tmp/runs.tsv" 2>"$tmp/err" || { do_log "FATAL gh run list failed: $(head -2 "$tmp/err")"; return 1; }
  _rcg_mark_timeout_runs "$tmp"
  awk -F'\t' '$2 == "success" || $2 == "failure" || $2 == "timeout"' "$tmp/runs.tsv" >"$tmp/done.tsv"
  [[ -s "$tmp/done.tsv" ]] || { echo "OK ci-red-note: no finished run of $wf in the last $n"; return 0; }

  local rid jid v jname sent=0 told=0
  rid=$(head -1 "$tmp/done.tsv" | cut -f1)
  while IFS=$'\t' read -r jid v jname; do
    if [[ "$here" == 1 && "$v" == red ]] && ! cut -f1 "$state" | grep -xF -- "$jname" >/dev/null; then
      _crn_open "$tmp" "$top" "$state" "$to" "$jname" && sent=$((sent + 1))
    elif [[ "$here" == 1 && "$v" == green ]] && cut -f1 "$state" | grep -xF -- "$jname" >/dev/null; then
      _crn_close "$state" "$to" "$jname" "$rid" && sent=$((sent + 1))
    fi
    [[ "$lanes" == 1 ]] || continue
    if [[ "$v" == red ]]; then
      told=$((told + $(_crn_lane "$tmp" "$top" "$lstate" "$to" "$jname")))
    elif [[ "$v" == green ]]; then
      awk -F'\t' -v j="$jname" '$1 != j' "$lstate" >"$lstate.tmp" && mv "$lstate.tmp" "$lstate"
    fi
  done < <(_crn_verdicts "$tmp" "$rid")
  [[ "$here" == 1 ]] && echo "OK ci-red-note: run $rid read, $sent note(s) sent to $to, $(wc -l <"$state") streak(s) open"
  [[ "$lanes" == 1 ]] && echo "OK ci-red-note: $told lane note(s) sent to this box's lanes"
  return 0
) }

# _crn_holder <top> - the dispatch lease holder (orc's LEASE_CMD=show prints
# "<id>[@<box>] <age>").
_crn_holder() {
  ( cd "$1/csi-spl-orc" && LEASE_CMD=show ./run -a do_spl_dispatch_lease 2>/dev/null ) | awk 'NF { id = $1 } END { print id }'
}

# _crn_box - this box's tag: SPOOL_BOX_TAG, else <SPOOL_ROOT>/box.env.
_crn_box() {
  [[ -n "${SPOOL_BOX_TAG:-}" ]] && { echo "$SPOOL_BOX_TAG"; return; }
  sed -n 's/^SPOOL_BOX_TAG=//p' "${SPOOL_ROOT:-/var/spool-hub}/box.env" 2>/dev/null | tail -1
}

# _crn_verdicts <tmp> <run id> - "<job id>\t<red|green|none>\t<name>" per job:
# red = failure or timeout, not stopped by gate-fail-fast.sh; green = success.
_crn_verdicts() {
  local f="$1/verd-$2.tsv" jid c name v
  if [[ ! -f "$f" ]]; then
    _rcg_run_jobs "$1" "$2" >"$1/v-$2.tsv"
    while IFS=$'\t' read -r jid c name; do
      case "$c" in
        success) v=green ;;
        timeout|runner-lost) v=red ;;
        failure)
          v=red
          gh api "repos/{owner}/{repo}/check-runs/$jid/annotations" --jq '.[].message' 2>/dev/null |
            grep -a 'gate fail-fast: stopped' >/dev/null && v=none ;;
        *) v=none ;;
      esac
      printf '%s\t%s\t%s\n' "$jid" "$v" "$name"
    done <"$1/v-$2.tsv" >"$f"
  fi
  cat "$f"
}

# _crn_dir <job name> - the tree whose commits can turn that job red.
_crn_dir() {
  case "$1" in
    hub:*) echo csi-spl-api ;; wui:*) echo csi-spl-wui ;; orc:*) echo csi-spl-orc ;;
    iac:*) echo csi-spl-iac ;; cnf:*) echo csi-spl-cnf ;; *) echo . ;;
  esac
}

# _crn_streak <tmp> <job> - walk the finished runs newest first: the oldest
# run of the unbroken red streak is the first red, the run before it where the
# job passed the last green. Prints "<fr rid>\t<fr sha>\t<fr time>\t<fr job
# id>\t<lg rid>\t<lg sha>", nothing when the job is not red.
_crn_streak() {
  local tmp="$1" job="$2"
  local rid created sha jid v fr_rid="" fr_sha="" fr_t="" fr_jid="" lg_sha="" lg_rid=""
  while IFS=$'\t' read -r rid _ created sha _; do
    IFS=$'\t' read -r jid v < <(_crn_verdicts "$tmp" "$rid" | awk -F'\t' -v j="$job" '$3 == j { print $1 "\t" $2; exit }')
    case "${v:-none}" in
      red) fr_rid=$rid fr_sha=$sha fr_t=$created fr_jid=$jid ;;
      green) lg_rid=$rid lg_sha=$sha; break ;;
    esac
  done <"$tmp/done.tsv"
  [[ -n "$fr_rid" ]] && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$fr_rid" "$fr_sha" "$fr_t" "$fr_jid" "$lg_rid" "$lg_sha"
}

# _crn_open <tmp> <top> <state> <to> <job> - the job's streak: send the note
# to the holder, record it.
_crn_open() {
  local tmp="$1" top="$2" state="$3" to="$4" job="$5"
  local fr_rid fr_sha fr_t fr_jid lg_rid lg_sha
  IFS=$'\t' read -r fr_rid fr_sha fr_t fr_jid lg_rid lg_sha < <(_crn_streak "$tmp" "$job")
  [[ -n "$fr_rid" ]] || return 1
  local body; body=$(_crn_body "$tmp" "$top" "$job" "$fr_rid" "$fr_sha" "$fr_t" "$fr_jid" "$lg_rid" "$lg_sha")
  _crn_send "$to" "$body" || return 1
  printf '%s\t%s\t%s\n' "$job" "$fr_sha" "$fr_rid" >>"$state"
}

# _crn_body ... - the note: since when, the last green, the signature and the
# suspect commits of the job's tree in <last green>..<first red>.
_crn_body() {
  local tmp="$1" top="$2" job="$3" fr_rid="$4" fr_sha="$5" fr_t="$6" fr_jid="$7" lg_rid="$8" lg_sha="$9"
  local dir sig range commits green scope
  dir=$(_crn_dir "$job")
  sig=$(_crn_sig "$tmp" "$fr_jid")
  if [[ -n "$lg_sha" ]]; then
    range="$lg_sha..$fr_sha" green="run $lg_rid (sha $lg_sha)" scope="in $lg_sha..$fr_sha"
  else
    range="$fr_sha" green="none in the window" scope="up to $fr_sha (no last green: the 15 newest)"
  fi
  commits=$(git -C "$top" log --format='- %h %s' -n 15 "$range" -- "$dir" .github 2>/dev/null)
  printf '## CI red on master: %s\n\n' "$job"
  printf 'Red since run %s (sha %s, %s). Last green: %s.\n' "$fr_rid" "$fr_sha" "$fr_t" "$green"
  printf 'Signature: %s\n\n' "${sig:0:200}"
  printf 'Suspect commits touching %s or .github %s (the first red run ends the range; superseded runs hide where it starts):\n%s\n\n' \
    "$dir" "$scope" "${commits:-- (none found in this clone: git fetch, or the range is outside $dir)}"
  printf 'One note per red streak (spec 131 C2); a green line follows when the job passes.'
}

# _crn_sig <tmp> <job id> - the first FAIL line of the job (a timeout's own
# message, else the log, else the failure annotation), read once per run.
_crn_sig() {
  local f="$1/sig-$2.txt" sig
  if [[ ! -f "$f" ]]; then
    sig=$(cat "$1/timeout-$2.txt" 2>/dev/null)
    [[ -n "$sig" ]] || sig=$(gh api "repos/{owner}/{repo}/actions/jobs/$2/logs" 2>/dev/null | _rcg_signature)
    [[ -n "$sig" ]] || sig=$(_rcg_annotation_sig "$2")
    printf '%s\n' "${sig:-(no FAIL line in the job log, no failure annotation)}" >"$f"
  fi
  cat "$f"
}

# _crn_close <state> <to> <job> <run id> - the green line, the streak closed.
_crn_close() {
  _crn_send "$2" "CI green again on master: $3 (run $4). Streak closed (spec 131 C2)." || return 1
  awk -F'\t' -v j="$3" '$1 != j' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# _crn_send <to> <body> - one blocker to the holder on the CI-red task.
_crn_send() {
  local send="${CI_RED_NOTE_SEND:-$(git rev-parse --show-toplevel)/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  bash "$send" --from "${CI_RED_NOTE_FROM:-${1%@*}}" --to "$1" --kind blocker \
    --task "${CI_RED_NOTE_TASK:-dispatch-ci-red}" --body "$2" >/dev/null
}

# _crn_lane <tmp> <top> <lane state> <to> <job> - ONE note per red streak to
# each lane of THIS box that made a suspect commit (see the description).
# Prints how many lanes were told.
_crn_lane() {
  local tmp="$1" top="$2" lstate="$3" to="$4" job="$5"
  local fr_rid fr_sha fr_t fr_jid lg_rid lg_sha dir told=0 id
  IFS=$'\t' read -r fr_rid fr_sha fr_t fr_jid lg_rid lg_sha < <(_crn_streak "$tmp" "$job")
  [[ -n "$fr_rid" ]] || { echo 0; return 0; }
  if awk -F'\t' -v j="$job" -v s="$fr_sha" '$1 == j && $2 == s { f = 1 } END { exit !f }' "$lstate"; then
    echo 0; return 0
  fi
  local -a range=("$fr_sha" -n 15)
  [[ -n "$lg_sha" ]] && range=("$lg_sha..$fr_sha")
  dir=$(_crn_dir "$job")
  git -C "$top" log --format=%H -n 30 "${range[@]}" -- "$dir" .github >"$tmp/suspects" 2>/dev/null
  [[ -s "$tmp/suspects" ]] || git -C "$top" log --format=%H -n 30 "${range[@]}" -- >"$tmp/suspects" 2>/dev/null
  [[ -f "$tmp/lane-shas" ]] || _crn_lane_shas "$top" >"$tmp/lane-shas"
  awk -F'\t' 'NR == FNR { s[$1] = 1; next } ($1 in s) { print $2 "\t" $1 }' "$tmp/suspects" "$tmp/lane-shas" \
    | sort -u >"$tmp/hits"
  local run sig mine body
  run=$(gh api "repos/{owner}/{repo}/actions/jobs/$fr_jid" --jq '.html_url' 2>/dev/null)
  sig=$(_crn_sig "$tmp" "$fr_jid")
  for id in $(cut -f1 "$tmp/hits" | sort -u); do
    mine=$(awk -F'\t' -v i="$id" '$1 == i { print $2 }' "$tmp/hits" |
           while read -r h; do git -C "$top" log -1 --format='- %h %s' "$h"; done)
    body=$(printf '## CI red on master: %s\n\nA job on master is red since run %s (sha %s), and your lane made a commit in its suspect range.\n\n- Job: %s\n- First FAIL line: %s\n- Run: %s\n- Last green: %s\n\nYour commits in the range:\n%s\n\nIf it is yours: fix it, rebase, push. If not: tell %s. One note per red (spec 133 action 7).' \
      "$job" "$fr_rid" "$fr_sha" "$job" "${sig:0:200}" "${run:-run $fr_rid, job $fr_jid}" \
      "${lg_sha:+run $lg_rid (sha $lg_sha)}${lg_sha:-none in the window}" "$mine" "$to")
    _crn_send_lane "$id" "${to%@*}" "$body" && told=$((told + 1))
  done
  printf '%s\t%s\t%s\n' "$job" "$fr_sha" "$fr_rid" >>"$lstate"
  echo "$told"
}

# _crn_lane_shas <top> - "<sha>\t<agent id>" for every commit a lane branch of
# this checkout (<id>-<topic>, the id as next-agent-id.sh mints it) made: each
# `commit` entry of the branch reflog, and each commit a `rebase (finish)`
# entry put on top of its `onto` base. A branch a lane only fast-forwarded or
# reset to master claims nothing.
_crn_lane_shas() {
  local b id sha gs
  git -C "$1" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null |
    grep -E '^[a-z]-[0-9]{3,}-.' | while read -r b; do
      id="${b%%-*}-$(cut -d- -f2 <<<"$b")"
      git -C "$1" log -g --format='%H %gs' "refs/heads/$b" -- 2>/dev/null | while read -r sha gs; do
        case "$gs" in
          commit*) printf '%s\t%s\n' "$sha" "$id" ;;
          *"(finish): "*" onto "*)
            git -C "$1" rev-list "${gs##* onto }..$sha" -- 2>/dev/null | sed "s/\$/\t$id/" ;;
        esac
      done
    done
}

# _crn_send_lane <lane id> <from> <body> - the lane note, on the CI-red task.
_crn_send_lane() {
  local send="${CI_RED_NOTE_SEND:-$(git rev-parse --show-toplevel)/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  bash "$send" --from "${CI_RED_NOTE_FROM:-$2}" --to "$1" --kind note \
    --task "${CI_RED_NOTE_TASK:-dispatch-ci-red}" --body "$3" >/dev/null
}
