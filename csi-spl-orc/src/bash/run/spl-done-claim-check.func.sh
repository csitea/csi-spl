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
# @description   - every token of 9..12 or 40 lowercase hex with at least one
# @description     letter a..f is a sha (a UUID is cut out first; an all-digit
# @description     token is a sha only when `git cat-file -t` names a commit in
# @description     a repo, SPL-2706, else a run id; a 32-hex md5 or a token
# @description     right after an "md5" label is a file hash, SPL-2332; a
# @description     relay run-on-box request id (gr-cmd-<hex>, also .zip, or
# @description     a token right after a "gr-cmd" / "request id" / "req"
# @description     label) is no sha, SPL-2953: c-368's "gr-cmd-890b4562175b";
# @description     a commit
# @description     reachable from origin's refs/notes/*, the release notes, is
# @description     no code, SPL-2560; a tree, a blob or a tag of no commit
# @description     is no sha, SPL-2831: c-734's "(tree cefedf318)"); SPL-2338:
# @description     when a line of the body starts with the word sha / shas
# @description     ("sha:", "- **sha**:", "SHA:") and holds a sha, only those
# @description     lines are the claim (a sha quoted on another line is
# @description     context, not a landing); with none, every sha of the body
# @description   - DONE_CLAIM_AGE_MIN (15) minutes after the message: a git
# @description     fetch of each repo in DONE_CLAIM_REPO_DIRS (its notes refs
# @description     too, into refs/done-claim/notes/*: the local ones are never
# @description     overwritten), then each sha
# @description     must resolve in one of them and be an ancestor of that
# @description     repo's trunk (origin/master, else origin/main), or carry a
# @description     patch already on it (`git cherry` "-": a review-branch sha
# @description     landed under a new sha by a rebase); a sha of another repo
# @description     is checked in that repo; SPL-2420: the cnf's customer
# @description     repos (env.box.landed_repos, resolved by spl_landed_repo of
# @description     spl-lane-issue.func.sh) whose clone is on this box are
# @description     repos too (a csi-rel sha on its master is landed)
# @description   - SPL-2930: the sender lane's OWN repo counts too, resolved
# @description     from its worktree (registry.tsv col 4, else its newest
# @description     workdirs.tsv row) by `git rev-parse --git-common-dir`: a
# @description     lane landing in a repo of no cnf list (c-179's
# @description     sha) is judged there; a failed fetch of it keeps its last
# @description     fetched trunk and the row and the note say so
# @description   - SPL-3020 (alerts 5bc7078d, 2d6c1619): a sha the check could
# @description     not judge is verdict unchecked, "not checked (<why>)": a sha
# @description     that resolves only in a repo whose fetch failed, or that is
# @description     no object in any repo while a repo failed its fetch or the
# @description     sender lane's own repo was never read (no worktree known, no
# @description     trunk). No note, no ledger: judged again next run. Only a
# @description     sha absent from a repo read fresh alerts
# @description   - SPL-3020: a repo whose trunk is LOCAL by design (never pushed
# @description     from this box) says so in its own clone, `git config
# @description     spool.localTrunk <branch>` (box-local: a customer repo is
# @description     named in no public cnf); it is judged on refs/heads/<branch>,
# @description     never fetched
# @description   - a result with NO sha, or with a sha on no trunk -> ONE note
# @description     to the dispatch lease holder (lane, msg id, the shas, "not
# @description     in the repository"); every decided message goes to the
# @description     ledger (seen.tsv: msg_id, verdict, epoch) and is never
# @description     judged again
# @description   - SPL-2313, read from metadata we write, never the body: a lane
# @description     whose slug marks a seat, reviewer or plan lane (its LAST
# @description     word, once a trailing vendor, takeover or spl key is cut,
# @description     is seat / seatN / review / reviewer / plan / planner: not
# @description     "skip-seat-lanes") is verdict seat, sha or not (a reviewer cites the
# @description     reviewed sha, by design not on trunk): ledger, no note. The
# @description     slug is the lane's worktree branch (git worktree list of
# @description     each repo, branch <id>-<slug>) or its retired row in
# @description     $SPOOL_ROOT/workdirs.tsv (agent, branch); SPL-2838: a lane
# @description     whose worktree is a detached HEAD (an R7 reviewer on the
# @description     reviewed sha) or whose retired row has no branch takes its
# @description     spawn's local branch <id>-<slug> instead; SPL-2916: ids are
# @description     recycled, so only the id's LATEST slug counts: its live
# @description     worktrees' branches (each must mark it), else for a live
# @description     detached worktree its newest local <id>-<slug> branch (tip
# @description     commit date), else its newest retired row (finished_at); a
# @description     lane with none is judged as before
# @description   - SPL-2916: a result whose first line is an R7 review line
# @description     (`review: <id>[@<box>] [<vendor>] PASS|FAIL ...`, the format
# @description     do_spl_review_line_check reads) is verdict seat: it names the
# @description     reviewed branch sha, never a landing
# @description   - a sha on no trunk but on a remote branch origin/<id>-...,
# @description     origin/review/<id>-... or origin/wip/<id>-... of a lane
# @description     still in this box's registry.tsv is verdict pending: no
# @description     note, no ledger, judged again next run; it alerts once
# @description     that lane is retired. SPL-3116 (msg b494ec3c, n=4 of 4
# @description     notes 20:25-20:45Z 10-23 were review requests on
# @description     origin/review/s107-v2-t020..t022): a review/ or wip/ branch
# @description     with no <id>- prefix is the SENDING lane's, pending while
# @description     it is in registry.tsv; a branch named for another id stays
# @description     that id's; a sha on no branch alerts as before
# @description   - SPL-3261 (notes 68215ba2, d72ab6e0): such a branch is also
# @description     the lane's of registry.tsv whose worktree branch ends in
# @description     -<topic> (an R7 reviewer citing its author's sha); a line
# @description     "landed:" / "landed sha:" / "trunk sha:" is the claim ahead
# @description     of the sha lines; a rotation branch <id>-rotate[-N] is no
# @description     slug (the id keeps its previous one)
# @description   - SPL-2327: a sha that is no object in any repo (a rebase in
# @description     another tree) is verdict rewritten (landed, no note) when
# @description     EXACTLY one trunk commit after the lane's spawn (registry.tsv,
# @description     else 48 h) has an SPL-n key of the result in its subject; zero
# @description     or several alert "not an object in any repository"
# @description   - SPL-3673 (alarms 166d17f7, c4933166, bb60fd55: c-271's shas on
# @description     origin/review/grok-dispatch-grade read "not in the
# @description     repository"): a sha on no trunk that `git branch -r
# @description     --contains` finds on origin/review/* is "on review branch
# @description     <name>, not on <trunk>" in the row and the note; verdict
# @description     review (ledger, no note) when every such sha is on one and
# @description     the body says it is not landed ("not on master|main|trunk",
# @description     "not landed", "unlanded", "on a review branch"); a sha on
# @description     no branch alerts as before
# @description Standing: the box cron done-claim-check (every 5 min). Prints one
# @description TSV row per decided message (msg_id, lane, landed | rewritten |
# @description seat | pending | unchecked | review | alert | would-alert, shas or no-sha). DRY_RUN=1 (default) reads and
# @description fetches but sends nothing and writes no ledger.
# @param DRY_RUN (optional) - 0 sends the notes and writes the ledger; default 1
# @param DONE_CLAIM_AGE_MIN (optional) - minutes after the result before it is judged, default 15
# @param DONE_CLAIM_DAYS_H (optional) - hours of results read, default 24
# @param DONE_CLAIM_REPO_DIRS (optional) - space-separated clones whose trunks count; default the repo holding this tree; the cnf's customer repos (env.box.landed_repos, SPL-2420) whose clone is on this box always count too, and each sender lane's own repo (SPL-2930)
# @param DONE_CLAIM_FETCH (optional) - 1 (default) fetches each repo before the check
# @param DONE_CLAIM_STATE_DIR (optional) - the ledger's dir, default $XDG_STATE_HOME/csi-spl/done-claim-check
# @param DONE_CLAIM_BOX (optional) - this box's id (a lane <id>@<other box> is skipped); default the desk box
# @param DONE_CLAIM_TO (optional) - the recipient; default the dispatch lease holder, else LEASE_ORCH
# @param DONE_CLAIM_FROM (optional) - the sender id, default role seat 1 in its live vendor letter (spl_role_seat 1)
# @param DONE_CLAIM_SEND (optional) - the sender script (the tests stub it), default spool-send.sh
# @param DONE_CLAIM_NOW (optional) - an epoch for the clock (tests)
# @example DRY_RUN=1 ./run -a do_spl_done_claim_check
#------------------------------------------------------------------------------
# spl_role_seat: the role seat ids in their live vendor letter (SPL-1695)
declare -F spl_role_seat >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"
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
  : >"$tmp/unchk"
  spl_done_claim_repos "$tmp/unchk" >"$tmp/repos" || { rm -rf "$tmp"; return 1; }
  spl_done_claim_lane_repos "$root" "$tmp/due" "$tmp/repos" "$tmp/unchk" >"$tmp/stale"
  local to=""
  if [[ "$dry" == 0 ]]; then to="$(spl_done_claim_to)" || { rm -rf "$tmp"; return 1; }; fi
  spl_done_claim_seats "$root" "$tmp/repos" >"$tmp/seats"
  awk -F'\t' '$1 ~ /^[cmagq]-[0-9]+$/ { print $1 }' "$root/registry.tsv" 2>/dev/null >"$tmp/live"
  local id from ts task body shas bad unchk rv verdict stale n_alert=0 n_ok=0 n_seat=0 n_wait=0 n_rew=0 n_unchk=0 n_rev=0
  while IFS=$'\t' read -r id from ts task body; do
    shas="$(spl_done_claim_notes "$tmp/repos" "$(spl_done_claim_shas "$body" "$tmp/repos")")"
    bad="" unchk="" rv=""
    if spl_done_claim_r7 "$body" || grep -qxF -- "${from%@*}" "$tmp/seats"; then
      verdict=seat; n_seat=$((n_seat + 1))
    elif bad="$(spl_done_claim_missing "$tmp/repos" "$shas")" && [[ -n "$shas" && -z "$bad" ]]; then
      verdict=landed; n_ok=$((n_ok + 1))
    elif [[ -n "$bad" && "$(spl_done_claim_unknown "$tmp/repos" "$bad")" == "$bad" ]] &&
      spl_done_claim_rewrite "$tmp/repos" "$body" "$(spl_done_claim_since "$root" "${from%@*}" "$now")"; then
      verdict=rewritten; n_rew=$((n_rew + 1))
    elif unchk="$(spl_done_claim_unchecked "$tmp/repos" "$tmp/unchk" "${from%@*}" "$bad")" &&
      bad="$(spl_done_claim_minus "$bad" "$unchk")" && [[ -n "$unchk" && -z "$bad" ]]; then
      verdict=unchecked; n_unchk=$((n_unchk + 1))
    elif [[ -n "$bad" && -z "$(spl_done_claim_unparked "$tmp/repos" "$tmp/live" "$bad" "${from%@*}" "$root")" ]]; then
      verdict=pending; n_wait=$((n_wait + 1))
    elif rv="$(spl_done_claim_on_review "$tmp/repos" "$bad")" && [[ -n "$rv" && "$(cut -f1 <<<"$rv" | xargs)" == "$bad" ]] &&
      spl_done_claim_unlanded "$body"; then
      verdict=review; n_rev=$((n_rev + 1))
    elif [[ "$dry" == 1 ]]; then
      verdict=would-alert; n_alert=$((n_alert + 1))
    else
      spl_done_claim_note "$from" "$id" "$ts" "$task" "$bad" "$tmp/repos" "$tmp/stale" "$unchk" >"$tmp/note"
      spl_done_claim_send "$to" "$tmp/note" || { rc=1; continue; }
      verdict=alert; n_alert=$((n_alert + 1))
    fi
    stale="$(spl_done_claim_stale "$tmp/stale" "$from")"
    [[ -n "$unchk" ]] && stale="$(spl_done_claim_unchk_text "$unchk")${stale:+; $stale}"
    [[ "$verdict" == review ]] && stale="$(spl_done_claim_review_text "$rv")${stale:+; $stale}"
    printf '%s\t%s\t%s\t%s%s\n' "$id" "$from" "$verdict" "${shas:-no-sha}" "${stale:+$'\t'$stale}"
    if [[ "$dry" == 0 && "$verdict" != pending && "$verdict" != unchecked ]]; then
      { mkdir -p "$state" && printf '%s\t%s\t%s\n' "$id" "$verdict" "$now" >>"$state/seen.tsv"; } || rc=1
    fi
  done <"$tmp/due"
  if [[ "$dry" == 0 ]]; then
    spl_done_claim_prune "$state/seen.tsv" "$((now - 2 * hours * 3600))"
    echo "OK done-claim-check: $n_ok landed, $n_rew rewritten, $n_seat seat, $n_wait pending, $n_unchk not checked, $n_alert alerted to $to, $n_rev on a review branch"
  else
    echo "OK done-claim-check: $n_ok landed, $n_rew rewritten, $n_seat seat, $n_wait pending, $n_unchk not checked, $n_alert would alert, $n_rev on a review branch (DRY_RUN=1: nothing sent, no ledger)"
  fi
  rm -rf "$tmp"
  return $rc
}

