#!/bin/bash
#------------------------------------------------------------------------------
# @description A lane whose reviewed work has landed gets its ACCEPTED from a
# @description script (spec 157 Rule 2, row B5, SPL-4102; owner HUM-10, t1
# @description 99ffa592 msg a99676b7: "What could be automated to be done
# @description without any intelligence?"). On the machine that holds the
# @description dispatch lease (LEASE_CMD=show do_spl_dispatch_lease, read
# @description only), for the newest verified review row of each task and
# @description author in $SPOOL_ROOT/dispatch/automation.log (row B4 writes
# @description `PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>`)
# @description not yet accepted, every check below must pass, in this order;
# @description the first that fails decides the exit code:
# @description   6 no PASS row for the lane (ACCEPT_AUTHOR names one)
# @description   4 the row is a pointer, not the truth: the review message
# @description     <msg_id> in the holder's spool (inbox, archive) has the same
# @description     task_id, reviewer (its bare from and the line's id) and
# @description     sha (field 5 of its `review: ` line), its author is the
# @description     row's (B4's own _spl_review_go_row on the reviewer's brief),
# @description     and do_spl_review_line_check passes it again (the journal)
# @description   8 not landed yet: no row in the lane's append-only
# @description     $SPOOL_ROOT/<author>/lifetime/push-master/pushes.log
# @description     (`<ts> <base>..<sha>`, one per do_spl_push_master PUSHED)
# @description   1 a landed commit (any pushed range) or a reviewed commit
# @description     (<sha> back to the first pushed base) changes no file
# @description   3 a commit of ANY pushed range whose stable patch-id is no
# @description     reviewed commit's and whose subject pairs with none: an
# @description     unreviewed extra commit (push 1 unreviewed, push 2 reviewed
# @description     is caught: every range is read, not the last status)
# @description   2 a reviewed commit `git cherry` does not find on trunk and
# @description     no landed commit pairs with: a partial landing
# @description   5 a reviewed commit landed under another patch-id (paired by
# @description     subject) whose `git range-diff` changes a +/- line of the
# @description     code (a context or line-offset change passes)
# @description   9 a landed commit cites no SPL-<n> in its subject and has no
# @description     `Closes: SPL-<n>` line, or do_check_lane_served fails a
# @description     pushed range (trunk, identity, AI trailer); 8 while it lags
# @description   7 a workflow of `gh run list --commit <last landed sha>` failed;
# @description     8 while one is queued or running or none started; a
# @description     cancelled one passes when a newer master run of the same
# @description     workflow succeeded on a descendant, else 8, and 9 (HOLD)
# @description     after ACCEPT_CANCEL_TICKS (3) runs
# @description Pass (0): the holder sends the author `ACCEPTED (auto, spec 157
# @description rule 2, automation.log <msg_id>): on master <sha>` (kind result,
# @description the row's task), the holder gets an audit note naming msg,
# @description task, author, reviewer and both shas, and one `accepted-close
# @description <msg_id> action=accepted` line goes to automation.log. A
# @description refusal (1-7, 9) is logged and sent to the holder once per msg
# @description and code, and judged again every run (a lane that fixes it is
# @description accepted later); 8 is only a DEFER line. Any failed read fails
# @description closed. The lease files and kill-your-self-report.sh are never
# @description written. Dry run unless DRY_RUN=0: PLAN lines, nothing sent or
# @description logged. Threat model: automation.log, pushes.log and the spool
# @description are group-writable; the checks catch corruption, stale rows
# @description and an invented review, not a same-user forger (spec 157
# @description Rule 2 check 2): the audit note keeps that with the holder.
# @description The cron line: do_spl_accepted_close_install_cron.
# @param ACCEPT_AUTHOR (optional) - judge only this lane (bare id); the exit code is its verdict
# @param ACCEPT_TASK (optional) - with ACCEPT_AUTHOR: only this task
# @param ACCEPT_FROM (optional) - the audit / refusal note's sender, default lease.conf LEASE_ORCH, else role seat 1
# @param ACCEPT_SEND (optional) - the sender script, default spawn-agents/scripts/spool-send.sh (tests)
# @param ACCEPT_GH (optional) - the gh binary, default gh (tests)
# @param ACCEPT_FETCH_SCRIPT (optional) - default spawn-agents/scripts/git-fetch-fresh.sh (tests)
# @param ACCEPT_CANCEL_TICKS (optional) - runs a cancelled workflow defers before the HOLD, default 3
# @param ACCEPT_REMOTE / ACCEPT_BRANCH (optional) - the trunk, default origin / master
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_accepted_close
# @example DRY_RUN=0 ./run -a do_spl_accepted_close
# @example ACCEPT_AUTHOR=c-805 ./run -a do_spl_accepted_close
#------------------------------------------------------------------------------
do_spl_accepted_close() {
  do_require_bin git || return 1
  do_require_bin python3 || return 1
  local dry="${DRY_RUN:-1}" one="${ACCEPT_AUTHOR:-}" ticks="${ACCEPT_CANCEL_TICKS:-3}"
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  [[ -z "$one" || "$one" =~ ^[acgmq]-[0-9]{3}$ ]] || { do_log "FATAL ACCEPT_AUTHOR must be a bare lane id, got: '$one'"; return 1; }
  [[ "$ticks" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL ACCEPT_CANCEL_TICKS must be 1..99, got: '$ticks'"; return 1; }
  spl_lease_init ro || return 1
  spl_lease_conf
  local holder log="$LEASE_DIR/automation.log" rows rc=0 last=0 n=0 msg task author reviewer sha ts
  holder="$(_spl_accepted_close_holder)" || return 0
  if [[ "$dry" == 0 ]]; then
    mkdir -p "$LEASE_DIR/accepted-close" && touch "$log" || { do_log "FATAL cannot write $log"; return 1; }
    exec 7>"$LEASE_DIR/accepted-close.lock"
    flock -n 7 || { do_log "INFO another accepted-close run holds $LEASE_DIR/accepted-close.lock - skipped"; return 0; }
  fi
  rows="$(_spl_accepted_close_rows "$log" "$one" "${ACCEPT_TASK:-}")"
  if [[ -n "$one" && -z "$rows" ]]; then
    echo "REFUSED: no verified PASS record in automation.log for $one${ACCEPT_TASK:+ on $ACCEPT_TASK} (rc 6)"; return 6
  fi
  while IFS=$'\t' read -r msg task author reviewer sha ts; do
    [[ -n "$msg" ]] || continue
    n=$((n + 1))
    ACC_PASS_TS="$ts"
    _spl_accepted_close_one "$holder" "$log" "$dry" "$msg" "$task" "$author" "$reviewer" "$sha"; last=$?
    (( last == 0 )) || rc=$last
  done <<<"$rows"
  do_log "OK accepted close: holder $holder, $n reviewed lane(s) judged$([[ "$dry" == 1 ]] && echo ' (DRY_RUN: planned, nothing sent)')"
  [[ -n "$one" ]] && return "$rc"
  return 0
}

# _spl_accepted_close_holder: the bare id of the live dispatch lease holder
# on this machine; 1 with an INFO on stderr otherwise (read only).
_spl_accepted_close_holder() {
  local show age
  show="$(LEASE_CMD=show do_spl_dispatch_lease 2>/dev/null)" || { do_log "INFO the dispatch lease cannot be read: nothing to do" >&2; return 1; }
  read -r LH age <<<"$show"
  if [[ -z "$LH" || "$LH" == none || ! "$age" =~ ^[0-9]+$ ]] || (( age > LEASE_STALE )); then
    do_log "INFO no live dispatch lease holder (${show:-empty}): nothing to do" >&2; return 1
  fi
  spl_lease_remote && { do_log "INFO the dispatch lease is held by $LH, on another machine: its machine accepts" >&2; return 1; }
  spl_lease_holder_id
}

# _spl_accepted_close_rows <log> [author] [task]: one TSV row (msg task
# author reviewer sha ts) per task+author, its newest well-formed PASS row,
# unless that msg already has an `accepted-close <msg> action=accepted` line.
_spl_accepted_close_rows() {
  awk -v a="$2" -v t="$3" '
    $1 == "PASS" && NF == 7 && $7 ~ /^[0-9a-f]{40}$/ && $5 ~ /^[acgmq]-[0-9][0-9][0-9]$/ && $6 ~ /^[acgmq]-[0-9][0-9][0-9]$/ {
      if ((a == "" || $5 == a) && (t == "" || $4 == t)) { k = $4 SUBSEP $5; if (!(k in row)) ord[++n] = k; row[k] = $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $2 }
    }
    $2 == "accepted-close" && $4 == "action=accepted" { done[$3] = 1 }
    END { for (i = 1; i <= n; i++) { split(row[ord[i]], f, "\t"); if (!(f[1] in done)) print row[ord[i]] } }' "$1" 2>/dev/null
}

# _spl_accepted_close_one <holder> <log> <dry> <msg> <task> <author>
# <reviewer> <sha>: judge one lane, then send and log; returns the verdict.
_spl_accepted_close_one() {
  local holder="$1" log="$2" dry="$3" msg="$4" task="$5" author="$6" reviewer="$7" sha="$8"
  local wt rc why tmp
  ACC_LANDED="" ACC_RANGES="" ACC_PRE=""
  wt="$(_spl_accepted_close_wt "$author")"
  if [[ -z "$wt" ]]; then why="no worktree of $author in registry.tsv / workdirs.tsv"; rc=9
  else
    # not $(...): the checks set ACC_LANDED / ACC_RANGES in this shell
    tmp="$(mktemp)" || return 9
    _spl_accepted_close_verify "$holder" "$msg" "$task" "$author" "$reviewer" "$sha" "$wt" >"$tmp"; rc=$?
    why="$(tail -n 1 "$tmp")"; rm -f "$tmp"
  fi
  if (( rc == 8 )); then do_log "INFO DEFER $author $task (msg $msg): $why"; return 8; fi
  if (( rc != 0 )); then
    echo "REFUSED: $why (rc $rc, $author, task $task, msg $msg)"
    _spl_accepted_close_refused "$holder" "$log" "$dry" "$rc" "$why" "$msg" "$task" "$author" "$reviewer"
    return "$rc"
  fi
  _spl_accepted_close_accept "$holder" "$log" "$dry" "$msg" "$task" "$author" "$reviewer" "$sha"
}

# _spl_accepted_close_wt <author>: the lane's first existing worktree
# (spl_done_claim_lane_wt: registry.tsv col 4, then workdirs.tsv, newest).
_spl_accepted_close_wt() {
  local d
  while IFS= read -r d; do
    [[ -n "$d" ]] && git -C "$d" rev-parse --git-dir >/dev/null 2>&1 && { echo "$d"; return 0; }
  done < <(spl_done_claim_lane_wt "${SPOOL_ROOT:-/var/spool-hub}" "$1")
  return 1
}

# _spl_accepted_close_verify <holder> <msg> <task> <author> <reviewer> <sha>
# <wt>: every check of the header in order; prints why it stopped, returns
# its code (0 when all pass). Sets ACC_LANDED (last landed sha), ACC_RANGES
# and ACC_PRE (the landed shas of pushes older than the PASS row, ACC_PASS_TS).
_spl_accepted_close_verify() {
  local holder="$1" msg="$2" task="$3" author="$4" reviewer="$5" sha="$6" wt="$7"
  local remote="${ACCEPT_REMOTE:-origin}" branch="${ACCEPT_BRANCH:-master}" fetch first rc rows
  local fetch_sh="${ACCEPT_FETCH_SCRIPT:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/git-fetch-fresh.sh}"
  fetch="$(bash "$fetch_sh" -C "$wt" --remote "$remote" --branch "$branch" 2>&1)" ||
    { echo "the fetch of $remote/$branch in $wt failed: $(tail -n 1 <<<"$fetch")"; return 8; }
  _spl_accepted_close_journal "$holder" "$msg" "$task" "$author" "$reviewer" "$sha" "$wt" || return 4
  rows="$(_spl_accepted_close_ranges "$author" "$wt")"
  ACC_RANGES="$(cut -d' ' -f2 <<<"$rows")"
  ACC_PRE="$(awk -v t="$ACC_PASS_TS" 'NF == 2 && $1 < t { sub(/.*\.\./, "", $2); print $2 }' <<<"$rows")"
  [[ -n "$rows" ]] || { echo "not landed yet: no pushed range in $SPOOL_ROOT/$author/lifetime/push-master/pushes.log"; return 8; }
  ACC_LANDED="$(tail -n 1 <<<"$ACC_RANGES")" ACC_LANDED="${ACC_LANDED#*..}"
  first="$(awk 'NR == 1 { sub(/\.\..*/, ""); print }' <<<"$ACC_RANGES")"
  git -C "$wt" cat-file -e "$sha^{commit}" 2>/dev/null ||
    git -C "$wt" fetch -q "$remote" "+refs/heads/review/*:refs/remotes/$remote/review/*" >/dev/null 2>&1
  git -C "$wt" cat-file -e "$sha^{commit}" 2>/dev/null || { echo "reviewed sha $sha is no commit in $wt"; return 9; }
  _spl_accepted_close_patches "$wt" "$sha" "$first" "$remote/$branch"; rc=$?
  (( rc == 0 )) || return "$rc"
  _spl_accepted_close_keys "$wt" || return 9
  _spl_accepted_close_served "$wt" "$remote" "$branch"; rc=$?
  (( rc == 0 )) || return "$rc"
  _spl_accepted_close_ci "$wt" "$ACC_LANDED" "$msg"
}

# _spl_accepted_close_journal <holder> <msg> <task> <author> <reviewer>
# <sha> <wt>: 0 when the review message re-verifies (header, check 4).
_spl_accepted_close_journal() {
  local holder="$1" msg="$2" task="$3" author="$4" reviewer="$5" sha="$6" wt="$7" got from mtask line rid lsha out brief
  got="$(_spl_accepted_close_msg "${SPOOL_ROOT:-/var/spool-hub}/$holder" "$msg")"
  [[ -n "$got" ]] || { echo "journal transcript re-verification failed: review message $msg is not in $holder's inbox or archive"; return 1; }
  IFS=$'\t' read -r from mtask line <<<"$got"
  rid="$(awk '{ sub(/@.*/, "", $2); print $2 }' <<<"$line")" lsha="$(awk '{ print $5 }' <<<"$line")"
  if [[ "${from%@*}" != "$reviewer" || "$rid" != "$reviewer" || "$mtask" != "$task" || "$lsha" != "$sha" ]]; then
    echo "journal transcript re-verification failed: automation.log (task $task, reviewer $reviewer, sha ${sha:0:12}) differs from message $msg (task $mtask, from $from, line id $rid, sha ${lsha:0:12})"
    return 1
  fi
  declare -F _spl_review_go_row >/dev/null ||
    { echo "journal transcript re-verification failed: _spl_review_go_row (row B4, spl-review-go.func.sh) is not loaded: the author cannot be re-derived"; return 1; }
  brief="${SPOOL_ROOT:-/var/spool-hub}/$reviewer/lifetime/brief.md"
  out="$(_spl_review_go_row "$brief" "$sha" "$mtask" 2>/dev/null | awk -F'\t' 'NR == 1 { print $1 }')"
  [[ "$out" == "$author" ]] ||
    { echo "journal transcript re-verification failed: the reviewer's brief names author '${out:-none}', automation.log $author"; return 1; }
  out="$(REVIEW_LINE="$line" REVIEW_LINE_REPO="$wt" do_spl_review_line_check 2>&1)" ||
    { echo "journal transcript re-verification failed: do_spl_review_line_check: $(grep -m 1 -E '^(FATAL|MISSING|SYNTAX FAIL)' <<<"$out" || tail -n 1 <<<"$out")"; return 1; }
  return 0
}

# _spl_accepted_close_msg <spool dir> <msg id>: `from<TAB>task_id<TAB>review
# line` of the message in <dir>/{inbox,archive}, its first `review: ` line.
_spl_accepted_close_msg() {
  python3 - "$1" "$2" <<'EOF_PY'
import json, os, re, sys
root, want = sys.argv[1], sys.argv[2]
for sub in ("inbox", "archive"):
    d = os.path.join(root, sub)
    try:
        names = sorted(os.listdir(d))
    except OSError:
        continue
    for n in names:
        if not n.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, n)) as f:
                m = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(m, dict) or m.get("msg_id") != want:
            continue
        lines = [l for l in str(m.get("body", "")).split("\n") if re.match(r"^review: \S+@\S+ \S+ PASS ", l)]
        if lines:
            print("\t".join((str(m.get("from", "")), str(m.get("task_id", "")), lines[0])))
        sys.exit(0)
EOF_PY
}

