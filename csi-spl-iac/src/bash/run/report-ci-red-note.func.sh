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
# @param CI_RED_NOTE_RUNS (optional) - default 40: runs read back for the range
# @param CI_RED_NOTE_STATE (optional) - the open streaks, default
# @param CI_RED_NOTE_STATE $XDG_STATE_HOME/csi-spl/ci-red-note.tsv
# @param CI_RED_NOTE_TO (optional) - default the dispatch lease holder
# @param CI_RED_NOTE_BOX (optional) - this box's tag, default SPOOL_BOX_TAG or
# @param CI_RED_NOTE_BOX <SPOOL_ROOT>/box.env
# @param CI_RED_NOTE_SEND (optional) - the sender, default orc's spool-send.sh
# @param CI_RED_NOTE_TASK (optional) - default dispatch-ci-red
# @param CI_GATE_WORKFLOW / CI_GATE_BRANCH / CI_GATE_REPO - as do_report_ci_gate
# @example ./run -a do_report_ci_red_note
# @example CI_RED_NOTE_TO=c-002 ./run -a do_report_ci_red_note
#------------------------------------------------------------------------------
do_report_ci_red_note() { (
  local wf="${CI_GATE_WORKFLOW:-10_ci-quality.yml}" branch="${CI_GATE_BRANCH-master}"
  local n="${CI_RED_NOTE_RUNS:-40}" top state to box
  [[ -n "${CI_GATE_REPO:-}" ]] && export GH_REPO="$CI_GATE_REPO"
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { do_log "FATAL gh and jq are required"; return 1; }
  declare -F _rcg_run_jobs >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/report-ci-gate.func.sh"
  top=$(git rev-parse --show-toplevel 2>/dev/null) || { do_log "FATAL not in a git checkout"; return 1; }
  state="${CI_RED_NOTE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/ci-red-note.tsv}"
  mkdir -p "$(dirname "$state")" && touch "$state" || { do_log "FATAL cannot write $state"; return 1; }
  to="${CI_RED_NOTE_TO:-$(_crn_holder "$top")}"
  [[ -n "$to" ]] || { do_log "FATAL no dispatch lease holder to send to"; return 1; }
  box="${CI_RED_NOTE_BOX:-$(_crn_box)}"
  if [[ "$to" == *@* && "${to#*@}" != "$box" ]]; then
    echo "OK ci-red-note: the holder $to is not on this box ($box); its box sends"; return 0
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

  local rid jid v jname sent=0
  rid=$(head -1 "$tmp/done.tsv" | cut -f1)
  while IFS=$'\t' read -r jid v jname; do
    if [[ "$v" == red ]] && ! cut -f1 "$state" | grep -xF -- "$jname" >/dev/null; then
      _crn_open "$tmp" "$top" "$state" "$to" "$jname" && sent=$((sent + 1))
    elif [[ "$v" == green ]] && cut -f1 "$state" | grep -xF -- "$jname" >/dev/null; then
      _crn_close "$state" "$to" "$jname" "$rid" && sent=$((sent + 1))
    fi
  done < <(_crn_verdicts "$tmp" "$rid")
  echo "OK ci-red-note: run $rid read, $sent note(s) sent to $to, $(wc -l <"$state") streak(s) open"
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
        timeout) v=red ;;
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

# _crn_open <tmp> <top> <state> <to> <job> - walk the finished runs newest
# first: the oldest run of the unbroken red streak is the first red, the run
# before it where the job passed the last green; send the note, record it.
_crn_open() {
  local tmp="$1" top="$2" state="$3" to="$4" job="$5"
  local rid created sha jid v fr_rid="" fr_sha="" fr_t="" fr_jid="" lg_sha="" lg_rid=""
  while IFS=$'\t' read -r rid _ created sha _; do
    IFS=$'\t' read -r jid v < <(_crn_verdicts "$tmp" "$rid" | awk -F'\t' -v j="$job" '$3 == j { print $1 "\t" $2; exit }')
    case "${v:-none}" in
      red) fr_rid=$rid fr_sha=$sha fr_t=$created fr_jid=$jid ;;
      green) lg_rid=$rid lg_sha=$sha; break ;;
    esac
  done <"$tmp/done.tsv"
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
  sig=$(cat "$tmp/timeout-$fr_jid.txt" 2>/dev/null)
  [[ -n "$sig" ]] || sig=$(gh api "repos/{owner}/{repo}/actions/jobs/$fr_jid/logs" 2>/dev/null | _rcg_signature)
  if [[ -n "$lg_sha" ]]; then
    range="$lg_sha..$fr_sha" green="run $lg_rid (sha $lg_sha)" scope="in $lg_sha..$fr_sha"
  else
    range="$fr_sha" green="none in the window" scope="up to $fr_sha (no last green: the 15 newest)"
  fi
  commits=$(git -C "$top" log --format='- %h %s' -n 15 "$range" -- "$dir" .github 2>/dev/null)
  printf '## CI red on master: %s\n\n' "$job"
  printf 'Red since run %s (sha %s, %s). Last green: %s.\n' "$fr_rid" "$fr_sha" "$fr_t" "$green"
  [[ -n "$sig" ]] || sig="(no FAIL line found in the job log)"
  printf 'Signature: %s\n\n' "${sig:0:200}"
  printf 'Suspect commits touching %s or .github %s (the first red run ends the range; superseded runs hide where it starts):\n%s\n\n' \
    "$dir" "$scope" "${commits:-- (none found in this clone: git fetch, or the range is outside $dir)}"
  printf 'One note per red streak (spec 131 C2); a green line follows when the job passes.'
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
