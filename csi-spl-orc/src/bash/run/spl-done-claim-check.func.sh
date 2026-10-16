#!/bin/bash
#------------------------------------------------------------------------------
# @description A lane's "done" claim is checked against the repository (owner
# @description HUM-10, t1 b61851fb, poll answer c5c9687b row D2; SPL-2265): a
# @description lane closed itself before its push was refused, and its result
# @description read like a landing. Plain coded checks, no language parsing
# @description beyond the hex sha (owner: "the less intelligence, the better"):
# @description   - every spool message of kind result from a LANE (c-/m-/a-/g-/q-
# @description     id, number above 003: 001..003 are the role seats, spec 061
# @description     Q1) in the last DONE_CLAIM_DAYS_H hours, read from every
# @description     inbox, archive and outbox under the spool root, once per
# @description     msg_id; a lane of another box (from <id>@<box>) is that
# @description     box's check; a result a lane sends ITSELF (to = from: the
# @description     lane-rotate ACK) claims nothing to anyone and is skipped
# @description   - every token of 9..40 lowercase hex with at least one letter
# @description     a..f is a sha (a UUID is cut out first; an all-digit token
# @description     is a run id, not a sha)
# @description   - DONE_CLAIM_AGE_MIN (15) minutes after the message: a git
# @description     fetch of each repo in DONE_CLAIM_REPO_DIRS, then each sha
# @description     must resolve in one of them and be an ancestor of that
# @description     repo's trunk (origin/master, else origin/main): a sha of
# @description     another repo is checked in that repo
# @description   - a result with NO sha, or with a sha on no trunk -> ONE note
# @description     to the dispatch lease holder (lane, msg id, the shas, "not
# @description     in the repository"); every decided message goes to the
# @description     ledger (seen.tsv: msg_id, verdict, epoch) and is never
# @description     judged again
# @description Standing: the box cron done-claim-check (every 5 min). Prints one
# @description TSV row per decided message (msg_id, lane, landed | alert |
# @description would-alert, shas or no-sha). DRY_RUN=1 (default) reads and
# @description fetches but sends nothing and writes no ledger.
# @param DRY_RUN (optional) - 0 sends the notes and writes the ledger; default 1
# @param DONE_CLAIM_AGE_MIN (optional) - minutes after the result before it is judged, default 15
# @param DONE_CLAIM_DAYS_H (optional) - hours of results read, default 24
# @param DONE_CLAIM_REPO_DIRS (optional) - space-separated clones whose trunks count; default the repo holding this tree
# @param DONE_CLAIM_FETCH (optional) - 1 (default) fetches each repo before the check
# @param DONE_CLAIM_STATE_DIR (optional) - the ledger's dir, default $XDG_STATE_HOME/csi-spl/done-claim-check
# @param DONE_CLAIM_BOX (optional) - this box's id (a lane <id>@<other box> is skipped); default the desk box
# @param DONE_CLAIM_TO (optional) - the recipient; default the dispatch lease holder, else LEASE_ORCH
# @param DONE_CLAIM_FROM (optional) - the sender id, default c-001
# @param DONE_CLAIM_SEND (optional) - the sender script (the tests stub it), default spool-send.sh
# @param DONE_CLAIM_NOW (optional) - an epoch for the clock (tests)
# @example DRY_RUN=1 ./run -a do_spl_done_claim_check
#------------------------------------------------------------------------------
do_spl_done_claim_check() {
  local v age="${DONE_CLAIM_AGE_MIN:-15}" hours="${DONE_CLAIM_DAYS_H:-24}" now dry="${DRY_RUN:-1}"
  for v in "$age" "$hours"; do
    [[ "$v" =~ ^[0-9]+$ ]] || { do_log "FATAL DONE_CLAIM_AGE_MIN and DONE_CLAIM_DAYS_H must be whole numbers"; return 1; }
  done
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  now="${DONE_CLAIM_NOW:-$(date +%s)}"
  local state="${DONE_CLAIM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/done-claim-check}"
  local root="${SPOOL_ROOT:-/var/spool-hub}" box tmp rc=0
  box="${DONE_CLAIM_BOX:-$(spl_desk_box_default)}"
  tmp="$(mktemp -d)" || return 1
  touch "$tmp/seen"
  [[ -f "$state/seen.tsv" ]] && cut -f1 "$state/seen.tsv" >"$tmp/seen"
  spl_done_claim_results "$root" "$((now - hours * 3600))" "$((now - age * 60))" "$box" "$tmp/seen" >"$tmp/due"
  if [[ ! -s "$tmp/due" ]]; then
    echo "OK done-claim-check: no lane result older than $age min left to judge"; rm -rf "$tmp"; return 0
  fi
  spl_done_claim_repos >"$tmp/repos" || { rm -rf "$tmp"; return 1; }
  local to=""
  if [[ "$dry" == 0 ]]; then to="$(spl_done_claim_to)" || { rm -rf "$tmp"; return 1; }; fi
  local id from ts task body shas bad verdict n_alert=0 n_ok=0
  while IFS=$'\t' read -r id from ts task body; do
    shas="$(spl_done_claim_shas "$body")"
    bad="$(spl_done_claim_missing "$tmp/repos" "$shas")"
    if [[ -n "$shas" && -z "$bad" ]]; then
      verdict=landed; n_ok=$((n_ok + 1))
    elif [[ "$dry" == 1 ]]; then
      verdict=would-alert; n_alert=$((n_alert + 1))
    else
      spl_done_claim_note "$from" "$id" "$ts" "$task" "$bad" "$tmp/repos" >"$tmp/note"
      spl_done_claim_send "$to" "$tmp/note" || { rc=1; continue; }
      verdict=alert; n_alert=$((n_alert + 1))
    fi
    printf '%s\t%s\t%s\t%s\n' "$id" "$from" "$verdict" "${shas:-no-sha}"
    if [[ "$dry" == 0 ]]; then
      { mkdir -p "$state" && printf '%s\t%s\t%s\n' "$id" "$verdict" "$now" >>"$state/seen.tsv"; } || rc=1
    fi
  done <"$tmp/due"
  if [[ "$dry" == 0 ]]; then
    spl_done_claim_prune "$state/seen.tsv" "$((now - 2 * hours * 3600))"
    echo "OK done-claim-check: $n_ok landed, $n_alert alerted to $to"
  else
    echo "OK done-claim-check: $n_ok landed, $n_alert would alert (DRY_RUN=1: nothing sent, no ledger)"
  fi
  rm -rf "$tmp"
  return $rc
}