# _spl_accepted_close_ranges <author> <wt>: the lane's pushed ranges, oldest
# first, `<ts> <base>..<sha>` (40-hex both, the sha a commit in <wt>).
_spl_accepted_close_ranges() {
  local f="${SPOOL_ROOT:-/var/spool-hub}/$1/lifetime/push-master/pushes.log" t r
  [[ -r "$f" ]] || return 0
  while read -r t r; do
    [[ "$r" =~ ^([0-9a-f]{40})\.\.([0-9a-f]{40})$ ]] || continue
    git -C "$2" cat-file -e "${BASH_REMATCH[2]}^{commit}" 2>/dev/null && echo "$t $r"
  done <"$f"
}

# _spl_accepted_close_landed <wt>: every commit of every range, oldest first, once.
_spl_accepted_close_landed() {
  local r
  for r in $ACC_RANGES; do git -C "$1" rev-list --reverse "$r"; done | awk '!seen[$0]++'
}

# _spl_accepted_close_empty <wt> <commit>: true when it changes no file.
_spl_accepted_close_empty() {
  [[ -z "$(git -C "$1" diff-tree --no-commit-id --root -r --numstat "$2" 2>/dev/null)" ]]
}

# _spl_accepted_close_patches <wt> <reviewed sha> <first base> <trunk>: the
# empty (1), extra (3), partial (2) and range-diff (5) checks. The reviewed
# set is <sha> back to the first pushed base, minus what a push older than
# the review landed (ACC_PRE): a fixup pushed before the review, under the
# reviewed tip, was never the reviewer's (Z1).
_spl_accepted_close_patches() {
  local wt="$1" sha="$2" first="$3" trunk="$4" c pid s r
  local -a landed reviewed
  local -A rpid=() rsub=() matched=() pair=()
  mapfile -t landed < <(_spl_accepted_close_landed "$wt")
  # shellcheck disable=SC2086 # ACC_PRE is a list of shas
  mapfile -t reviewed < <(git -C "$wt" rev-list --reverse "$sha" --not "$first" $ACC_PRE)
  (( ${#reviewed[@]} )) || { echo "incomplete landing: reviewed ${sha:0:12} has no commit after the first pushed base ${first:0:12}"; return 2; }
  for c in "${landed[@]}" "${reviewed[@]}"; do
    _spl_accepted_close_empty "$wt" "$c" && { echo "incomplete landing: commit ${c:0:12} is empty (changes no file)"; return 1; }
  done
  # a commit with no patch-id (no text diff) matches nothing: never an empty key
  for c in "${reviewed[@]}"; do
    pid="$(spl_done_claim_patch_id "$wt" "$c")"
    rpid["${pid:-none:$c}"]="$c"; rsub["$c"]="$(git -C "$wt" log -1 --format=%s "$c")"
  done
  for c in "${landed[@]}"; do
    pid="$(spl_done_claim_patch_id "$wt" "$c")"; pid="${pid:-none:$c}"
    [[ -n "${rpid[$pid]:-}" ]] && { matched["${rpid[$pid]}"]=1; continue; }
    s="$(git -C "$wt" log -1 --format=%s "$c")"
    for r in "${reviewed[@]}"; do
      [[ -z "${matched[$r]:-}" && -z "${pair[$r]:-}" && "${rsub[$r]}" == "$s" ]] && { pair["$r"]="$c"; continue 2; }
    done
    echo "unreviewed extra commit landed on master (${c:0:12} $s)"; return 3
  done
  while read -r s c; do
    [[ "$s" == - ]] && matched["$c"]=1
  done < <(git -C "$wt" cherry "$trunk" "$sha" "$first" 2>/dev/null)
  for r in "${reviewed[@]}"; do
    [[ -n "${matched[$r]:-}" || -n "${pair[$r]:-}" ]] || { echo "incomplete landing: reviewed ${r:0:12} (${rsub[$r]}) is not on $trunk"; return 2; }
  done
  for r in "${!pair[@]}"; do
    _spl_accepted_close_hunks "$wt" "$r" "${pair[$r]}" ||
      { echo "rebase altered code logic: reviewed ${r:0:12} landed as ${pair[$r]:0:12} with a changed hunk (git range-diff)"; return 5; }
  done
  return 0
}

# _spl_accepted_close_hunks <wt> <reviewed> <landed>: 0 when `git range-diff`
# of the two commits changes no code line: a `=` pair, or a `!` pair whose
# outer +/- lines touch only the commit message, the metadata or inner
# context (a line offset); 1 for a changed inner +/- line or no pairing. A
# section is named by an outer `@@ <name>` hunk header or an inner `## <name>
# ##` line: a code-only change shows `@@ <file>` and no `## <file> ##`.
_spl_accepted_close_hunks() {
  git -C "$1" range-diff --no-color --creation-factor=100 "$2^..$2" "$3^..$3" 2>/dev/null | awk '
    NR == 1 { if ($0 ~ /^[0-9]+: +[0-9a-f]+ = /) ok = 1; else if ($0 !~ /^[0-9]+: +[0-9a-f]+ ! /) bad = 1; next }
    /^[0-9-]+: / { bad = 1; next }
    /^    @@ / { sec = substr($0, 8); next }
    /^    [ +-] ## .* ##$/ { sec = substr($0, 10, length($0) - 12); next }
    /^    [-+][-+]/ && sec !~ /^(Metadata|Commit message)/ { bad = 1 }
    END { exit (NR == 0 || bad) ? 1 : 0 }'
}

# _spl_accepted_close_keys <wt>: 0 when every landed commit cites SPL-<n> in
# its subject or has a `Closes: SPL-<n>` body line (check 6).
_spl_accepted_close_keys() {
  local c
  while read -r c; do
    grep -qE 'SPL-[0-9]+' <<<"$(git -C "$1" log -1 --format=%s "$c")" && continue
    grep -qE '^Closes: SPL-[0-9]+' <<<"$(git -C "$1" log -1 --format=%b "$c")" && continue
    echo "missing tracked issue key: ${c:0:12} cites no SPL-<n> in its subject and has no 'Closes: SPL-<n>' line"; return 1
  done < <(_spl_accepted_close_landed "$1")
}

# _spl_accepted_close_served <wt> <remote> <branch>: do_check_lane_served on
# each pushed range; 0 all PASS, 8 one lags, 9 one FAILs (check 5).
_spl_accepted_close_served() {
  local r out rc
  for r in $ACC_RANGES; do
    out="$(SHA="${r#*..}" BASE="${r%..*}" LANE_WT="$1" LANE_REMOTE="$2" LANE_BRANCH="$3" do_check_lane_served 2>/dev/null)"; rc=$?
    (( rc == 0 )) && continue
    (( rc == 3 )) && { echo "deploy lag: do_check_lane_served ${r:0:8}..${r:42:8}: $out"; return 8; }
    echo "lane not served: do_check_lane_served ${r:0:8}..${r:42:8} (rc $rc): ${out:-no verdict}"; return 9
  done
}

# _spl_accepted_close_ci <wt> <sha> <msg>: gh's runs of <sha> (check 7):
# 0 all success / skipped, 7 one failed, 8 wait, 9 cancelled past the ticks.
_spl_accepted_close_ci() {
  local wt="$1" sha="$2" gh="${ACCEPT_GH:-gh}" runs verdict w cnt f="$LEASE_DIR/accepted-close/$3.cancelled"
  runs="$(cd "$wt" && "$gh" run list --commit "$sha" --json workflowName,status,conclusion 2>/dev/null)" ||
    { echo "CI unknown: gh run list --commit ${sha:0:12} failed"; return 8; }
  verdict="$(python3 -c '
import json, sys
runs = json.loads(sys.argv[1] or "[]")
if not runs: print("wait none started"); sys.exit()
bad = [r["workflowName"] for r in runs if r.get("conclusion") in ("failure", "timed_out", "startup_failure", "action_required")]
if bad: print("red " + ",".join(bad)); sys.exit()
busy = [r["workflowName"] for r in runs if r.get("status") != "completed"]
if busy: print("wait " + ",".join(busy)); sys.exit()
gone = sorted({r["workflowName"] for r in runs if r.get("conclusion") not in ("success", "skipped")})
print(("cancelled\t" + "\t".join(gone)) if gone else "green")' "$runs" 2>/dev/null)" || { echo "CI unknown: gh answered no JSON list"; return 8; }
  case "$verdict" in
    green) rm -f "$f"; return 0 ;;
    red*) echo "CI red on ${sha:0:12}: ${verdict#red } failed (the lane must fix it)"; return 7 ;;
    wait*) echo "CI not finished on ${sha:0:12}: ${verdict#wait }"; return 8 ;;
  esac
  while IFS= read -r w; do
    _spl_accepted_close_superseded "$wt" "$sha" "$w" || {
      cnt=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); [[ "${DRY_RUN:-1}" == 0 ]] && echo "$cnt" >"$f"
      (( cnt >= ${ACCEPT_CANCEL_TICKS:-3} )) && { echo "HOLD: CI workflow cancelled ($w on ${sha:0:12}, $cnt runs, no newer success)"; return 9; }
      echo "CI workflow $w cancelled on ${sha:0:12} (run $cnt of ${ACCEPT_CANCEL_TICKS:-3})"; return 8; }
  done < <(cut -f2- <<<"$verdict" | tr '\t' '\n')
  rm -f "$f"; return 0
}

