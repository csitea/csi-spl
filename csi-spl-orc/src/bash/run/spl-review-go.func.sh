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
# @description   [1] the verdict is PASS (a FAIL is never checked further),
# @description       and the read: part does not say FAIL as a verdict
# @description       (`JUDGMENT|VERDICT|OVERALL|REVIEW FAIL`, `FAIL W<n>`;
# @description       a count such as `red control 2 FAIL` is no verdict)
# @description   [3] the reviewer was placed for it: its brief has a
# @description       `| author | ... |` table row whose sha / head / commits
# @description       cell abbreviates the reviewed sha, or whose task cell is
# @description       the message's task; no such row: it names one author in
# @description       prose (`Author <id>@<box>`) and the sha or the task.
# @description       The reviewer is <id>@<box> of the message's from (a bare
# @description       from is this box: LEASE_MACHINE, else the desk box). On
# @description       this box its brief is $SPOOL_ROOT/<reviewer>/lifetime/
# @description       brief.md, else (the seat retired) dispatch/briefs/<title
# @description       of its identity record>.md; a seat of another box is
# @description       never judged on this box's records of the same id (one
# @description       id can be two seats, c-700@<box-a> and c-700@<box-b>, SPL-4427).
# @description       Then, either box, the fleet lane map's rows of <id>@<box>
# @description       (the hub, read as do_spl_lane_map reads it): dispatch/
# @description       briefs/<slug of the row's <id>-<slug> branch>.md, else
# @description       the briefs whose first heading the row's scope opens;
# @description       the first whose row matches. None: rc 3 naming both
# @description       boxes
# @description   [2] the reviewer's vendor differs from the author's
# @description       (rounds-rulebook 2.7.2; the vendor is the id letter)
# @description   [7] the author's own brief ($SPOOL_ROOT/<author>/lifetime/
# @description       brief.md when the row's author box is this box or none,
# @description       else the dispatch/briefs/<slug>.md the reviewer brief
# @description       names on its `Author brief:` line, else the lane map's
# @description       as in [3], a scope match only when it is one brief,
# @description       and only a brief tied to the work: named <slug> of the
# @description       row's review/<slug> branch, or naming that branch or
# @description       the sha; never the task, a shared topic) is
# @description       on this box (unread = not verified)
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
# @description  [10] no other review seat waits: every other dispatch/briefs/
# @description       <slug>.md naming the same one author and the reviewed
# @description       sha (an agy strings seat beside the grok R7, SPL-4251)
# @description       has its verified PASS logged as `WAIT <ts> <msg_id>
# @description       <task_id> <author_id> <reviewer_id> <sha> <slug>`; while
# @description       one has none, this PASS is logged as such a WAIT line
# @description       (the holder told once) and the GO waits for the last
# @description       seat's PASS; a seat retired (every identity record
# @description       titled <slug> is in agents/retired/, none live) that
# @description       sent the holder no review line for the sha waits for
# @description       nothing (it was re-placed, SPL-4316)
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
# @param SPOOL_ROOT (optional) - the spool root, default /var/spool-hub (the cron line sets none)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_review_go
# @example DRY_RUN=0 ./run -a do_spl_review_go
# @example REVIEW_GO_MSG=/var/spool-hub/c-002/archive/<file>.json ./run -a do_spl_review_go
#------------------------------------------------------------------------------
do_spl_review_go() {
  do_require_bin python3 || return 1
  local max="${REVIEW_GO_MAX_AGE:-60}" dry="${DRY_RUN:-1}" holder log rows n=0 msg task from line rc
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL REVIEW_GO_MAX_AGE must be minutes (a positive integer), got: '$max'"; return 1; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1"; return 1; }
  # The cron line exports no SPOOL_ROOT: spl_lease_init's default, set before
  # its first use (SPL-4316; under set -u both cron ticks died on line 96).
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
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
    IFS=$'\t' read -r msg task from line <<<"$rows"
    _spl_review_go_seen "$msg" "$log" && { do_log "INFO msg $msg is in $log already: not checked again"; return 0; }
    _spl_review_go_one "$holder" "$msg" "$task" "$line" "$log" "$dry" "$from"; return
  fi
  rows="$(_spl_review_go_scan "$max" "$SPOOL_ROOT/$holder")" || { do_log "WARN could not read $SPOOL_ROOT/$holder"; return 1; }
  while IFS=$'\t' read -r msg task from line; do
    [[ -n "$msg" ]] || continue
    _spl_review_go_seen "$msg" "$log" && continue
    rc=0; _spl_review_go_one "$holder" "$msg" "$task" "$line" "$log" "$dry" "$from" || rc=$?
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

