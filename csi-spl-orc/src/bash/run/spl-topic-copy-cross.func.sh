#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy ONE topic, or a selection of its messages, into a channel
# @description of ANOTHER workspace as a new topic, then point the source at
# @description the copy and archive it: the cross-workspace form of
# @description do_spl_topic_move, which stays same-workspace (owner HUM-10,
# @description csitea topic 8da3f62a: "Move this whole discussion to the GitHub
# @description channel of the Siena Capital workspace", then "split the
# @description messages of this whole topic into two topics").
# @description A COPY through the hub, never a cross-tenant DB write: the source
# @description is read with `spool hub-tail` by a desk seated in SRC_TENANT,
# @description the copy is written with `spool send --channel` by a desk seated
# @description in DST_TENANT, each under its own workspace's RLS.
# @description   1. read the source topic, oldest first (the union of what the
# @description      SRC_DESK_BOXES hold, one row per msg_id); MSG_IDS keeps
# @description      only the named messages (a split = one run per part)
# @description   2. post them into DST_CHANNEL as one new topic. With TITLE the
# @description      root is a title post and every message a reply; without
# @description      it the first message is the root. Every copied message
# @description      opens with "**<display name>** · <YYYY-MM-DD HH:MM> UTC"
# @description      of the original (names from SRC_NAMES_FILE or the member
# @description      list, never an e-mail address; an agent is its id). The
# @description      root carries the marker "Copied from workspace <src>, topic
# @description      <uuid>". Each blob attachment is fetched from the source
# @description      and put again in the target, never linked back.
# @description   3. LINK_BACK=1: "Moved to <link>" in the source topic, through
# @description      do_spl_desk_reply; ARCHIVE=1: do_spl_topic_archive on it.
# @description      For a split, run every part but the last with ARCHIVE=0.
# @description IDEMPOTENT: the target topic id is derived from (source tenant,
# @description topic, target tenant, channel, TITLE, MSG_IDS, COPY_TAG), so a re-run finds
# @description the copy, checks its marker and the header of every post it
# @description already holds, and posts only the rest; a link-back already
# @description there is not repeated.
# @description Prints one JSON line (messages, posts, posted, already,
# @description attachments, first and last header, target topic, permalink).
# @description Dry run unless DRY_RUN=0: the dry run reads the source and lists
# @description every post it would make (msg id, header, first characters), and
# @description sends nothing.
# @param ENV - required: dev or prd, or self (a self-hosted hub: do_spl_desk_cnf)
# @param SRC_TENANT - required: the workspace the topic is in
# @param SRC_TOPIC_ID - required: the topic's task uuid (the ?topic= of the WUI URL)
# @param DST_TENANT - required: the workspace to copy it into (not SRC_TENANT)
# @param DST_CHANNEL - required: the target channel id (a leading # is dropped)
# @param SRC_DESK_AGENT - required unless DESK_AGENT: the source desk's agent (link-back, archive)
# @param DST_DESK_AGENT - required unless DESK_AGENT: the target desk's agent, a member of DST_CHANNEL
# @param MSG_IDS (optional) - space- or comma-separated source msg ids (or unique
# @param   prefixes of 8+ hex) to copy, kept in source order; default every message
# @param TITLE (optional) - the opening title of the new topic (one line, <= 200 chars)
# @param SRC_DESK_BOXES (optional) - space-separated source desk boxes to read, default the desk box
# @param DST_DESK_BOX (optional) - default the desk box, the same value do_spl_desk_up used
# @param SRC_NAMES_FILE (optional) - a JSON object {"HUM-10": "FirstName LastName", ...};
# @param   default: the display names do_spl_hub_member_list reads for SRC_TENANT
# @param LINK_TO (optional) - the HUM-* the link-back answers, default the topic's first
# @param   human sender, else the first human it was addressed to
# @param LINK_BACK (optional) - 1 (default) or 0: post the link-back in the source
# @param ARCHIVE (optional) - 1 (default) or 0: archive the source afterwards
# @param DST_WUI_URL (optional) - the target WUI base, default its tenant host <tenant>.<fqdn>
# @param   when env.dns.mapped_tenants lists it, else (and for t1) the apex
# @param COPY_TAG (optional) - a-z 0-9 -: a NEW target topic for the same inputs (a repair
# @param   re-copy); every run of that copy must pass the same tag
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd SRC_TENANT=csitea SRC_TOPIC_ID=0f8fad5b-d9cb-469f-a165-70867728950e DST_TENANT=t1 DST_CHANNEL=dev DESK_AGENT=c-001 ./run -a do_spl_topic_copy_cross
# @example ENV=dev SRC_TENANT=t1 SRC_TOPIC_ID=0f8fad5b-d9cb-469f-a165-70867728950e DST_TENANT=e2e DST_CHANNEL=dev DESK_AGENT=c-001 MSG_IDS='1a2b3c4d 5e6f7a8b' TITLE='Part 1' ARCHIVE=0 DRY_RUN=0 ./run -a do_spl_topic_copy_cross
#------------------------------------------------------------------------------
do_spl_topic_copy_cross() {
  : "${SRC_TENANT:?SRC_TENANT must be set (no default) - the workspace the topic is in}"
  : "${SRC_TOPIC_ID:?SRC_TOPIC_ID must be set (no default) - the task uuid of the topic}"
  : "${DST_TENANT:?DST_TENANT must be set (no default) - the workspace to copy into}"
  : "${DST_CHANNEL:?DST_CHANNEL must be set (no default) - the target channel id}"
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local box_default; box_default="$(spl_desk_box_default)"
  local src_t="$SRC_TENANT" dst_t="$DST_TENANT" topic="$SRC_TOPIC_ID" channel="${DST_CHANNEL#\#}"
  local src_a="${SRC_DESK_AGENT:-${DESK_AGENT:-}}" dst_a="${DST_DESK_AGENT:-${DESK_AGENT:-}}"
  local dst_box="${DST_DESK_BOX:-$box_default}" title="${TITLE:-}" sel="${MSG_IDS:-}" src_boxes=()
  local link_back="${LINK_BACK:-1}" archive="${ARCHIVE:-1}" tag="${COPY_TAG:-}"
  read -r -a src_boxes <<<"${SRC_DESK_BOXES:-$box_default}"
  sel="$(tr ',' ' ' <<<"$sel" | xargs)"
  _spl_tcc_check_args || return 1

  local hub="$SPL_HUB_URL" work rc=0
  work="$(mktemp -d "${TMPDIR:-/tmp}/spl-topic-copy.XXXXXX")" || { do_log "FATAL could not make a work dir"; return 1; }
  _spl_tcc_run || rc=$?
  rm -rf "$work"
  return "$rc"
}

