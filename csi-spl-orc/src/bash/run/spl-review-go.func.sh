#!/bin/bash
#------------------------------------------------------------------------------
# @description A verified cross-vendor review PASS sends the author its GO at
# @description once (spec 157 Rule 1, row B4, SPL-4101; owner HUM-10, t1
# @description 99ffa592 msg a99676b7: "What could be automated to be done
# @description without any intelligence?"). On the machine that holds the
# @description dispatch lease it reads the holder's spool ($SPOOL_ROOT/<holder>
# @description /{inbox,archive}, newer than REVIEW_GO_MAX_AGE minutes) for
# @description result / note messages holding an R7 line (`review: <id>@<box>
# @description <vendor> PASS|FAIL <sha> ran: ... | read: ... | log: ...`) sent
# @description by that reviewer, and checks each one, in this order (exit code
# @description of the check in brackets; REVIEW_GO_MSG runs one message file
# @description and returns it):
# @description   [1] the verdict is PASS (a FAIL is never checked further)
# @description   [3] the reviewer was placed for it: its brief ($SPOOL_ROOT/
# @description       <reviewer>/lifetime/brief.md, else, the seat retired,
# @description       dispatch/briefs/<title of its identity record>.md) has a
# @description       `| author | ... |` table row whose sha / head / commits
# @description       cell abbreviates the reviewed sha, or whose task cell is
# @description       the message's task; no such row: it names one author in
# @description       prose (`Author <id>@<box>`) and the sha or the task
# @description   [2] the reviewer's vendor differs from the author's
# @description       (rounds-rulebook 2.7.2; the vendor is the id letter)
# @description   [7] the author's own brief ($SPOOL_ROOT/<author>/lifetime/
# @description       brief.md, else the dispatch/briefs/<slug>.md the reviewer
# @description       brief names on its `Author brief:` line) is on this box
# @description       (unread = not verified)
# @description   [4] that brief names no owner-go keyword (apply, do-provision,
# @description       do-tf-apply, PROBE_PRD_GO, DRY_RUN=0, ENV=prd, IAM,
# @description       billing, service account key, /etc/; spec 7.1.2), or it
# @description       carries `Owner-go: <msg id>` and a message with that id
# @description       from HUM-<n> is in the holder's spool or desk spools
# @description   [6] the reviewer's log is on this box (do_spl_review_line_check
# @description       exit 2: never fetched), [8] and that check passes: every
# @description       module test named in ran: is a command in the log (a
# @description       docs-only line names none: refused)
# @description   [5] the row's branch on origin (git ls-remote, read only) is
# @description       still the reviewed sha
# @description All pass: `GO <sha>` goes to the author (spool-send, kind task,
# @description the row's task, from the holder), then the line (bare ids; the
# @description task_id is the review message's, the author the brief row's)
# @description `PASS <ts> <msg_id> <task_id> <author_id> <reviewer_id> <sha>`
# @description is appended to $SPOOL_ROOT/dispatch/automation.log (the record
# @description Rule 2 reads). Any refusal sends the holder one note on task
# @description review-go (no GO, no REJECT: the judgement stays the
# @description dispatcher's) and logs `<ts> review-go <msg_id> action=refused
# @description rc=<n> ...`. A message seen once is never checked again; a
# @description failed GO send is not logged, so the next run tries again.
# @description Nothing happens (rc 0) when the dispatch lease (LEASE_CMD=show
# @description do_spl_dispatch_lease, read only) is none, stale or held on
# @description another box. Lease files (spl-dispatch-lease*) are never
# @description written. Dry run unless DRY_RUN=0: it prints PLAN lines.
# @description The cron line: do_spl_review_go_install_cron.
# @param REVIEW_GO_MAX_AGE (optional) - minutes; older messages are not read, default 60
# @param REVIEW_GO_MSG (optional) - one message file: check it alone, return its exit code (0 when already logged)
# @param REVIEW_GO_REPO (optional) - the repo whose origin holds the branch, default this checkout
# @param REVIEW_GO_FROM (optional) - the hold note's sender, default lease.conf LEASE_ORCH, else role seat 1
# @param REVIEW_GO_SEND (optional) - the sender script, default spawn-agents/scripts/spool-send.sh (tests)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_review_go
# @example DRY_RUN=0 ./run -a do_spl_review_go
# @example REVIEW_GO_MSG=/var/spool-hub/c-002/archive/<file>.json ./run -a do_spl_review_go
#------------------------------------------------------------------------------
do_spl_review_go() {
  do_require_bin python3 || return 1
  local max="${REVIEW_GO_MAX_AGE:-60}" dry="${DRY_RUN:-1}" holder log rows n=0 msg task line rc
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL REVIEW_GO_MAX_AGE must be minutes (a positive integer), got: '$max'"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  spl_lease_init ro || return 1
  spl_lease_conf
  holder="$(_spl_review_go_holder)" || return 0
  log="$LEASE_DIR/automation.log"
  if [[ "$dry" == 0 ]]; then
    if ! { mkdir -p "$LEASE_DIR" && touch "$log"; }; then do_log "FATAL cannot write $log"; return 1; fi
    exec 7>"$LEASE_DIR/review-go.lock"
    flock -n 7 || { do_log "INFO another review GO run holds $LEASE_DIR/review-go.lock - skipped"; return 0; }
  fi
  if [[ -n "${REVIEW_GO_MSG:-}" ]]; then
    rows="$(_spl_review_go_scan "$max" "$REVIEW_GO_MSG")" || return 1
    [[ -n "$rows" ]] || { do_log "FATAL $REVIEW_GO_MSG holds no review line from its reviewer"; return 1; }
    IFS=$'\t' read -r msg task _ line <<<"$rows"
    _spl_review_go_seen "$msg" "$log" && { do_log "INFO msg $msg is in $log already: not checked again"; return 0; }
    _spl_review_go_one "$holder" "$msg" "$task" "$line" "$log" "$dry"; return
  fi
  rows="$(_spl_review_go_scan "$max" "$SPOOL_ROOT/$holder")" || { do_log "WARN could not read $SPOOL_ROOT/$holder"; return 1; }
  while IFS=$'\t' read -r msg task _ line; do
    [[ -n "$msg" ]] || continue
    _spl_review_go_seen "$msg" "$log" && continue
    rc=0; _spl_review_go_one "$holder" "$msg" "$task" "$line" "$log" "$dry" || rc=$?
    (( rc == 0 )) && n=$((n + 1))
  done <<<"$rows"
  do_log "OK review GO: holder $holder, $n GO(s) sent$([[ "$dry" == 1 ]] && echo ' (DRY_RUN: planned, nothing sent)')"
}