# spl_done_claim_results <root> <from-epoch> <before-epoch> <box> <seen>: one
# TSV row (msg_id, from, ts, task_id, body with tabs and newlines as spaces)
# per lane result to another id with from-epoch <= ts <= before-epoch and msg_id not in
# <seen>, oldest first. A file not modified in the window is not opened.
spl_done_claim_results() {
  local root="$1" lo="$2" hi="$3" box="$4" seen="$5" mins
  mins=$(( ($(date +%s) - lo) / 60 + 60 ))
  (( mins > 0 )) || mins=60
  find "$root" -mindepth 3 -maxdepth 3 \( -path '*/inbox/*' -o -path '*/archive/*' -o -path '*/outbox/*' \) \
    -name '*.json' -mmin "-$mins" -print0 2>/dev/null |
    xargs -0 -r grep -lZE '"kind": *"result"' 2>/dev/null |
    xargs -0 -r jq -r 'select(.kind == "result" and (.msg_id | type) == "string" and (.from | type) == "string")
      | [.msg_id, .from, (((.ts // "") | sub("\\.[0-9]+"; "") | fromdateiso8601?) // 0 | tostring),
         (.ts // ""), (.task_id // ""), ((.body // "") | gsub("[\t\r\n]"; " ")), ((.to // "") | tostring)] | @tsv' 2>/dev/null |
    awk -F'\t' -v lo="$lo" -v hi="$hi" -v box="$box" -v seen="$seen" '
      BEGIN { while ((getline l < seen) > 0) done[l] = 1 }
      {
        id = $1; from = $2; e = $3 + 0
        if (id in done || id in got) next
        if (from !~ /^[cmagq]-[0-9][0-9][0-9][0-9]*(@[a-z0-9-]+)?$/) next
        n = from; sub(/@.*/, "", n); sub(/^[cmagq]-/, "", n); if (n + 0 <= 3) next
        if (index(from, "@") && substr(from, index(from, "@") + 1) != box) next
        to = $7; sub(/@.*/, "", to); f = from; sub(/@.*/, "", f); if (to == f) next
        if (e < lo || e > hi) next
        got[id] = 1
        print e "\t" id "\t" from "\t" $4 "\t" $5 "\t" $6
      }' | sort -n -k1,1 | cut -f2-
}

# spl_done_claim_shas <body>: the distinct hex tokens of 9..40 chars holding a
# letter a..f, UUIDs cut out first; one line, space-separated.
spl_done_claim_shas() {
  sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/ /g' <<<"$1" |
    tr -c '0-9A-Za-z' '\n' | grep -xE '[0-9a-f]{9,40}' | grep '[a-f]' | awk '!s[$0]++' | paste -sd' ' -
}

# spl_done_claim_repos: one line per repo of DONE_CLAIM_REPO_DIRS (default the
# repo holding this tree): "<top dir> <trunk ref>", fetched first unless
# DONE_CLAIM_FETCH=0. A repo that cannot be read is a FATAL: a missing clone
# must not turn every sha into an alert.
spl_done_claim_repos() {
  local d top ref rc=0
  # shellcheck disable=SC2086 # a space-separated list, split on purpose
  for d in ${DONE_CLAIM_REPO_DIRS:-$PROJ_PATH}; do
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || { do_log "FATAL $d is not a git repo" >&2; rc=1; continue; }
    if [[ "${DONE_CLAIM_FETCH:-1}" == 1 ]]; then
      git -C "$top" fetch -q origin 2>/dev/null || { do_log "FATAL git fetch origin failed in $top" >&2; rc=1; continue; }
    fi
    ref=""
    for ref in origin/master origin/main; do git -C "$top" rev-parse -q --verify "$ref^{commit}" >/dev/null && break; ref=""; done
    [[ -n "$ref" ]] || { do_log "FATAL $top has neither origin/master nor origin/main" >&2; rc=1; continue; }
    echo "$top $ref"
  done
  return $rc
}

# spl_done_claim_missing <repos file> <shas>: the shas on no repo's trunk (a
# sha that resolves in a repo and is an ancestor of its trunk has landed).
spl_done_claim_missing() {
  local s top ref ok out=()
  for s in $2; do
    ok=0
    while read -r top ref; do
      git -C "$top" rev-parse -q --verify "$s^{commit}" >/dev/null 2>&1 &&
        git -C "$top" merge-base --is-ancestor "$s" "$ref" 2>/dev/null && { ok=1; break; }
    done <"$1"
    (( ok )) || out+=("$s")
  done
  echo "${out[*]}"
}

# The recipient: DONE_CLAIM_TO, else the dispatch lease holder as the lease
# names it (<id>@<box> on a fleet), else LEASE_ORCH from lease.conf.
spl_done_claim_to() {
  [[ -n "${DONE_CLAIM_TO:-}" ]] && { echo "$DONE_CLAIM_TO"; return 0; }
  spl_lease_init ro || return 1
  spl_lease_conf
  spl_lease_read
  if [[ "$LH" != none && "$LH" != *@unreachable ]]; then echo "$LH"
  elif [[ -n "${LEASE_ORCH:-}" ]]; then echo "$LEASE_ORCH"
  else do_log "FATAL no dispatch lease holder and no LEASE_ORCH: nobody to tell"; return 1; fi
}

# spl_done_claim_note <lane> <msg id> <ts> <task> <missing shas> <repos file>: the body.
spl_done_claim_note() {
  local what="sha ${5// /, }"
  [[ -z "$5" ]] && what="no sha"
  printf 'done-claim check: %s result %s (%s, task %s): %s not in the repository\n\n' "$1" "$2" "$3" "${4:-none}" "$what"
  printf -- '- checked %s min after the result, on: %s\n' "${DONE_CLAIM_AGE_MIN:-15}" \
    "$(awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }' "$6")"
  printf -- '- rule: a lane result names a sha on the trunk (SPL-2265); one note per message\n'
}

# spl_done_claim_send <to> <body file>: one spool note on task done-claim-check.
spl_done_claim_send() {
  local send="${DONE_CLAIM_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "${DONE_CLAIM_FROM:-c-001}" --to "$1" \
    --kind note --task done-claim-check --body-file "$2" >/dev/null 2>&1 8>&- 9>&- ||
    { do_log "WARN could not send the done-claim note to $1"; return 1; }
}

# spl_done_claim_prune <ledger> <epoch>: drop rows older than <epoch>.
spl_done_claim_prune() {
  [[ -f "$1" ]] || return 0
  awk -F'\t' -v lo="$2" '$3 >= lo' "$1" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}