# _spl_review_go_seen <msg> <log>: 0 when automation.log already holds a PASS,
# a WAIT or a review-go line for the message.
_spl_review_go_seen() {
  grep -qE "^(PASS|WAIT) [^ ]+ $1 | review-go $1 " "$2" 2>/dev/null
}

# _spl_review_go_read_fail <line>: 0 when the line's read: part says FAIL as
# a verdict (g-161 had to write `grok PASS ... read: JUDGMENT FAIL W1`, msg
# 95d5ed90). A count is no verdict: 1 of 242 PASS lines on a box matched this,
# 36 named FAIL for a red control (one box, since 2026-10-22).
_spl_review_go_read_fail() {
  local r="${1#* | read: }"
  r="${r%% | log: *}"
  grep -qiE '\b(judgment|judgement|verdict|overall|review)\b[^a-z0-9]{0,3}fail(ed)?\b|\bfail(ed)?\b[^a-z0-9]{0,3}w[0-9]+\b' <<<"$r"
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

# _spl_review_go_here: this box, as spl_lease_remote names it.
_spl_review_go_here() { echo "${LEASE_MACHINE:-$(spl_desk_box_default)}"; }

# _spl_review_go_brief <reviewer> <its box> <sha> <task>: the path of the
# reviewer's placed brief. On this box: its lifetime copy, else (a retired
# seat's lifetime dir is gone) dispatch/briefs/<slug>.md, the slug being the
# title of its live identity record or of its newest retired one
# (agents/retired/<id>.<spawned>.json). A seat of another box is never read
# from this box's records: the same id here may be another seat (SPL-4427).
# Then the lane map's briefs (_spl_review_go_lane_briefs): the first whose
# row matches the sha or task, else the first. A seat of another box with
# none: nothing printed, rc 1.
_spl_review_go_brief() {
  local b="$SPOOL_ROOT/$1/lifetime/brief.md" here slug c first=""
  here="$(_spl_review_go_here)"
  if [[ "$2" == "$here" ]]; then
    [[ -s "$b" ]] && { echo "$b"; return 0; }
    slug="$(_spl_review_go_title "$1")"
    [[ -n "$slug" ]] && { echo "$SPOOL_ROOT/dispatch/briefs/$slug.md"; return 0; }
  fi
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    first="${first:-$c}"
    _spl_review_go_row "$c" "$3" "$4" >/dev/null && { echo "$c"; return 0; }
  done < <(_spl_review_go_lane_briefs "$1" "$2" all)
  [[ -n "$first" ]] && { echo "$first"; return 0; }
  [[ "$2" == "$here" ]] || return 1
  echo "$b"
}

# _spl_review_go_lanes: the fleet lane map's hub rows (JSON, `.lanes`), read
# as do_spl_lane_map reads them (spl_lane_init, spl_lane_hub_read), in a
# subshell; rc 1 with no fleet or no hub answer.
_spl_review_go_lanes() {
  (
    { spl_lane_init && [[ "$LANE_MODE" == hub ]] && spl_lane_hub_read; } >/dev/null 2>&1 || exit 1
    printf '%s' "$LANE_HUB_JSON"
  )
}

# _spl_review_go_lane_briefs <id> <box> <all|one>: the dispatch/briefs/<slug>.md
# copies of the seat <id>@<box> by its lane map rows, newest row first, one
# per line: the slug of an <id>-<slug> branch (a rotated seat's branch is
# <id>-rotate: no brief), then the briefs whose first heading (`#`s and
# `Brief:` dropped, as the spawn writes the scope; cut to 120 or 500) the
# row's scope opens. With `one` a scope match counts only when the matches
# are one brief's content (the author check reads the one it gets).
_spl_review_go_lane_briefs() {
  local f
  f="$(mktemp)" || return 0
  _spl_review_go_lanes >"$f" || { rm -f "$f"; return 0; }
  python3 - "$1" "$2" "$3" "$SPOOL_ROOT/dispatch/briefs" "$f" <<'EOF_PY'
import glob, json, os, re, sys
rid, box, mode, bdir, src = sys.argv[1:6]
try:
    rows = [r for r in json.load(open(src)).get("lanes", []) if isinstance(r, dict) and r.get("agent_id") == rid and r.get("agent_box") == box]
except (OSError, ValueError, AttributeError):
    sys.exit(0)
rows.sort(key=lambda r: str(r.get("updated_at", "")), reverse=True)
heads = None
def head(f):
    try:
        with open(f, encoding="utf-8", errors="replace") as fh:
            for l in fh:
                if re.match(r"#+ ", l):
                    return re.sub(r"^Brief: *", "", re.sub(r"^#+ +", "", l.strip()))
    except OSError:
        pass
    return ""
out = []
for r in rows:
    br = str(r.get("branch") or "")
    slug = br[len(rid) + 1:] if br.startswith(rid + "-") else ""
    p = os.path.join(bdir, slug + ".md")
    if re.fullmatch(r"[A-Za-z0-9._-]+", slug) and os.path.isfile(p) and os.path.getsize(p):
        out.append(p)
    sc = str(r.get("scope") or "").strip()
    if len(sc) < 12:
        continue
    if heads is None:
        heads = {f: head(f) for f in sorted(glob.glob(os.path.join(bdir, "*.md")))}
    hit = [f for f, h in heads.items() if h.startswith(sc) or (len(sc) >= 120 and h.startswith(sc[:-1]))]
    if mode == "one" and len({open(f, "rb").read() for f in hit}) != 1:
        continue
    out += hit
for p in dict.fromkeys(out):
    print(p)
EOF_PY
  rm -f "$f"
}

# _spl_review_go_title <id>: the title (placement slug) of the seat's live
# identity record, else of its newest retired one; empty when none is valid.
_spl_review_go_title() {
  local rec="$SPOOL_ROOT/agents/$1.json" recs slug
  recs=("$SPOOL_ROOT/agents/retired/$1".*.json)
  [[ -s "$rec" ]] || rec="${recs[-1]}"
  slug="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("title") or "")' "$rec" 2>/dev/null)"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+$ ]] && echo "$slug"
  return 0
}