# _spl_review_go_holder: the bare id of the live dispatch lease holder on this
# machine; 1 (an INFO on stderr) when there is none, it is stale or remote.
_spl_review_go_holder() {
  local show age
  show="$(LEASE_CMD=show do_spl_dispatch_lease 2>/dev/null)" || { do_log "INFO the dispatch lease cannot be read: nothing to do" >&2; return 1; }
  read -r LH age <<<"$show"
  if [[ -z "$LH" || "$LH" == none || ! "$age" =~ ^[0-9]+$ ]] || (( age > LEASE_STALE )); then
    do_log "INFO no live dispatch lease holder (${show:-empty}): nothing to do" >&2; return 1
  fi
  spl_lease_remote && { do_log "INFO the dispatch lease is held by $LH, on another machine: its machine sends the GO" >&2; return 1; }
  spl_lease_holder_id
}

# _spl_review_go_seen <msg> <log>: 0 when automation.log already holds a PASS
# or a review-go line for the message.
_spl_review_go_seen() {
  grep -qE "^PASS [^ ]+ $1 | review-go $1 " "$2" 2>/dev/null
}

# _spl_review_go_scan <max minutes> <spool dir | message file>: one TSV row per
# result / note message whose body holds a `review: ` line sent by the
# reviewer it names: msg_id task_id from line, oldest first. A spool dir is
# read in inbox/ and archive/, by the delivery time its file names open with;
# REVIEW_GO_NOW pins the clock (tests).
_spl_review_go_scan() {
  python3 - "$1" "$2" "${REVIEW_GO_NOW:-}" <<'EOF_PY'
import datetime as dt, json, os, re, sys
mins, src, now = int(sys.argv[1]), sys.argv[2], sys.argv[3]
now = dt.datetime.strptime(now, "%Y-%m-%dT%H:%M:%SZ") if now else dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
cut = (now - dt.timedelta(minutes=mins)).strftime("%Y%m%dT%H%M%SZ")
files = [src] if os.path.isfile(src) else []
for sub in ("inbox", "archive") if not files else ():
    d = os.path.join(src, sub)
    try:
        files += [os.path.join(d, n) for n in os.listdir(d) if n.endswith(".json") and n[:16] >= cut]
    except OSError:
        pass
LINE = re.compile(r"^review: ([acgmq]-[0-9]{3,})@\S+ ")
rows = []
for f in files:
    try:
        with open(f) as fh:
            m = json.load(fh)
    except (OSError, ValueError):
        continue
    if not isinstance(m, dict) or m.get("kind") not in ("result", "note"):
        continue
    line = next((l.strip() for l in str(m.get("body", "")).split("\n") if l.startswith("review: ")), "")
    who = LINE.match(line)
    frm = str(m.get("from", ""))
    if who and frm.split("@")[0] == who.group(1) and "\t" not in line:
        rows.append((str(m.get("ts", "")), str(m.get("msg_id", "")), str(m.get("task_id", "")), frm, line))
for r in sorted(set(rows)):
    if re.fullmatch(r"[0-9a-f-]{8,36}", r[1]) and re.fullmatch(r"[A-Za-z0-9._-]+", r[2]):
        print("\t".join(r[1:]))
EOF_PY
}