# _spl_tcc_run: the body of do_spl_topic_copy_cross, with its locals and the
# scratch dir $work (removed by the caller whatever happens here).
_spl_tcc_run() {
  local b d
  for b in "${src_boxes[@]}"; do
    d="$SPL_STATE_DIR/desk/$src_t/$b"
    [[ -d "$d/spool" ]] || { do_log "FATAL no desk box $b in $src_t to read the source with ($d): do_spl_desk_up seats one"; return 1; }
  done
  spl_host_spool || return 1
  _spl_tcc_read_source || return 1
  _spl_tcc_names >"$work/names.json" || return 1
  local dst_task wui link
  dst_task="$(_spl_tcc_task_id "$src_t" "$topic" "$dst_t" "$channel" "$title" "$sel" ${tag:+"$tag"})"
  wui="$(_spl_tcc_wui "$dst_t")"
  link="$wui/t/$dst_task"
  _spl_tcc_plan "$work/src.ndjson" "$work/names.json" "$src_t" "$topic" "$sel" "$title" >"$work/plan.json" 2>"$work/plan.err" ||
    { do_log "FATAL cannot plan the copy of $topic: $(cat "$work/plan.err")"; return 1; }
  local n nmsg
  n="$(_spl_tcc_jq "$work/plan.json" 'len(d)')"
  nmsg="$(_spl_tcc_jq "$work/plan.json" 'sum(1 for p in d if p["msg_id"])')"
  (( nmsg > 0 )) || { do_log "FATAL the desk boxes ${src_boxes[*]} hold no message of topic $topic in $src_t"; return 1; }
  if (( dry )); then
    _spl_tcc_dry_report
    return 0
  fi
  local dd="$SPL_STATE_DIR/desk/$dst_t/$dst_box"
  [[ -d "$dd/spool/$dst_a" ]] || { do_log "FATAL no desk for $dst_a on $dst_box in $dst_t: run do_spl_desk_up first ($dd)"; return 1; }
  local have posted=0
  have="$(_spl_tcc_resume "$dd" "$dst_task")" || return 1
  _spl_tcc_post_rest "$dd" "$dst_task" "$have" || return 1
  if [[ "$link_back" == 1 ]]; then _spl_tcc_link_back "$link" "$nmsg" || return 1; fi
  if [[ "$archive" == 1 ]]; then
    (
      # shellcheck disable=SC2034 # read by do_spl_topic_archive in this subshell
      TENANT_ID="$src_t" DESK_AGENT="$src_a" DESK_BOX="${src_boxes[0]}" TOPIC="$topic" MODE=archive DRY_RUN=0
      do_spl_topic_archive >/dev/null
    ) || { do_log "FATAL the copy is complete ($link) but archiving $topic in $src_t failed: re-run, it continues"; return 1; }
  fi
  _spl_tcc_summary "$posted" "$have" "$dst_task" "$link" 0
  do_log "OK copied $nmsg message(s) of $src_t topic $topic to #$channel in $dst_t ($posted post(s) now, $have already there): $link; link-back=$link_back archive=$archive"
}