# spl_done_claim_results <root> <from-epoch> <before-epoch> <box> <seen>: one
# TSV row (msg_id, from, ts, task_id, body with tabs as spaces, newlines as \x1f)
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
         (.ts // ""), (.task_id // ""), ((.body // "") | gsub("[\t\r]"; " ") | gsub("\n"; "\u001f")), ((.to // "") | tostring)] | @tsv' 2>/dev/null |
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

# spl_done_claim_shas <body> [repos file]: the shas the result CLAIMS (SPL-2338). When a
# line of <body> (lines split on \x1f) starts with the word sha or shas, after
# list marks and bold (`sha:`, `- **sha**:`, `- **Sha:**`, `SHA:`), and one of
# those lines holds a sha, only those lines count: a sha quoted on another line
# (another lane's, another repo's, a reverted one) is context. Else every sha
# of the body, as before. One line, space-separated. SPL-3261 (c-913's
# 12472906: "- Landed: <sha>" beside "Range-diff, reviewed <review sha> ..."):
# a line starting with "landed:", "landed sha:" or "trunk sha:" counts ahead of
# the sha lines; "commit:" is too generic and is not one. Range-diff lines are
# not dropped: with a Landed line they are not read anyway. The cost: a Landed
# line hides every other sha of the body, the lane's own unlanded one too
# (case B3), the same risk a sha line carries since SPL-2338.
spl_done_claim_shas() {
  local claim lines
  lines="$(tr '\037' '\n' <<<"$1")"
  claim="$(grep -iE '^[[:space:]>*+_`-]*(landed( sha)?|trunk sha)[*_`]*:' <<<"$lines" | spl_done_claim_tokens "${2:-}")"
  [[ -n "$claim" ]] || claim="$(grep -iE '^[[:space:]>*+_`-]*shas?[*_`]*([[:space:]]|:|$)' <<<"$lines" | spl_done_claim_tokens "${2:-}")"
  [[ -n "$claim" ]] || claim="$(spl_done_claim_tokens "${2:-}" <<<"$1")"
  echo "$claim"
}

# spl_done_claim_tokens [repos file] (stdin): the distinct hex tokens of 9..12
# or 40 chars, UUIDs and the token after an "md5" label cut out first, and a
# run-on-box request id (gr-cmd-<hex>[.zip], the token after a "gr-cmd",
# "request id" or "req" label; SPL-2953); one line, space-separated. 13..39
# hex (a 32-hex md5) is no git sha. A token that
# is a tree, a blob or a tag of no commit in a repo of [repos file] is no sha
# (c-734's "(tree cefedf318)"); an all-digit token counts only when it is a
# commit (SPL-2706: c-597's "sha: 704617890" read as no sha), else a run id.
spl_done_claim_tokens() {
  sed -E -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/ /g' \
    -e 's/(^|[^0-9a-zA-Z])md5(sum)?[^0-9a-zA-Z]+[0-9a-fA-F]+([^0-9a-zA-Z]|$)/\1 \3/gI' \
    -e 's/(^|[^0-9a-zA-Z])(gr-cmd|request[ _-]?id|req)[^0-9a-zA-Z]+[0-9a-fA-F]+([^0-9a-zA-Z]|$)/\1 \3/gI' |
    tr -c '0-9A-Za-z' '\n' | grep -xE '[0-9a-f]{9,12}|[0-9a-f]{40}' | awk '!s[$0]++' |
    spl_done_claim_commits "${1:-}" | paste -sd' ' -
}

# spl_done_claim_commits [repos file] (stdin): the tokens that are a commit (or
# a tag of one) in a repo of [repos file], and the lettered ones that are no
# object in any (a pre-rebase sha, judged later). A tree, a blob or a tag of
# no commit is dropped, as is an all-digit token that is no commit (a run id).
spl_done_claim_commits() {
  local t top ref kind
  while read -r t; do
    kind=none
    if [[ -n "$1" && -f "$1" ]]; then
      while read -r top ref; do
        git -C "$top" cat-file -e "$t" 2>/dev/null || continue
        git -C "$top" rev-parse -q --verify "$t^{commit}" >/dev/null 2>&1 && { kind=commit; break; }
        kind=other
      done <"$1"
    fi
    [[ "$kind" == commit || ( "$kind" == none && "$t" =~ [a-f] ) ]] && echo "$t"
  done
}

# spl_done_claim_notes <repos file> <shas>: <shas> without the commits
# reachable from a notes ref (refs/notes/*, or origin's fetched into
# refs/done-claim/notes/*) of any repo: a release-notes commit quoted in a
# result is no claim (SPL-2560, c-461's fc9aca8e0). One line, space-separated.
spl_done_claim_notes() {
  local s full top ref notes out=()
  for s in $2; do
    notes=0
    while read -r top ref; do
      full="$(git -C "$top" rev-parse -q --verify "$s^{commit}" 2>/dev/null)" || continue
      [[ -n "$(git -C "$top" for-each-ref --count=1 --contains "$full" refs/notes refs/done-claim/notes 2>/dev/null)" ]] && { notes=1; break; }
    done <"$1"
    (( notes )) || out+=("$s")
  done
  echo "${out[*]}"
}

# spl_done_claim_repos [unchecked file]: one line per repo of DONE_CLAIM_REPO_DIRS (default the
# repo holding this tree): "<top dir> <trunk ref>", fetched first (with
# origin's notes refs, SPL-2560) unless DONE_CLAIM_FETCH=0; a local-trunk repo
# (SPL-3020) is its local branch, unfetched. A repo that cannot be read is a FATAL: a missing clone
# must not turn every sha into an alert. Then the cnf's customer repos whose
# clone is on this box (spl_done_claim_landed_repos, SPL-2420).
spl_done_claim_repos() {
  local d top ref rc=0 listed=""
  # shellcheck disable=SC2086 # a space-separated list, split on purpose
  for d in ${DONE_CLAIM_REPO_DIRS:-$PROJ_PATH}; do
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || { do_log "FATAL $d is not a git repo" >&2; rc=1; continue; }
    if ref="$(spl_done_claim_local_trunk "$top")"; then echo "$top $ref"; listed+="$top "; continue; fi
    if [[ "${DONE_CLAIM_FETCH:-1}" == 1 ]]; then
      git -C "$top" fetch -q origin 2>/dev/null || { do_log "FATAL git fetch origin failed in $top" >&2; rc=1; continue; }
      git -C "$top" fetch -q origin '+refs/notes/*:refs/done-claim/notes/*' 2>/dev/null ||
        do_log "WARN git fetch of the notes refs failed in $top: a notes sha may alert" >&2
    fi
    ref=""
    for ref in origin/master origin/main; do git -C "$top" rev-parse -q --verify "$ref^{commit}" >/dev/null && break; ref=""; done
    [[ -n "$ref" ]] || { do_log "FATAL $top has neither origin/master nor origin/main" >&2; rc=1; continue; }
    echo "$top $ref"; listed+="$top "
  done
  spl_done_claim_landed_repos "$listed" "${1:-/dev/null}" || rc=1
  return $rc
}

# spl_done_claim_lane_repos <root> <due file> <repos file>: SPL-2930 (c-179's
# sha a486355b0 and c-189's own repo alerted "not in the repository",
# 10-22): appends to <repos file> each sender lane's OWN repo not yet in it
# (same git common dir), "<top> <trunk>", fetched unless DONE_CLAIM_FETCH=0.
# No cnf list: the repo comes from the lane's worktree. A failed fetch (an
# https origin with no credential) keeps its last fetched trunk and prints
# "<lane>\t<top> <trunk>" for each lane judged on it; a repo with no trunk
# is skipped with a WARN, never a FATAL. SPL-3020: [unchecked file] gets
# "R\t<top>\t<why>" per repo whose fetch failed and "L\t<lane>\t<why>" per
# lane whose own repo was not read; a local-trunk repo is its local branch.
spl_done_claim_lane_repos() {
  local have="" stale="" top ref c id wt
  while read -r top ref; do c="$(spl_done_claim_common "$top")" && have+="$c"$'\n'; done <"$3"
  while read -r id; do
    c=""
    while read -r wt; do c="$(spl_done_claim_common "$wt")" && break; done < <(spl_done_claim_lane_wt "$1" "$id")
    [[ -n "$c" ]] || { printf 'L\t%s\town repo not found (no worktree in registry.tsv or workdirs.tsv)\n' "$id" >>"${4:-/dev/null}"; continue; }
    if grep -qxF -- "$c" <<<"$have"; then
      awk -F'\t' -v c="$c" -v id="$id" '$1 == c { print id "\t" $2 }' <<<"$stale"
      continue
    fi
    have+="$c"$'\n'
    top="${c%/.git}"
    if ref="$(spl_done_claim_local_trunk "$top")"; then echo "$top $ref" >>"$3"; continue; fi
    ref=""
    for ref in origin/master origin/main; do git -C "$top" rev-parse -q --verify "$ref^{commit}" >/dev/null 2>&1 && break; ref=""; done
    if [[ -z "$ref" ]]; then
      do_log "WARN $id's own repo $top has neither origin/master nor origin/main: not read" >&2
      printf 'L\t%s\town repo %s has no trunk\n' "$id" "$top" >>"${4:-/dev/null}"; continue
    fi
    if [[ "${DONE_CLAIM_FETCH:-1}" == 1 ]] &&
      ! GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$top" fetch -q origin </dev/null >/dev/null 2>&1; then
      do_log "WARN git fetch origin failed in $top ($id's own repo): its last fetched $ref counts" >&2
      stale+="$c"$'\t'"$top $ref"$'\n'
      printf 'R\t%s\tgit fetch failed in %s\n' "$top" "$top" >>"${4:-/dev/null}"
      printf '%s\t%s %s\n' "$id" "$top" "$ref"
    fi
    echo "$top $ref" >>"$3"
  done < <(cut -f2 "$2" | sed 's/@.*//' | sort -u)
}

# spl_done_claim_lane_wt <root> <lane id>: the lane's worktree dirs, newest
# first: its registry.tsv row (col 4), then its workdirs.tsv worktree rows by
# finished_at (an id is recycled: the newest that still exists wins).
spl_done_claim_lane_wt() {
  awk -F'\t' -v id="$2" '$1 == id && $4 != "" { print $4 }' "$1/registry.tsv" 2>/dev/null
  awk -F'\t' -v id="$2" '!/^#/ && $2 == "worktree" && $3 == id && $1 != "" { print $6 "\t" $1 }' "$1/workdirs.tsv" 2>/dev/null |
    sort -r | cut -f2
}

# spl_done_claim_common <dir>: the absolute git common dir of <dir> (a
# worktree and its main clone share it), else false.
spl_done_claim_common() {
  [[ -d "$1" ]] && git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
}

# spl_done_claim_stale <stale file> <from>: "own repo <top> not fetched,
# judged on its last fetched <trunk>" when the lane's own repo failed its fetch.
spl_done_claim_stale() {
  awk -F'\t' -v id="${2%@*}" '$1 == id { split($2, a, " "); print "own repo " a[1] " not fetched, judged on its last fetched " a[2]; exit }' "$1"
}

# spl_done_claim_landed_repos "<tops already listed> ": "<clone> origin/<trunk>"
# per customer repo the cnf knows (env.box.landed_repos, a hosted site's
# src_dir), resolved by the one shared spl_landed_repo / spl_landed_repo_trunk
# (spl-lane-issue.func.sh) that do_spl_lane_issue and the **Live** proof use:
# a sha on one of their trunks has landed (c-578's csi-rel sha, 10-17). A clone
# on another box is that box's (skipped); a failed fetch warns and keeps the
# clone's last fetched trunk (an "R" row in [unchecked file], SPL-3020), a
# missing trunk is a FATAL; a local-trunk clone is its local branch, unfetched.
spl_done_claim_landed_repos() {
  local n row clone trunk rc=0 skip=" ${1:-}"
  while IFS=$'\t' read -r n _; do
    row="$(spl_landed_repo "$n" 2>/dev/null)" || continue
    clone="${row%%$'\t'*}"
    [[ "$skip" == *" $clone "* ]] && continue
    skip+="$clone "
    if trunk="$(spl_done_claim_local_trunk "$clone")"; then echo "$clone $trunk"; continue; fi
    if [[ "${DONE_CLAIM_FETCH:-1}" == 1 ]] && trunk="$(spl_landed_repo_trunk "$n" "$clone" "${row#*$'\t'}" 2>/dev/null)"; then :
    else
      if [[ "${DONE_CLAIM_FETCH:-1}" == 1 ]]; then
        do_log "WARN git fetch origin failed in $clone ($n): its last fetched trunk counts" >&2
        printf 'R\t%s\tgit fetch failed in %s\n' "$clone" "$clone" >>"${2:-/dev/null}"
      fi
      trunk="$(SLR_NO_FETCH=1 spl_landed_repo_trunk "$n" "$clone" "${row#*$'\t'}")" || { rc=1; continue; }
    fi
    echo "$clone origin/$trunk"
  done < <(spl_landed_repo_rows)
  return $rc
}

# spl_done_claim_missing <repos file> <shas>: the shas on no repo's trunk. A
# sha that resolves in a repo has landed when it is an ancestor of its trunk,
# or when `git cherry` marks it "-": the same patch (patch-id) is on the trunk
# under another sha, as a review-branch sha after the rebase that landed it.
spl_done_claim_missing() {
  local s full top ref ok out=()
  for s in $2; do
    ok=0
    while read -r top ref; do
      full="$(git -C "$top" rev-parse -q --verify "$s^{commit}" 2>/dev/null)" || continue
      if git -C "$top" merge-base --is-ancestor "$full" "$ref" 2>/dev/null ||
        git -C "$top" cherry "$ref" "$full" "$full^" 2>/dev/null | grep -x -- "- $full" >/dev/null; then ok=1; break; fi
    done <"$1"
    (( ok )) || out+=("$s")
  done
  echo "${out[*]}"
}

# spl_done_claim_local_trunk <top>: "refs/heads/<branch>" when the clone says
# its trunk is local by design (`git config spool.localTrunk <branch>`, never
# pushed from this box, SPL-3020) and that branch exists; else false.
spl_done_claim_local_trunk() {
  local b
  b="$(git -C "$1" config --get spool.localTrunk 2>/dev/null)" && [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] || return 1
  git -C "$1" rev-parse -q --verify "refs/heads/$b^{commit}" >/dev/null 2>&1 || return 1
  echo "refs/heads/$b"
}

# spl_done_claim_unchecked <repos file> <unchecked file> <lane id> <shas>:
# "<sha>\t<why>" per sha of <shas> (all on no trunk) the check could not judge
# (SPL-3020): it resolves only in a repo whose fetch failed (an "R" row), or it
# is no object in any repo while the lane's own repo was not read ("L" row) or
# any repo failed its fetch. A sha in a repo read fresh is not listed.
spl_done_claim_unchecked() {
  local s top ref why lw hit
  lw="$(awk -F'\t' -v id="$3" '$1 == "L" && $2 == id { print $3; exit }' "$2" 2>/dev/null)"
  for s in $4; do
    why="" hit=0
    while read -r top ref; do
      git -C "$top" rev-parse -q --verify "$s^{commit}" >/dev/null 2>&1 || continue
      hit=1
      why="$(awk -F'\t' -v t="$top" '$1 == "R" && $2 == t { print $3; exit }' "$2" 2>/dev/null)"
      [[ -n "$why" ]] && break
    done <"$1"
    if (( ! hit )); then
      why="$lw"
      [[ -n "$why" ]] || why="$(awk -F'\t' '$1 == "R" { printf "%s%s", (n++ ? ", " : ""), $3 }' "$2" 2>/dev/null)"
    fi
    if [[ -n "$why" ]]; then printf '%s\t%s\n' "$s" "$why"; fi
  done
  return 0
}

# spl_done_claim_minus <shas> <unchecked rows>: <shas> without the unchecked ones.
spl_done_claim_minus() {
  local s out=()
  for s in $1; do grep -q -- "^$s"$'\t' <<<"$2" || out+=("$s"); done
  echo "${out[*]}"
}

# spl_done_claim_unchk_text <unchecked rows>: "not checked (<why>): <sha>; ...".
spl_done_claim_unchk_text() {
  awk -F'\t' 'NF { printf "%snot checked (%s): %s", (n++ ? "; " : ""), $2, $1 }' <<<"$1"
}

# spl_done_claim_unknown <repos file> <shas>: the shas that are no object in
# any repo (a pre-rebase sha of another tree), as against an unpushed one.
spl_done_claim_unknown() {
  local s top ref ok out=()
  for s in $2; do
    ok=0
    while read -r top ref; do
      git -C "$top" cat-file -e "$s^{object}" 2>/dev/null && { ok=1; break; }
    done <"$1"
    (( ok )) || out+=("$s")
  done
  echo "${out[*]}"
}

# spl_done_claim_since <root> <lane id> <now>: the lane's spawn epoch from
# <root>/registry.tsv (col 5, 20261017T082257Z), else <now> - 48 h.
spl_done_claim_since() {
  local t e
  t="$(awk -F'\t' -v id="$2" '$1 == id { print $5; exit }' "$1/registry.tsv" 2>/dev/null)"
  if [[ "$t" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]] &&
    e="$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}" +%s 2>/dev/null)"; then
    echo "$e"
  else
    echo "$(($3 - 48 * 3600))"
  fi
}

# spl_done_claim_rewrite <repos file> <body> <since epoch>: true when EXACTLY
# one trunk commit committed at or after <since> carries an issue key
# (SPL-n) of <body> in its subject (SPL-2327): the rewritten sha's landing.
spl_done_claim_rewrite() {
  local keys top ref hits=""
  keys="$(grep -oE 'SPL-[0-9]+' <<<"$2" | sort -u | sed -E 's/$/([^0-9]|$)/' | paste -sd'|' -)"
  [[ -n "$keys" ]] || return 1
  while read -r top ref; do
    hits+="$(git -C "$top" log --format='%ct %H %s' "$ref" 2>/dev/null |
      awk -v lo="$3" -v re="$keys" '$1 + 0 >= lo + 0 && $0 ~ re { print $2 }')"$'\n'
  done <"$1"
  [[ "$(grep -c . <<<"$(sort -u <<<"$hits")")" == 1 ]]
}

# spl_done_claim_r7 <body>: true when the first non-blank line of <body> (lines
# split on \x1f) is an R7 review line, `review: <id>[@<box>] [<vendor>]
# PASS|FAIL ...` (SPL-2916, m-120's f6471a6c): a review, never a done-claim.
spl_done_claim_r7() {
  local first rx='^[[:space:]>*_`-]*review: [cmagq]-[0-9]{3,}(@[A-Za-z0-9._-]+)?( [a-z]+)? (PASS|FAIL)([[:space:]]|$)'
  first="$(awk 'NF { print; exit }' <<<"${1//$'\037'/$'\n'}")"
  [[ "$first" =~ $rx ]]
}

# spl_done_claim_seats <root> <repos file>: the lane ids whose LATEST slug
# marks a seat, reviewer or plan lane (SPL-2313): its last word, once a
# trailing vendor, "takeover" or spl key is cut, is seat[N], review[er] or
# plan[ner] (a-321-c002-radar-r7-reviewer-agy yes, m-341-c002-done-claim-skip-
# seat-lanes no; measured on 241 slugs of both boxes, 10-17). Ids are recycled
# (SPL-2916: m-120 of the other box, a reviewer, alerted on an older code slug of its id), so
# the slug is the latest one: the branches of the id's live worktrees <id>-<slug>
# (every one must mark it); else, its live worktree detached, its newest local
# branch <id>-<slug> by tip commit date (a spawn branches off the trunk of its
# day); else its newest worktree row of <root>/workdirs.tsv (agent, branch,
# finished_at; an empty branch reads the newest local branch). An id whose
# latest slug is a code slug, or that has none, is not listed. SPL-3261
# (a-709's 4c4de307): a rotation's branch <id>-rotate[-N] is no slug, so the
# id keeps its previous one; an id whose only rows are rotation rows reads its
# newest other local branch <id>-<slug>.
spl_done_claim_seats() {
  local top ref
  {
    while read -r top ref; do
      git -C "$top" worktree list --porcelain 2>/dev/null | awk '
        /^worktree / { n = split($2, p, "/"); id = p[n] }
        /^branch refs\/heads\/[cmagq]-[0-9]+-/ { b = substr($2, 12); match(b, /^[cmagq]-[0-9]+/); print "L\t" substr(b, 1, RLENGTH) "\t" b }
        /^detached$/ && id ~ /^[cmagq]-[0-9]+$/ { print "D\t" id "\t" }'
      git -C "$top" for-each-ref --format='%(committerdate:unix) %(refname:short)' refs/heads/ 2>/dev/null |
        sed -nE 's#^([0-9]+) (([cmagq]-[0-9]+)-.+)$#B\t\3\t\2\t\1#p'
    done <"$2"
    [[ -f "$1/workdirs.tsv" ]] &&
      awk -F'\t' '!/^#/ && $2 == "worktree" && $3 ~ /^[cmagq]-[0-9]+$/ { print "R\t" $3 "\t" $5 "\t" $6 }' "$1/workdirs.tsv"
  } | awk -F'\t' '
    function seat(s) {
      while (sub(/-(claude|agy|mistral|grok|qwen|takeover|spl-?[0-9]+)$/, "", s)) ;
      return s ~ /-(seat[0-9]*|review|reviewer|plan|planner)$/
    }
    $1 != "D" && $3 ~ /^[cmagq]-[0-9]+-rotate(-[0-9]+)?$/ { rot[$2] = 1; next }
    $1 == "L" { live[$2] = 1; if (!seat($3)) code[$2] = 1; next }
    $1 == "D" { det[$2] = 1; next }
    $1 == "B" { if (!($2 in bt) || $4 + 0 >= bt[$2]) { bt[$2] = $4 + 0; bb[$2] = $3 }; next }
    $1 == "R" { if (!($2 in rt) || ($4 "") >= rt[$2]) { rt[$2] = $4 ""; rb[$2] = $3 }; next }
    END {
      for (id in live) if (!(id in code)) print id
      for (id in det) if (!(id in live) && (id in bb) && seat(bb[id])) print id
      for (id in rt) if (!(id in live) && !(id in det)) {
        s = (rb[id] != "" ? rb[id] : bb[id]); if (s != "" && seat(s)) print id
      }
      for (id in rot) if (!(id in live) && !(id in det) && !(id in rt) && (id in bb) && seat(bb[id])) print id
    }' | sort -u
}

# spl_done_claim_unparked <repos file> <live ids file> <shas> [sender id]: the
# shas NOT on a remote branch origin/[review/|wip/]<id>-... of a lane in <live
# ids>: a plan lane's sha waiting there for a go is pending, not missing
# (SPL-2313). SPL-3116: origin/review/<topic>... or origin/wip/<topic>... with
# no lane id (c-912's review/s107-v2-t020) is the sender's own branch.
# SPL-3261 (a-709's review of c-906's review/r19-04-...): it is also the branch
# of each lane of [root]/registry.tsv whose worktree branch ends in -<topic>.
spl_done_claim_unparked() {
  local s full top ref ids brs ok out=()
  for s in $3; do
    ok=0
    while read -r top ref; do
      full="$(git -C "$top" rev-parse -q --verify "$s^{commit}" 2>/dev/null)" || continue
      brs="$(git -C "$top" branch -r --contains "$full" --format='%(refname:short)' 2>/dev/null)"
      ids="$(sed -nE -e 's#^origin/((review|wip)/)?([cmagq]-[0-9]+)-.*#\3#p;t' -e "s#^origin/(review|wip)/.+#${4:-}#p" <<<"$brs")"
      ids+=$'\n'"$(spl_done_claim_topic_lanes "${5:-}" "$brs")"
      grep -qxFf "$2" <<<"$ids" && { ok=1; break; }
    done <"$1"
    (( ok )) || out+=("$s")
  done
  echo "${out[*]}"
}

# spl_done_claim_topic_lanes <root> <remote branches>: the lane ids of
# <root>/registry.tsv whose worktree (col 4) is on a branch ending in -<topic>,
# for each origin/review/<topic> or origin/wip/<topic> with no lane id.
spl_done_claim_topic_lanes() {
  local tp lid lwt b
  [[ -n "$1" && -f "$1/registry.tsv" ]] || return 0
  sed -nE 's#^origin/(review|wip)/(.+)#\2#p' <<<"$2" | grep -vE '^[cmagq]-[0-9]+-' | while read -r tp; do
    while IFS=$'\t' read -r lid lwt; do
      b="$(git -C "$lwt" rev-parse --abbrev-ref HEAD 2>/dev/null)" && [[ "$b" == *"-$tp" ]] && echo "$lid"
    done < <(awk -F'\t' '$1 ~ /^[cmagq]-[0-9]+$/ && $4 != "" { print $1 "\t" $4 }' "$1/registry.tsv")
  done
}

# spl_done_claim_on_review <repos file> <shas>: "<sha>\t<branch>\t<trunk>" per
# sha of <shas> (all on no trunk) that `git branch -r --contains` finds on an
# origin/review/* branch (its first, by name), <trunk> the repo's trunk without
# "origin/" (SPL-3673: c-271's 8cf3fef52 on origin/review/grok-dispatch-grade).
spl_done_claim_on_review() {
  local s full top ref b
  for s in $2; do
    while read -r top ref; do
      full="$(git -C "$top" rev-parse -q --verify "$s^{commit}" 2>/dev/null)" || continue
      b="$(git -C "$top" branch -r --contains "$full" --format='%(refname:short)' 2>/dev/null)"
      b="$(grep -m1 '^origin/review/' <<<"$b")" || continue
      printf '%s\t%s\t%s\n' "$s" "$b" "${ref#origin/}"; break
    done <"$1"
  done
  return 0
}

# spl_done_claim_unlanded <body>: true when the result itself says its sha is
# not landed: "not (yet) on|in master|main|trunk", "not (yet) landed",
# "unlanded" or "on a|the review branch" (SPL-3673: c-271's 68039e73 "on a
# review branch, not on master"). A bare "review" is not one: a "review
# request" names no state.
spl_done_claim_unlanded() {
  grep -qiE '(^|[^a-z])(not (yet )?(on|in) (origin/)?(master|main|trunk)|not (yet )?landed|unlanded|on (a|the) review branch)([^a-z]|$)' <<<"${1//$'\037'/$'\n'}"
}

# spl_done_claim_review_text <review rows>: "on review branch <b>, not on <trunk>: <sha> ...".
spl_done_claim_review_text() {
  awk -F'\t' 'NF { k = "on review branch " $2 ", not on " $3; if (!(k in s)) { o[++n] = k; s[k] = $1 } else s[k] = s[k] " " $1 }
    END { for (i = 1; i <= n; i++) printf "%s%s: %s", (i > 1 ? "; " : ""), o[i], s[o[i]] }' <<<"$1"
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

# spl_done_claim_note <lane> <msg id> <ts> <task> <missing shas> <repos file>
# [stale file] [unchecked rows]: the body. A sha that is no object in any repo says so
# (SPL-2327); a lane whose own repo failed its fetch says so (SPL-2930); a sha
# the check could not judge is listed apart, not counted (SPL-3020).
spl_done_claim_note() {
  local s gone rv tr known=() what=() w
  gone=" $(spl_done_claim_unknown "$6" "$5") "
  rv="$(spl_done_claim_on_review "$6" "$5")"
  for s in $5; do [[ "$gone" == *" $s "* ]] || grep -q -- "^$s"$'\t' <<<"$rv" || known+=("$s"); done
  gone="$(xargs <<<"$gone")"
  [[ -n "$5" ]] || what+=("no sha not in the repository")
  [[ ${#known[@]} -gt 0 ]] && w="${known[*]}" && what+=("sha ${w// /, } not in the repository")
  while IFS=$'\t' read -r s w tr; do [[ -n "$s" ]] && what+=("sha $s on review branch $w, not on $tr"); done <<<"$rv"
  [[ -n "$gone" ]] && what+=("sha ${gone// /, } not an object in any repository (a pre-rebase sha?)")
  w="${what[*]/%/;}"
  printf 'done-claim check: %s result %s (%s, task %s): %s\n\n' "$1" "$2" "$3" "${4:-none}" "${w%;}"
  printf -- '- checked %s min after the result, on: %s\n' "${DONE_CLAIM_AGE_MIN:-15}" \
    "$(awk '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }' "$6")"
  w="$(spl_done_claim_stale "${7:-/dev/null}" "$1")"
  [[ -n "$w" ]] && printf -- '- %s (git fetch failed)\n' "$w"
  [[ -n "${8:-}" ]] && printf -- '- not counted above: %s\n' "$(spl_done_claim_unchk_text "$8")"
  printf -- '- rule: a lane result names a sha on the trunk (SPL-2265); one note per message\n'
}

# spl_done_claim_send <to> <body file>: one spool note on task done-claim-check.
spl_done_claim_send() {
  local send="${DONE_CLAIM_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "${DONE_CLAIM_FROM:-$(spl_role_seat 1)}" --to "$1" \
    --kind note --task done-claim-check --body-file "$2" >/dev/null 2>&1 8>&- 9>&- ||
    { do_log "WARN could not send the done-claim note to $1"; return 1; }
}

# spl_done_claim_prune <ledger> <epoch>: drop rows older than <epoch>.
spl_done_claim_prune() {
  [[ -f "$1" ]] || return 0
  awk -F'\t' -v lo="$2" '$3 >= lo' "$1" >"$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}