# _spl_accepted_close_superseded <wt> <sha> <workflow>: 0 when a successful
# master run of <workflow> ran on a commit that contains <sha>.
_spl_accepted_close_superseded() {
  local h
  while read -r h; do
    [[ "$h" =~ ^[0-9a-f]{40}$ ]] && git -C "$1" merge-base --is-ancestor "$2" "$h" 2>/dev/null && return 0
  done < <(cd "$1" && "${ACCEPT_GH:-gh}" run list --workflow "$3" --branch "${ACCEPT_BRANCH:-master}" --status success \
    --limit 30 --json headSha --jq '.[].headSha' 2>/dev/null)
  return 1
}

# _spl_accepted_close_send <from> <to> <kind> <task> <body>: one spool message.
_spl_accepted_close_send() {
  local send="${ACCEPT_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$1" --to "$2" --kind "$3" --task "$4" --body "$5" \
    >/dev/null 2>&1 7>&- 8>&- 9>&-
}

# _spl_accepted_close_refused <holder> <log> <dry> <rc> <why> <msg> <task>
# <author> <reviewer>: log and tell the holder, once per msg and code.
_spl_accepted_close_refused() {
  local holder="$1" log="$2" dry="$3" rc="$4" why="$5" msg="$6" task="$7" author="$8" reviewer="$9" src
  grep -q " accepted-close $msg action=refused rc=$rc " "$log" 2>/dev/null && return 0
  [[ "$dry" == 1 ]] && { echo "PLAN refused rc $rc: note $holder about $author ($task, msg $msg)"; return 0; }
  _spl_accepted_close_send "${ACCEPT_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}" "$holder" note "$task" \
    "accepted-close (spec 157 rule 2) held $author on task $task: $why. Review msg $msg (reviewer $reviewer). Dispatcher judgment: no ACCEPTED was sent."; src=$?
  printf '%s accepted-close %s action=refused rc=%s actor=%s task=%s author=%s reviewer=%s note_rc=%s why=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" "$rc" "$holder" "$task" "$author" "$reviewer" "$src" "${why// /_}" >>"$log"
}