# _spl_tcc_check_args: the inputs of do_spl_topic_copy_cross, else the FATAL
# naming the bad one.
_spl_tcc_check_args() {
  local uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' b id
  [[ "$topic" =~ $uuid_re ]] || { do_log "FATAL SRC_TOPIC_ID must be the topic's lowercase task UUID, got: '$topic'"; return 1; }
  [[ "$channel" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]] || { do_log "FATAL DST_CHANNEL must be a lowercase channel id, got: '$DST_CHANNEL'"; return 1; }
  [[ "$src_t" != "$dst_t" ]] || { do_log "FATAL SRC_TENANT and DST_TENANT are both $src_t: use do_spl_topic_move within one workspace"; return 1; }
  [[ -n "$src_a" ]] || { do_log "FATAL SRC_DESK_AGENT (or DESK_AGENT) must name the source desk's agent"; return 1; }
  [[ -n "$dst_a" ]] || { do_log "FATAL DST_DESK_AGENT (or DESK_AGENT) must name the target desk's agent"; return 1; }
  (( ${#src_boxes[@]} > 0 )) || { do_log "FATAL SRC_DESK_BOXES names no box"; return 1; }
  for b in "${src_boxes[@]}"; do spl_desk_validate "$src_t" "$b" "$src_a" || return 1; done
  spl_desk_validate "$dst_t" "$dst_box" "$dst_a" || return 1
  for id in $sel; do
    [[ "$id" =~ ^[0-9a-f]{8}([0-9a-f-]{0,28})$ ]] || { do_log "FATAL MSG_IDS entry must be a msg id or a prefix of 8+ hex, got: '$id'"; return 1; }
  done
  [[ ${#title} -le 200 && "$title" != *$'\n'* ]] || { do_log "FATAL TITLE must be one line of at most 200 characters"; return 1; }
  [[ -z "$tag" || "$tag" =~ ^[a-z0-9-]{1,32}$ ]] || { do_log "FATAL COPY_TAG must be 1..32 of a-z 0-9 -, got: '$tag'"; return 1; }
  [[ "$link_back" =~ ^[01]$ && "$archive" =~ ^[01]$ ]] || { do_log "FATAL LINK_BACK and ARCHIVE must be 0 or 1"; return 1; }
  [[ -z "${LINK_TO:-}" || "$LINK_TO" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL LINK_TO must be a HUM-* id, got: '$LINK_TO'"; return 1; }
  [[ -z "${SRC_NAMES_FILE:-}" || -r "$SRC_NAMES_FILE" ]] || { do_log "FATAL SRC_NAMES_FILE is not a readable file: '$SRC_NAMES_FILE'"; return 1; }
}

# _spl_tcc_read_source: every source desk box's hub-tail of the topic into
# $work/src.ndjson (duplicates are folded by the plan).
_spl_tcc_read_source() {
  local b d out
  : >"$work/src.ndjson"
  for b in "${src_boxes[@]}"; do
    d="$SPL_STATE_DIR/desk/$src_t/$b"
    out="$(spl_desk_spool "$d" "$b" "$src_t" "$hub" -- hub-tail --task "$topic" --json 2>&1)" ||
      { do_log "FATAL hub-tail $topic on $b in $src_t: $out"; return 1; }
    grep '^{' <<<"$out" >>"$work/src.ndjson"
  done
  return 0
}

# _spl_tcc_names: a JSON object of display names (HUM-* -> name) for the
# headers. SRC_NAMES_FILE wins; else do_spl_hub_member_list of the source
# tenant (read-only). A name that is empty or looks like an e-mail address is
# dropped: the header then shows the id.
_spl_tcc_names() {
  local raw=""
  if [[ -n "${SRC_NAMES_FILE:-}" ]]; then
    raw="$(cat "$SRC_NAMES_FILE")"
  else
    raw="$( (TENANT_ID="$src_t"; unset MATCH; do_spl_hub_member_list) 2>/dev/null)" ||
      do_log "WARN no member list for $src_t: the headers show the HUM-* ids" >&2
  fi
  python3 -c '
import json, sys
raw, names = sys.argv[1], {}
try:
    obj = json.loads(raw)
    if isinstance(obj, dict):
        names = {str(k): str(v) for k, v in obj.items()}
except ValueError:
    for line in raw.splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if isinstance(r, dict) and r.get("type") == "member" and r.get("human_id"):
            names[r["human_id"]] = str(r.get("display_name") or "")
print(json.dumps({k: " ".join(v.split()) for k, v in names.items() if v.strip() and "@" not in v}))
' "$raw"
}

# _spl_tcc_task_id <src tenant> <topic> <dst tenant> <channel> <title> <sel> [tag]:
# the target topic's task id, a uuid5 of them, so every run of one copy lands
# in the same topic (the resume key) and two parts of a split never do; a
# COPY_TAG makes a fresh copy of the same selection (a repair).
_spl_tcc_task_id() {
  python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spl-topic-copy-cross:" + "/".join(sys.argv[1:])))' "$@"
}

# _spl_tcc_wui <tenant>: the WUI base the permalink opens in. DST_WUI_URL
# wins; a tenant the cnf maps (env.dns.mapped_tenants, SPL-959) is its host
# <tenant>.<fqdn>; t1, a self-hosted hub and an unmapped tenant are the apex
# (an unmapped host does not resolve: measured on dev w12live1).
_spl_tcc_wui() {
  local base="${DST_WUI_URL:-}" mapped=1
  if [[ -z "$base" && -r "${SPL_CNF:-}" ]]; then
    grep -qx -- "$1" <<<"$(yq -r '.env.dns.mapped_tenants[]?' "$SPL_CNF" 2>/dev/null)" || mapped=0
  fi
  if [[ -z "$base" ]]; then
    if [[ "$1" == t1 || "${ENV:-}" == self || -z "${SPL_FQDN:-}" || $mapped == 0 ]]; then base="${SPL_WUI_URL:-}"; else base="https://$1.$SPL_FQDN"; fi
    (( mapped )) || do_log "WARN $1 has no tenant host (env.dns.mapped_tenants): the permalink uses the apex; pass DST_WUI_URL to override" >&2
  fi
  printf '%s' "${base%/}"
}

# _spl_tcc_jq <json file> <python expr over d>: one value out of a JSON file.
_spl_tcc_jq() {
  python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

# _spl_tcc_plan <src ndjson> <names json> <src tenant> <topic> <sel> <title>:
# the posts, in order, as a JSON list of {msg_id, from, header, body, files}.
# body is what is sent: the header, a blank line, the original text; the root
# carries the copy marker. msg_id is "" for the title post. files are the blob
# attachments to re-put. A link-back this action posted ("Moved to
# <wui>/t/<uuid> (workspace ...") is not a message: a re-run never copies it.
# Exit 1 (on stderr) on a MSG_IDS entry that matches no message or several.
_spl_tcc_plan() {
  python3 - "$@" <<'EOF_PY'
import json, re, sys
src, names_f, tenant, topic, sel, title = sys.argv[1:]
LINK_BACK = re.compile(r"^Moved to https?://\S+/t/[0-9a-f-]{36} \(workspace ")
names = json.load(open(names_f))
msgs = {}
for line in open(src):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if not isinstance(m, dict) or not m.get("msg_id"):
        continue
    if LINK_BACK.match(str(m.get("body", ""))):
        continue  # this action's own link-back, from an earlier run or part
    msgs[m["msg_id"]] = m
rows = sorted(msgs.values(), key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))
total = len(rows)
if sel.split():
    keep = set()
    for want in sel.split():
        hits = [m["msg_id"] for m in rows if m["msg_id"].startswith(want)]
        if len(hits) != 1:
            print("MSG_IDS entry %s matches %d message(s) of the topic" % (want, len(hits)), file=sys.stderr)
            sys.exit(1)
        keep.add(hits[0])
    rows = [m for m in rows if m["msg_id"] in keep]
marker = "_Copied from workspace %s, topic %s: %d of its %d message(s)._" % (tenant, topic, len(rows), total)
out = []
if title:
    header = "**%s**" % title
    out.append({"msg_id": "", "from": "", "header": header, "body": header + "\n\n" + marker, "files": []})
for m in rows:
    frm = str(m.get("from", ""))
    ts = str(m.get("ts", ""))
    when = ts[:10] + " " + ts[11:16] + " UTC" if len(ts) >= 16 else ts
    header = "**%s** · %s" % (names.get(frm, frm), when)
    atts = m.get("files") or []
    files = [{"file_id": a["file_id"], "name": a.get("name") or a["file_id"]}
             for a in atts if a.get("mode") == "blob" and a.get("file_id")]
    skipped = [a.get("name") or "?" for a in atts if a.get("mode") != "blob"]
    body = header + "\n\n" + str(m.get("body", ""))
    if skipped:
        body += "\n\n_Not copied (a path on the sender's box): %s_" % ", ".join(skipped)
    if not out:
        body += "\n\n---\n" + marker
    out.append({"msg_id": m["msg_id"], "from": frm, "header": header, "body": body, "files": files,
                "head": " ".join(str(m.get("body", "")).split())[:60]})
print(json.dumps(out))
EOF_PY
}

# _spl_tcc_dry_report: what a DRY_RUN=0 would post, one INFO line per post
# (msg id, header, first 60 characters), then the summary JSON line.
_spl_tcc_dry_report() {
  local line
  while IFS= read -r line; do do_log "INFO DRY_RUN would post $line"; done < <(
    python3 -c '
import json, sys
plan = json.load(open(sys.argv[1]))
for i, p in enumerate(plan):
    att = " +%d file(s)" % len(p["files"]) if p["files"] else ""
    print("%d/%d %s %s%s (%s) %s" % (i + 1, len(plan), p["msg_id"][:8] or "title", p["header"], att,
                                    "root" if i == 0 else "reply", p.get("head", "")))
' "$work/plan.json")
  do_log "INFO DRY_RUN target: #$channel in $dst_t as $dst_a on $dst_box, topic $dst_task ($link); then link-back=$link_back archive=$archive in $topic"
  [[ -d "$SPL_STATE_DIR/desk/$dst_t/$dst_box/spool/$dst_a" ]] ||
    do_log "INFO DRY_RUN there is no desk for $dst_a on $dst_box in $dst_t yet: do_spl_desk_up seats one"
  _spl_tcc_summary 0 0 "$dst_task" "$link" 1
  do_log "OK DRY_RUN nothing was sent. Re-run with DRY_RUN=0 to copy."
}

# _spl_tcc_summary <posted> <already> <task> <link> <dry>: the result line.
_spl_tcc_summary() {
  python3 - "$work/plan.json" "$ENV" "$src_t" "$topic" "$dst_t" "$channel" "$title" "$@" <<'EOF_PY'
import json, sys
plan = json.load(open(sys.argv[1]))
env, src, topic, dst, channel, title, posted, have, task, link, dry = sys.argv[2:]
msgs = [p for p in plan if p["msg_id"]]
print(json.dumps({"env": env, "src_tenant": src, "src_topic": topic, "dst_tenant": dst, "dst_channel": channel,
                  "title": title, "messages": len(msgs), "posts": len(plan), "posted": int(posted), "already": int(have),
                  "attachments": sum(len(p["files"]) for p in plan),
                  "first_header": msgs[0]["header"] if msgs else "", "last_header": msgs[-1]["header"] if msgs else "",
                  "dst_topic": task, "permalink": link, "dry_run": dry == "1"}, ensure_ascii=False, sort_keys=True))
EOF_PY
}

# _spl_tcc_resume <dst desk dir> <dst task>: how many posts the target topic
# already holds from this copy (a re-run continues after them). Refuses a
# target whose root lacks the marker, or whose posts do not match the plan's
# headers in order: that is not this copy, and posting into it would mix two.
_spl_tcc_resume() {
  local out
  out="$(spl_desk_spool "$1" "$dst_box" "$dst_t" "$hub" -- hub-tail --task "$2" --json 2>&1)" ||
    { do_log "FATAL hub-tail $2 on $dst_box in $dst_t: $out"; return 1; }
  grep '^{' <<<"$out" >"$work/dst.ndjson"
  python3 - "$work/dst.ndjson" "$work/plan.json" "$dst_a" "$src_t" "$topic" <<'EOF_PY' && return 0
import json, sys
dst, plan_f, agent, tenant, topic = sys.argv[1:]
plan = json.load(open(plan_f))
mine = []
for line in open(dst):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if isinstance(m, dict) and m.get("from") == agent:
        mine.append(m)
mine.sort(key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))
if not mine:
    print(0); sys.exit(0)
if "Copied from workspace %s, topic %s:" % (tenant, topic) not in str(mine[0].get("body", "")):
    print("the target topic's first post carries no copy marker for %s/%s" % (tenant, topic), file=sys.stderr); sys.exit(1)
if len(mine) > len(plan):
    print("the target holds %d posts, the plan only %d" % (len(mine), len(plan)), file=sys.stderr); sys.exit(1)
for i, m in enumerate(mine):
    if not str(m.get("body", "")).startswith(plan[i]["header"] + "\n"):
        print("post %d of the target is not post %d of the plan (%s)" % (i + 1, i + 1, plan[i]["header"]), file=sys.stderr); sys.exit(1)
print(len(mine))
EOF_PY
  do_log "FATAL the target topic $2 in $dst_t is not a resumable copy of $topic"
  return 1
}

# _spl_tcc_post_rest <dst desk dir> <dst task> <already>: post the plan from
# index <already> on, into the caller's posted counter. Stops at the first
# failure: a re-run continues there. Each post waits for a later second than
# the one before: the hub orders a topic by (ts, msg_id) and ts has 1 s
# resolution, so posts sent within one second were shuffled by their random
# msg_id (measured on prd sienna, 2026-10-10: the title landed 3rd of 18).
_spl_tcc_post_rest() {
  local dd="$1" task="$2" i="$3" body sent delivery ids=() last
  last="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while (( i < n )); do
    body="$(_spl_tcc_jq "$work/plan.json" "d[$i]['body']")"
    _spl_tcc_reput "$dd" "$i" || return 1
    _spl_tcc_after "$last"
    sent="$(spl_desk_spool "$dd" "$dst_box" "$dst_t" "$hub" -- send --from "$dst_a" --channel "$channel" \
      --task "$task" --kind note --body "$body" "${ids[@]}" 2>&1)" ||
      { do_log "FATAL post $((i + 1))/$n into #$channel of $dst_t: $sent (re-run: it continues here)"; return 1; }
    delivery="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("delivery",""))' "$sent" 2>/dev/null)"
    [[ "$delivery" == sent ]] ||
      { do_log "FATAL post $((i + 1))/$n was not delivered to the hub ($sent): re-run once the desk sidecar has flushed it"; return 1; }
    last="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("ts",""))' "$sent" 2>/dev/null)"
    [[ -n "$last" ]] || last="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    posted=$((posted + 1)); i=$((i + 1))
  done
}

# _spl_tcc_after <RFC3339 UTC ts>: return once the clock reads a later second.
_spl_tcc_after() {
  while [[ ! "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${1:0:19}Z" ]]; do sleep 0.2; done
}

# _spl_tcc_reput <dst desk dir> <plan index>: fetch each blob attachment of
# post <index> from the source desk and put it again in the target desk, into
# the caller's ids[]: --put-file for a single file (its name is kept), else
# put-file + --file-id each.
_spl_tcc_reput() {
  local dd="$1" idx="$2" sb="${src_boxes[0]}" fid name out put dir rows cnt
  local sd="$SPL_STATE_DIR/desk/$src_t/$sb"
  ids=()
  rows="$(_spl_tcc_jq "$work/plan.json" "'\n'.join(f['file_id'] + '\t' + f['name'] for f in d[$idx]['files'])")"
  [[ -n "$rows" ]] || return 0
  cnt="$(grep -c . <<<"$rows")"
  while IFS=$'\t' read -r fid name; do
    out="$(spl_desk_spool "$sd" "$sb" "$src_t" "$hub" -- hub-get-file --file-id "$fid" 2>&1)" ||
      { do_log "FATAL fetch attachment $name ($fid) from $src_t: $out"; return 1; }
    dir="$work/f/$idx/$fid"; mkdir -p "$dir" || return 1
    name="$(basename -- "$name")"; [[ -n "$name" && "$name" != . && "$name" != .. ]] || name="$fid"
    cp -- "$sd/spool/files/$fid" "$dir/$name" || { do_log "FATAL attachment $fid is not in $sd/spool/files after the fetch"; return 1; }
    if (( cnt == 1 )); then ids+=(--put-file "$dir/$name"); continue; fi
    put="$(spl_desk_spool "$dd" "$dst_box" "$dst_t" "$hub" -- put-file "$dir/$name" 2>&1)" ||
      { do_log "FATAL put-file $name in $dst_t: $put"; return 1; }
    fid="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["file_id"])' "$put" 2>/dev/null)" ||
      { do_log "FATAL put-file $name returned no file_id: $put"; return 1; }
    ids+=(--file-id "$fid")
  done <<<"$rows"
}

# _spl_tcc_link_back <link> <count>: "Moved to <link>" in the source topic,
# through do_spl_desk_reply, unless the source agent already posted it there.
_spl_tcc_link_back() {
  local link="$1" count="$2" to="${LINK_TO:-}" what
  if python3 -c '
import json, sys
for line in open(sys.argv[1]):
    try:
        m = json.loads(line)
    except ValueError:
        continue
    if m.get("from") == sys.argv[2] and sys.argv[3] in str(m.get("body", "")):
        sys.exit(0)
sys.exit(1)' "$work/src.ndjson" "$src_a" "$link"; then
    do_log "INFO the link-back to $link is already in $topic"
    return 0
  fi
  [[ -n "$to" ]] || to="$(python3 -c '
import json, sys
rows = []
for line in open(sys.argv[1]):
    try:
        rows.append(json.loads(line))
    except ValueError:
        pass
rows.sort(key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))
hums = [str(m.get(k, "")) for k in ("from", "to") for m in rows]
print(next((h for h in hums if h.startswith("HUM-")), ""))' "$work/src.ndjson")"
  [[ -n "$to" ]] || { do_log "FATAL the copy is complete ($link) but $topic has no human to address the link-back to: pass LINK_TO=HUM-<n>"; return 1; }
  what="$count message(s) of this topic, in order"
  [[ -n "$title" ]] && what="\"$title\", $what"
  (
    # shellcheck disable=SC2034 # read by do_spl_desk_reply in this subshell
    TENANT_ID="$src_t" DESK_AGENT="$src_a" DESK_BOX="${src_boxes[0]}" DESK_TASK="$topic" DESK_TO="$to" DESK_KIND=note DRY_RUN=0
    # shellcheck disable=SC2034 # read by do_spl_desk_reply in this subshell
    DESK_BODY="Moved to $link (workspace $dst_t, #$channel): $what."
    unset DESK_BODY_FILE DESK_FILES DESK_ACK DESK_ANY
    do_spl_desk_reply >/dev/null
  ) || { do_log "FATAL the copy is complete ($link) but the link-back in $topic failed: re-run, it continues"; return 1; }
}