# _spl_review_go_brief <reviewer>: the path of the reviewer's placed brief: its
# lifetime copy, else (a retired seat's lifetime dir is gone)
# dispatch/briefs/<slug>.md, the slug being the title of its live identity
# record or of its newest retired one (agents/retired/<id>.<spawned>.json).
_spl_review_go_brief() {
  local b="$SPOOL_ROOT/$1/lifetime/brief.md" rec="$SPOOL_ROOT/agents/$1.json" slug recs
  [[ -s "$b" ]] && { echo "$b"; return 0; }
  recs=("$SPOOL_ROOT/agents/retired/$1".*.json)
  [[ -s "$rec" ]] || rec="${recs[-1]}"
  slug="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("title") or "")' "$rec" 2>/dev/null)"
  if [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "$SPOOL_ROOT/dispatch/briefs/$slug.md"; else echo "$b"; fi
}

# _spl_review_go_abrief <author> <reviewer brief>: the path of the author's
# brief on this box: its lifetime copy, else the dispatch/briefs/<slug>.md the
# reviewer brief names on its `Author brief:` line (an author on another
# box). rc 1 when neither is here.
_spl_review_go_abrief() {
  local b="$SPOOL_ROOT/$1/lifetime/brief.md" p
  [[ -s "$b" ]] && { echo "$b"; return 0; }
  p="$(sed -nE 's/.*Author brief:[[:space:]]*([^[:space:];,]+\.md).*/\1/p' "$2" 2>/dev/null)"
  p="${p%%$'\n'*}"
  [[ "$p" == "$SPOOL_ROOT/dispatch/briefs/${p##*/}" && "${p##*/}" =~ ^[A-Za-z0-9._-]+\.md$ && -s "$p" ]] || return 1
  echo "$p"
}

# _spl_review_go_row <brief> <sha> <task>: author_id author_box branch task of
# the brief's `| author | ... |` table row for the review: its sha / head /
# commits cell holds an abbreviation of <sha> (7+ hex), else its task cell is
# <task>. No such row: the prose form placement briefs use (`Author
# c-805@<box> (claude)`, `Branch `review/<slug>``), only when the brief names
# one author and holds an abbreviation of <sha> or <task>. Nothing printed,
# rc 1, when neither matches.
_spl_review_go_row() {
  python3 - "$1" "$2" "$3" <<'EOF_PY'
import re, sys
brief, sha, task = sys.argv[1:4]
def cells(l):
    return [c.strip() for c in l.strip().strip("|").split("|")]
try:
    lines = open(brief, encoding="utf-8", errors="replace").read().split("\n")
except OSError:
    sys.exit(1)
rows, head = [], None
for l in lines:
    if not l.lstrip().startswith("|"):
        head = None
        continue
    c = cells(l)
    if head is None and any(x.lower() == "author" for x in c):
        head = [x.lower() for x in c]
    elif head and not re.fullmatch(r"[\s|:-]+", l):
        rows.append(dict(zip(head, c)))
def col(r, *names):
    return next((v for k, v in r.items() for n in names if k == n or k.startswith(n + " ")), "")
def hit(r):
    return any(sha.startswith(h) for h in re.findall(r"\b[0-9a-f]{7,40}\b", col(r, "sha", "head", "commits")))
for r in sorted(rows, key=lambda r: not hit(r)):
    a = re.match(r"([acgmq]-[0-9]{3,})(?:@([A-Za-z0-9._-]+))?", col(r, "author"))
    if a and (hit(r) or col(r, "task") == task):
        b = (col(r, "review branch", "branch").split() or [""])[0].strip("`")
        print("\t".join((a.group(1), a.group(2) or "", b, col(r, "task") or task)))
        sys.exit(0)
text = "\n".join(lines)
named = re.findall(r"(?i)\bauthor:?[ \t]+([acgmq]-[0-9]{3,})(?:@([A-Za-z0-9._-]+))?", text)
if len({i for i, _ in named}) != 1:
    sys.exit(1)
if task not in text and not any(sha.startswith(h) for h in re.findall(r"\b[0-9a-f]{7,40}\b", text)):
    sys.exit(1)
br = re.search(r"(?i)\bbranch[ \t]+`([A-Za-z0-9._/-]+)`", text) or re.search(r"\b(review/[A-Za-z0-9._/-]*[A-Za-z0-9_-])", text)
print("\t".join((named[0][0], next((b for _, b in named if b), ""), br.group(1) if br else "", task)))
EOF_PY
}

# _spl_review_go_owner_go <author brief> <holder>: 0 when the brief needs no
# owner go, or its `Owner-go: <msg id>` names a message from HUM-<n> found in
# the holder's spool or its desk spools; 1 (the why on stdout) otherwise.
_spl_review_go_owner_go() {
  local kw id
  kw="$(grep -oiE '\bapply\b' "$1")"
  [[ -n "$kw" ]] || kw="$(grep -oE 'do-provision|do-tf-apply|PROBE_PRD_GO|DRY_RUN=0|ENV=prd|\bIAM\b|\bbilling\b|service account key|/etc/' "$1")"
  [[ -n "$kw" ]] || return 0
  kw="${kw%%$'\n'*}"
  id="$(sed -n 's/^Owner-go:[[:space:]]*\([0-9a-f-]\{8,36\}\)[[:space:]]*$/\1/p' "$1")"
  id="${id%%$'\n'*}"
  [[ -n "$id" ]] || { echo "the author brief names owner-go keyword '$kw' and has no Owner-go: line"; return 1; }
  python3 - "$id" "$SPOOL_ROOT/$2" "${SPL_STATE_DIR:-/nonexistent}/desk" "$2" <<'EOF_PY' && return 0
import glob, json, os, re, sys
mid, spool, desk, holder = sys.argv[1:5]
dirs = [spool] + glob.glob(os.path.join(desk, "*", "*", "spool", holder))
for d in dirs:
    for f in glob.glob(os.path.join(d, "*", "*%s*.json" % mid[:8])):
        try:
            m = json.load(open(f))
        except (OSError, ValueError):
            continue
        if str(m.get("msg_id", "")).startswith(mid) and re.fullmatch(r"HUM-[0-9]+", str(m.get("from", ""))):
            sys.exit(0)
sys.exit(1)
EOF_PY
  echo "the author brief names owner-go keyword '$kw'; its Owner-go: $id is no HUM-<n> message on this box"
  return 1
}

# _spl_review_go_one <holder> <msg> <task> <line> <log> <dry>: every check of
# one review message; GO and the PASS record on success, else the hold note
# and the refusal line. Returns the check's exit code (see the header).
_spl_review_go_one() {
  local holder="$1" msg="$2" task="$3" line="$4" log="$5" dry="$6" rx why rc
  local rid rbox rven verdict sha author abox branch rtask brief abrief
  rx='^review: ([acgmq]-[0-9]{3,})@([A-Za-z0-9._-]+) ([a-z]+) ([A-Z]+) ([0-9a-f]{40}) '
  [[ "$line" =~ $rx ]] || { _spl_review_go_hold "$@" 1 "not an R7 line with a 40-hex sha"; return 1; }
  rid="${BASH_REMATCH[1]}" rbox="${BASH_REMATCH[2]}" rven="${BASH_REMATCH[3]}" verdict="${BASH_REMATCH[4]}" sha="${BASH_REMATCH[5]}"
  [[ "$verdict" == PASS ]] || { _spl_review_go_hold "$@" 1 "REVIEW $verdict from $rid@$rbox for ${sha:0:12}"; return 1; }
  brief="$(_spl_review_go_brief "$rid")"
  IFS=$'\t' read -r author abox branch rtask < <(_spl_review_go_row "$brief" "$sha" "$task")
  [[ -n "${author:-}" ]] || { _spl_review_go_hold "$@" 3 "unplaced reviewer or author not assigned in $brief"; return 3; }
  [[ "${author%%-*}" != "${rid%%-*}" ]] || { _spl_review_go_hold "$@" 2 "reviewer $rid ($rven) shares the vendor of author $author"; return 2; }
  abrief="$(_spl_review_go_abrief "$author" "$brief")" ||
    { _spl_review_go_hold "$@" 7 "author $author has no brief on this box ($SPOOL_ROOT/$author/lifetime/brief.md, nor an Author brief: line in $brief): not verified"; return 7; }
  why="$(_spl_review_go_owner_go "$abrief" "$holder")" ||
    { _spl_review_go_hold "$@" 4 "task touches owner-go scope: $why"; return 4; }
  why="$(REVIEW_LINE="$line" REVIEW_LINE_REPO="${REVIEW_GO_REPO:-}" do_spl_review_line_check 2>&1)"; rc=$?
  (( rc == 2 )) && { _spl_review_go_hold "$@" 6 "the reviewer's log is on box $rbox: run the check there (never fetched)"; return 6; }
  (( rc == 0 )) || { _spl_review_go_hold "$@" 8 "review line check failed (rc $rc): $(tail -n2 <<<"$why" | paste -sd' ')"; return 8; }
  why="$(_spl_review_go_tip "$branch")"
  [[ "$why" == "$sha" ]] || { _spl_review_go_hold "$@" 5 "branch '${branch:-none}' on origin is ${why:-missing}, not the reviewed ${sha:0:12}: re-review"; return 5; }
  _spl_review_go_send "$holder" "$msg" "$task" "$author" "$abox" "$rid" "$sha" "$log" "$dry" "${rtask:-$task}"
}

# _spl_review_go_tip <branch>: the sha origin's branch points at (read only:
# git ls-remote, nothing fetched into a shared checkout); empty when none.
_spl_review_go_tip() {
  local repo="${REVIEW_GO_REPO:-$(git -C "${BASH_SOURCE[0]%/*}" rev-parse --show-toplevel 2>/dev/null)}"
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]] || return 0
  git -C "$repo" ls-remote origin "refs/heads/$1" 2>/dev/null | awk 'NR == 1 {print $1}'
}

# _spl_review_go_send <holder> <msg> <task> <author> <author box> <reviewer>
# <sha> <log> <dry> <go task>: GO <sha> to the author on <go task> (the brief
# row's task), then the PASS record with the message's own task_id (Rule 2
# re-checks it against the message). A failed send logs nothing (the next
# run tries again) and returns 9.
_spl_review_go_send() {
  local to="$4${5:+@$5}" send="${REVIEW_GO_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  if [[ "$9" == 1 ]]; then
    echo "PLAN GO ${7} to $to on task ${10} from $1 (review msg $2 by $6), then PASS in automation.log"
    return 0
  fi
  SPOOL_ROOT="$SPOOL_ROOT" bash "$send" --from "$1" --to "$to" --kind task --task "${10}" --body "GO $7" \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || { do_log "WARN msg $2: GO to $to failed; the next run tries again"; return 9; }
  printf 'PASS %s %s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$4" "$6" "$7" >>"$8"
  do_log "OK msg $2: GO ${7:0:12} sent to $to (review PASS by $6)"
}

# _spl_review_go_hold <holder> <msg> <task> <line> <log> <dry> <rc> <why>:
# the refusal, logged once and told to the holder; no GO, no REJECT.
_spl_review_go_hold() {
  local holder="$1" msg="$2" task="$3" log="$5" dry="$6" rc="$7" why="$8" erc=0
  local who="${REVIEW_GO_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}" send="${REVIEW_GO_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  if [[ "$dry" == 1 ]]; then
    echo "PLAN HOLD msg $msg (rc $rc): $why"
    return 0
  fi
  SPOOL_ROOT="$SPOOL_ROOT" bash "$send" --from "$who" --to "$holder" --kind note --task review-go \
    --body "REVIEW-GO HOLD (spec 157 rule 1, rc $rc): review msg $msg on task $task: $why. No GO sent; the next step is yours." \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || erc=$?
  printf '%s review-go %s action=refused rc=%s task=%s holder=%s note_rc=%s why=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" "$rc" "$task" "$holder" "$erc" "$why" >>"$log"
  do_log "INFO msg $msg: REFUSED (rc $rc) $why"
}