# _spl_accepted_close_accept <holder> <log> <dry> <msg> <task> <author>
# <reviewer> <sha>: the ACCEPTED, the audit note, the log line.
_spl_accepted_close_accept() {
  local holder="$1" log="$2" dry="$3" msg="$4" task="$5" author="$6" reviewer="$7" sha="$8" body src arc=0
  body="ACCEPTED (auto, spec 157 rule 2, automation.log $msg): on master $ACC_LANDED"
  if [[ "$dry" == 1 ]]; then echo "PLAN $holder -> $author (task $task, kind result): $body"; return 0; fi
  _spl_accepted_close_send "$holder" "$author" result "$task" "$body"; src=$?
  (( src == 0 )) || { do_log "WARN the ACCEPTED to $author failed (rc $src); the next run tries again"; return 9; }
  _spl_accepted_close_send "${ACCEPT_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}" "$holder" note "$task" \
    "accepted-close audit (spec 157 rule 2): sent '$body' to $author. msg $msg, task $task, author $author, reviewer $reviewer, reviewed $sha, landed $ACC_LANDED, ranges $(paste -sd' ' <<<"$ACC_RANGES")." || arc=$?
  printf '%s accepted-close %s action=accepted actor=%s task=%s author=%s reviewer=%s reviewed=%s landed=%s ranges=%s send_rc=%s audit_rc=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" "$holder" "$task" "$author" "$reviewer" "$sha" "$ACC_LANDED" \
    "$(paste -sd, <<<"$ACC_RANGES")" "$src" "$arc" >>"$log"
  echo "ACCEPTED $author task $task: $body"
}