# _spl_review_go_slug <reviewer> <its brief>: the reviewer's placement slug:
# the brief's name when it is a dispatch/briefs copy, else its identity
# title, else `-` (no sibling brief is then ever matched to it).
_spl_review_go_slug() {
  local t
  if [[ "$2" == "$SPOOL_ROOT/dispatch/briefs/"*.md ]]; then t="${2##*/}"; echo "${t%.md}"; return 0; fi
  t="$(_spl_review_go_title "$1")"
  echo "${t:--}"
}

# _spl_review_go_siblings <reviewer> <its brief> <author> <sha> <log> <holder>:
# the slugs of the OTHER review seats for the same author and sha still
# without a WAIT line, space-separated; nothing when none waits. A sibling is
# a dispatch/briefs/<slug>.md, not the reviewer's own (by slug or content),
# whose row (_spl_review_go_row, matched by the sha only) names the author,
# and whose seat is not gone (_spl_review_go_gone).
_spl_review_go_siblings() {
  local own f slug gone miss=()
  own="$(_spl_review_go_slug "$1" "$2")"
  while IFS= read -r f; do
    slug="${f##*/}" && slug="${slug%.md}"
    [[ "$slug" == "$own" ]] || cmp -s "$f" "$2" && continue
    [[ "$(_spl_review_go_row "$f" "$4" '@@no-task@@' | cut -f1)" == "$3" ]] || continue
    grep -qE "^WAIT [^ ]+ [^ ]+ [^ ]+ $3 [^ ]+ $4 $slug\$" "$5" 2>/dev/null && continue
    gone="$(_spl_review_go_gone "$slug" "$4" "$6")" &&
      { do_log "INFO review seat $slug ($gone) retired with no review line for ${4:0:12}: re-placed, not waited for" >&2; continue; }
    miss+=("$slug")
  done < <(grep -lF -- "${4:0:7}" "$SPOOL_ROOT"/dispatch/briefs/*.md 2>/dev/null)
  echo "${miss[*]}"
}

# _spl_review_go_gone <slug> <sha> <holder>: 0 (the retired ids on stdout)
# when the seat placed under <slug> is gone: every identity record titled
# <slug> is a retired one (agents/retired/<id>.<spawned>.json, written by
# agent-id-retire.sh), none is live (agents/<id>.json), and none of those ids
# sent the holder (inbox/, archive/) a review line for <sha>. A seat not yet
# spawned (no record), live, or whose PASS or FAIL is in the spool: rc 1.
_spl_review_go_gone() {
  python3 - "$SPOOL_ROOT" "$1" "$2" "$3" <<'EOF_PY'
import glob, json, os, re, sys
root, slug, sha, holder = sys.argv[1:5]
def ids(pat):
    out = set()
    for f in glob.glob(os.path.join(root, "agents", pat)):
        try:
            r = json.load(open(f))
        except (OSError, ValueError):
            continue
        if isinstance(r, dict) and r.get("title") == slug and re.fullmatch(r"[acgmq]-[0-9]{3,}", str(r.get("id", ""))):
            out.add(r["id"])
    return out
gone = set() if ids("*.json") else ids(os.path.join("retired", "*.json"))
if not gone:
    sys.exit(1)
line = re.compile(r"review: (?:%s)@\S+ [a-z]+ [A-Z]+ %s" % ("|".join(map(re.escape, sorted(gone))), sha))
for sub in ("inbox", "archive"):
    for f in glob.glob(os.path.join(root, holder, sub, "*.json")):
        try:
            with open(f) as fh:
                txt = fh.read()
            if sha in txt and line.search(str(json.loads(txt).get("body", ""))):
                sys.exit(1)
        except (OSError, ValueError, AttributeError):
            continue
print(" ".join(sorted(gone)))
EOF_PY
}

# _spl_review_go_abrief <author> <reviewer brief> <author box> <review
# branch> <sha>: the path of the author's brief on this box: its
# lifetime copy when the author box is this box or none (another box's seat
# may share the id, SPL-4427), else the dispatch/briefs/<slug>.md the reviewer
# brief names on its `Author brief:` line, else the first of the lane map's
# (_spl_review_go_lane_briefs, a scope match only when it is one brief) tied
# to the reviewed work (_spl_review_go_tied): a re-tasked or rotated seat's
# new lane brief is never read for it (R7 c-972 N1). rc 1 when none is here.
_spl_review_go_abrief() {
  local b="$SPOOL_ROOT/$1/lifetime/brief.md" here p c
  here="$(_spl_review_go_here)"
  [[ ( -z "$3" || "$3" == "$here" ) && -s "$b" ]] && { echo "$b"; return 0; }
  p="$(sed -nE 's/.*Author brief:[[:space:]]*([^[:space:];,]+\.md).*/\1/p' "$2" 2>/dev/null)"
  p="${p%%$'\n'*}"
  if [[ "$p" == "$SPOOL_ROOT/dispatch/briefs/${p##*/}" && "${p##*/}" =~ ^[A-Za-z0-9._-]+\.md$ && -s "$p" ]]; then echo "$p"; return 0; fi
  while IFS= read -r c; do
    _spl_review_go_tied "$c" "$4" "$5" && { echo "$c"; return 0; }
  done < <(_spl_review_go_lane_briefs "$1" "${3:-$here}" one)
  return 1
}

# _spl_review_go_tied <brief> <review branch> <sha>: 0 when the brief is the
# review branch's own (dispatch/briefs/<slug>.md of review/<slug>) or names
# the review branch or an abbreviation (7+ hex) of the sha. Never the task:
# it is usually a shared dispatch or owner topic (one owner topic id was in 34
# briefs), so a seat re-tasked in the same topic would be tied (R7 c-972 W1).
_spl_review_go_tied() {
  local h
  [[ "$2" == review/?* && "$1" == "$SPOOL_ROOT/dispatch/briefs/${2#review/}.md" ]] && return 0
  [[ -n "$2" ]] && grep -qF -- "$2" "$1" && return 0
  while IFS= read -r h; do
    [[ -n "$h" && "$3" == "$h"* ]] && return 0
  done < <(grep -oE '\b[0-9a-f]{7,40}\b' "$1")
  return 1
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

# _spl_review_go_one <holder> <msg> <task> <line> <log> <dry> <from>: every
# check of one review message (<from>: its sender, <id> or <id>@<box>); GO and
# the PASS record on success, else the hold note and the refusal line.
# Returns the check's exit code (see the header).
_spl_review_go_one() {
  local holder="$1" msg="$2" task="$3" line="$4" log="$5" dry="$6" from="${7:-}" rx why rc here mbox
  local rid rbox rven verdict sha author abox branch rtask brief abrief
  set -- "${@:1:6}"
  here="$(_spl_review_go_here)" mbox="${from##*@}"
  [[ "$from" == *@* ]] || mbox="$here"
  rx='^review: ([acgmq]-[0-9]{3,})@([A-Za-z0-9._-]+) ([a-z]+) ([A-Z]+) ([0-9a-f]{40}) '
  [[ "$line" =~ $rx ]] || { _spl_review_go_hold "$@" 1 "not an R7 line with a 40-hex sha"; return 1; }
  rid="${BASH_REMATCH[1]}" rbox="${BASH_REMATCH[2]}" rven="${BASH_REMATCH[3]}" verdict="${BASH_REMATCH[4]}" sha="${BASH_REMATCH[5]}"
  [[ "$verdict" == PASS ]] || { _spl_review_go_hold "$@" 1 "REVIEW $verdict from $rid@$rbox for ${sha:0:12}"; return 1; }
  ! _spl_review_go_read_fail "$line" || { _spl_review_go_hold "$@" 1 "PASS header but its read: says FAIL from $rid@$rbox for ${sha:0:12}"; return 1; }
  brief="$(_spl_review_go_brief "$rid" "$mbox" "$sha" "$task")" ||
    { _spl_review_go_hold "$@" 3 "reviewer $rid@$mbox runs on box $mbox: no brief for it on this box $here (its records here are not read for another box's seat; the lane map names no dispatch/briefs copy): brief on another box, not judged"; return 3; }
  IFS=$'\t' read -r author abox branch rtask < <(_spl_review_go_row "$brief" "$sha" "$task")
  [[ -n "${author:-}" ]] || { _spl_review_go_hold "$@" 3 "unplaced reviewer or author not assigned in $brief"; return 3; }
  [[ "${author%%-*}" != "${rid%%-*}" ]] || { _spl_review_go_hold "$@" 2 "reviewer $rid ($rven) shares the vendor of author $author"; return 2; }
  abrief="$(_spl_review_go_abrief "$author" "$brief" "$abox" "$branch" "$sha")" ||
    { _spl_review_go_hold "$@" 7 "author $author has no brief on this box $here (author box ${abox:-not named}; not $SPOOL_ROOT/$author/lifetime/brief.md, an Author brief: line in $brief or the lane map): not verified"; return 7; }
  why="$(_spl_review_go_owner_go "$abrief" "$holder")" ||
    { _spl_review_go_hold "$@" 4 "task touches owner-go scope: $why"; return 4; }
  why="$(REVIEW_LINE="$line" REVIEW_LINE_REPO="${REVIEW_GO_REPO:-}" do_spl_review_line_check 2>&1)"; rc=$?
  (( rc == 2 )) && { _spl_review_go_hold "$@" 6 "the reviewer's log is on box $rbox: run the check there (never fetched)"; return 6; }
  (( rc == 0 )) || { _spl_review_go_hold "$@" 8 "review line check failed (rc $rc): $(tail -n2 <<<"$why" | paste -sd' ')"; return 8; }
  why="$(_spl_review_go_tip "$branch")"
  [[ "$why" == "$sha" ]] || { _spl_review_go_hold "$@" 5 "branch '${branch:-none}' on origin is ${why:-missing}, not the reviewed ${sha:0:12}: re-review"; return 5; }
  why="$(_spl_review_go_siblings "$rid" "$brief" "$author" "$sha" "$log" "$holder")"
  [[ -z "$why" ]] || { _spl_review_go_wait "$@" "$author" "$rid" "$sha" "$(_spl_review_go_slug "$rid" "$brief")" "$why"; return 10; }
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

# _spl_review_go_wait <holder> <msg> <task> <line> <log> <dry> <author>
# <reviewer> <sha> <slug> <waiting slugs>: a verified PASS while other review
# seats wait: the WAIT record (what the last seat's check reads) and one note
# to the holder; no GO.
_spl_review_go_wait() {
  local who="${REVIEW_GO_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}" send="${REVIEW_GO_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  local why="PASS by $8 verified for $7 ${9:0:12}; the GO waits for the other review seat(s): ${11}"
  if [[ "$6" == 1 ]]; then
    echo "PLAN WAIT msg $2 (rc 10): $why"
    return 0
  fi
  printf 'WAIT %s %s %s %s %s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3" "$7" "$8" "$9" "${10}" >>"$5"
  SPOOL_ROOT="$SPOOL_ROOT" bash "$send" --from "$who" --to "$1" --kind note --task review-go \
    --body "REVIEW-GO WAIT (spec 157 rule 1, rc 10): review msg $2 on task $3: $why. No GO yet; the last seat's PASS sends it." \
    >/dev/null 2>&1 7>&- 8>&- 9>&- || do_log "WARN msg $2: the WAIT note to $1 failed"
  do_log "INFO msg $2: WAIT (rc 10) $why"
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
