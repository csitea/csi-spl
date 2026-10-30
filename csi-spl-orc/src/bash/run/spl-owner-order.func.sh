#!/bin/bash
#------------------------------------------------------------------------------
# @description The owner-order ledger (spec 168, B1; owner HUM-10 poll
# @description 10af03a3 answer A): an explicit owner order, word for word,
# @description with the repo and the paths it covers. One append-only JSON
# @description lines file per repo under $SPOOL_ROOT/owner-orders, never in
# @description git (a customer repo's order quotes the customer). ORDER_CMD:
# @description add (one order; ORDER_FROM_HUB=<env> reads the owner's message
# @description from the hub and refuses a text that is not part of it), list,
# @description lift (only on the owner's own lifting message, read from the
# @description hub for a gating order), match (the active orders covering any
# @description of the paths). add and lift are a dry run unless DRY_RUN=0.
# @description The order TEXT never goes to stdout (./run copies stdout to its
# @description log): list and match print id, state, gate and paths, and write
# @description the full orders as JSON lines to ORDER_OUT when it is set.
# @description Exit codes (spec 168 3.5): 0 done / nothing covered, 3 covered
# @description (match) or already there, 2 the ledger is unreadable or
# @description malformed, 1 refused input. The spawn copy-in and the gate
# @description treat every code but 0 and 3 as REFUSE (fail closed).
# @param ORDER_CMD (required) - add | list | lift | match
# @param ORDER_REPO (add, lift, match; or ORDER_REPO_DIR) - the repo key: the basename of the directory that holds the repo's git common dir, e.g. csi-spl for every worktree of csi-spl
# @param ORDER_REPO_DIR (optional) - a checkout or worktree of the repo; its key is derived as above, never from the worktree's own dir name
# @param ORDER_MSG (add) - the owner's message id, the full uuid
# @param ORDER_PATHS (add, match) - comma-separated repo-relative paths; for add, globs (* one segment, ** any depth, ? one char)
# @param ORDER_PATHS_FILE (optional, add, match) - the same, one per line (a path may hold a comma)
# @param ORDER_TEXT / ORDER_TEXT_FILE (add) - the order word for word; with ORDER_FROM_HUB it may be left out (the whole body) or be a contiguous part of it
# @param ORDER_FROM_HUB (optional for add; required to lift a go or content order) - dev | prd: read the message from that hub (read-only do_spl_db_query); unset = source "given"
# @param ORDER_OWNER ORDER_TS ORDER_TOPIC (add, without ORDER_FROM_HUB) - HUM-<n>, ISO UTC send time, topic uuid (optional)
# @param ORDER_GATE (optional, add) - go (default: any uncited change refused) | content (a pure rename passes, a content change needs the go) | none
# @param ORDER_EXPIRES ORDER_NOTE (optional, add) - ISO UTC end of the order; the writer's one line
# @param ORDER_ID ORDER_LIFT_MSG ORDER_REASON (lift) - the order (8+ hex digits of its id), the owner's lifting message uuid, why
# @param ORDER_ALL (optional, list) - 1: lifted and expired too
# @param ORDER_OUT (optional, list, match) - a file to append the full orders (text included) to as JSON lines, mode 600; keep it outside OWNER_ORDER_DIR (list reads every *.jsonl there)
# @param AGENT_ID (required for add, lift) - the writer
# @param OWNER_ORDER_DIR (optional) - default $SPOOL_ROOT/owner-orders
# @param DRY_RUN (optional) - default 1
# @example ORDER_CMD=list ./run -a do_spl_owner_order
# @example ORDER_CMD=add ORDER_REPO=csi-spl ORDER_MSG=<uuid> ORDER_FROM_HUB=prd ORDER_PATHS='csi-spl-doc/doc/md/**' ORDER_GATE=content AGENT_ID=c-001 DRY_RUN=0 ./run -a do_spl_owner_order
# @example ORDER_CMD=match ORDER_REPO_DIR="$PWD" ORDER_PATHS=csi-spl-doc/doc/md/a.md ORDER_OUT="$(mktemp)" ./run -a do_spl_owner_order
# @example ORDER_CMD=lift ORDER_REPO=csi-spl ORDER_ID=6f9ae3ad ORDER_LIFT_MSG=<uuid> ORDER_FROM_HUB=prd ORDER_REASON='owner lifted it' AGENT_ID=c-001 DRY_RUN=0 ./run -a do_spl_owner_order
#------------------------------------------------------------------------------
SPL_OO_UUID_RX='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
SPL_OO_ISO_RX='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# A path glob as an anchored regex: * one segment, ** any depth, ? one char.
# shellcheck disable=SC2016
SPL_OO_G2R='def g2r: "^" + (gsub("(?<c>[.+^$()|\\[\\]{}\\\\])"; "\\\(.c)")
    | gsub("\\*\\*/"; "\u0001") | gsub("\\*\\*"; "\u0002") | gsub("\\*"; "[^/]*")
    | gsub("\\?"; "[^/]") | gsub("\u0001"; "(.*/)?") | gsub("\u0002"; ".*")) + "$";'
# The fold: one object per order, its add plus lift and the state (active,
# lifted, expired) at ORDER_NOW. Input: the event lines, slurped.
# shellcheck disable=SC2016
SPL_OO_FOLD='(map(select(.op == "lift")) | map({key: .order, value: .}) | from_entries) as $lifts
  | map(select(.op == "add")) | map(. as $a | $a + {
      lift: ($lifts[$a.order] // null),
      state: (if $lifts[$a.order] then "lifted"
              elif (($a.expires // "") != "" and $a.expires <= $now) then "expired"
              else "active" end)})'

do_spl_owner_order() {
  local cmd="${ORDER_CMD:-}" dir="${OWNER_ORDER_DIR:-${SPOOL_ROOT:-/var/spool-hub}/owner-orders}"
  do_require_bin jq || return 1
  case "$cmd" in
    add) _spl_oo_add "$dir" ;;
    list) _spl_oo_list "$dir" ;;
    lift) _spl_oo_lift "$dir" ;;
    match) _spl_oo_match "$dir" ;;
    *) do_log "FATAL ORDER_CMD must be add, list, lift or match (got '$cmd')"; return 1 ;;
  esac
}

# _spl_oo_repo: prints the checked repo key: ORDER_REPO, else the basename
# of the parent of ORDER_REPO_DIR's git common dir (a worktree gives its
# main repo's name, not its own dir name)
_spl_oo_repo() {
  local r="${ORDER_REPO:-}" cd
  if [[ -z "$r" && -n "${ORDER_REPO_DIR:-}" ]]; then
    cd="$(git -C "$ORDER_REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
      { do_log "FATAL ORDER_REPO_DIR $ORDER_REPO_DIR is not a git checkout" >&2; return 1; }
    r="$(basename "$(dirname "$cd")")"
  fi
  [[ "$r" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { do_log "FATAL ORDER_REPO must be a repo key (got '$r')" >&2; return 1; }
  printf '%s' "$r"
}

# _spl_oo_paths: ORDER_PATHS_FILE (one per line) or ORDER_PATHS (comma-
# separated), one path per line; refuses absolute, .., empty, control chars
_spl_oo_paths() {
  local p; local -a ps=()
  if [[ -n "${ORDER_PATHS_FILE:-}" ]]; then
    [[ -r "$ORDER_PATHS_FILE" ]] || { do_log "FATAL ORDER_PATHS_FILE $ORDER_PATHS_FILE is not readable" >&2; return 1; }
    mapfile -t ps <"$ORDER_PATHS_FILE"
  else
    IFS=',' read -r -a ps <<<"${ORDER_PATHS:-}"
  fi
  ((${#ps[@]} > 0)) || { do_log "FATAL ORDER_PATHS is required" >&2; return 1; }
  for p in "${ps[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [[ -n "$p" && "$p" != /* && ! "$p" =~ (^|/)\.\.(/|$) && ! "$p" =~ [[:cntrl:]] ]] ||
      { do_log "FATAL ORDER_PATHS: '$p' is not a repo-relative path" >&2; return 1; }
    printf '%s\n' "$p"
  done
}

# _spl_oo_fold <file>: the folded orders, one JSON array. No file = [];
# an unreadable or malformed ledger is rc 2, never an empty answer (fail
# closed: a reader must not take a broken ledger for "no order").
_spl_oo_fold() {
  local now="${ORDER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" out
  [[ -e "$1" ]] || { echo '[]'; return 0; }
  [[ -r "$1" ]] || { do_log "FATAL the ledger $1 is not readable" >&2; return 2; }
  out="$(jq -s -c --arg now "$now" "$SPL_OO_FOLD" "$1" 2>&1)" || { do_log "FATAL the ledger $1 is malformed: ${out:0:200}" >&2; return 2; }
  printf '%s\n' "$out"
}

# _spl_oo_show <json lines>: one line per order on stdout, no text (./run
# logs stdout); the full lines are appended to ORDER_OUT when it is set
_spl_oo_show() {
  [[ -n "$1" ]] || return 0
  jq -r '"\(.order) \(.repo) \(.state) gate=\(.gate) source=\(.source) owner=\(.owner) ts=\(.ts) paths=\(.paths | join(","))"' <<<"$1"
  [[ -z "${ORDER_OUT:-}" ]] && return 0
  (umask 077; printf '%s\n' "$1" >>"$ORDER_OUT") || { do_log "FATAL could not write ORDER_OUT $ORDER_OUT"; return 1; }
}

_spl_oo_append() {  # <dir> <repo> <json line>
  local f="$1/$2.jsonl"
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would append to $f: $(jq -c 'del(.text)' <<<"$3")"
    return 0
  fi
  mkdir -p "$1" && chmod 2770 "$1" 2>/dev/null
  { flock 9 && printf '%s\n' "$3" >>"$f"; } 9>"$1/.lock" || { do_log "FATAL could not write $f"; return 1; }
  chmod 660 "$f" 2>/dev/null
  return 0
}

# _spl_oo_hub <env> <msg uuid>: "<from>\t<task>\t<ts>\t<base64 body>" of the
# hub's message, read-only. One row or nothing.
_spl_oo_hub() {
  local sql out
  sql="select 'OO|' || from_id || '|' || task_id || '|' || to_char(ts at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') || '|' || translate(encode(convert_to(body, 'UTF8'), 'base64'), chr(10), '') as r from messages where msg_id = '$2'"
  out="$(ENV="$1" SQL="$sql" do_spl_db_query 2>&1)" || { do_log "FATAL the $1 hub read failed: $(tail -1 <<<"$out")" >&2; return 1; }
  grep -m1 -oE 'OO\|[^| ]+\|[^| ]+\|[^| ]+\|[A-Za-z0-9+/=]*' <<<"$out" | sed -n 1p | cut -d'|' -f2- | tr '|' '\t' || true
}

# _spl_oo_text: ORDER_TEXT, else the file ORDER_TEXT_FILE, else empty
_spl_oo_text() {
  if [[ -n "${ORDER_TEXT:-}" ]]; then printf '%s' "$ORDER_TEXT"
  elif [[ -n "${ORDER_TEXT_FILE:-}" ]]; then
    [[ -r "$ORDER_TEXT_FILE" ]] || { do_log "FATAL ORDER_TEXT_FILE $ORDER_TEXT_FILE is not readable" >&2; return 1; }
    cat "$ORDER_TEXT_FILE"
  fi
}

# _spl_oo_source <msg>: sets OO_OWNER OO_TS OO_TOPIC OO_TEXT OO_SOURCE from
# the hub (ORDER_FROM_HUB) or from the ORDER_* given
_spl_oo_source() {
  local given row body
  given="$(_spl_oo_text)" || return 1
  if [[ -z "${ORDER_FROM_HUB:-}" ]]; then
    OO_SOURCE=given OO_OWNER="${ORDER_OWNER:-}" OO_TS="${ORDER_TS:-}" OO_TOPIC="${ORDER_TOPIC:-}" OO_TEXT="$given"
    [[ -n "$OO_TEXT" ]] || { do_log "FATAL ORDER_TEXT (or ORDER_TEXT_FILE, or ORDER_FROM_HUB) is required: the order word for word"; return 1; }
    [[ "$OO_TS" =~ $SPL_OO_ISO_RX ]] || { do_log "FATAL ORDER_TS must be the owner's send time, YYYY-MM-DDTHH:MM:SSZ (got '$OO_TS')"; return 1; }
    [[ -z "$OO_TOPIC" || "$OO_TOPIC" =~ $SPL_OO_UUID_RX ]] || { do_log "FATAL ORDER_TOPIC must be a topic uuid (got '$OO_TOPIC')"; return 1; }
  else
    [[ "$ORDER_FROM_HUB" =~ ^(dev|prd)$ ]] || { do_log "FATAL ORDER_FROM_HUB must be dev or prd"; return 1; }
    row="$(_spl_oo_hub "$ORDER_FROM_HUB" "$1")" || return 1
    [[ -n "$row" ]] || { do_log "FATAL message $1 is not on the $ORDER_FROM_HUB hub"; return 1; }
    IFS=$'\t' read -r OO_OWNER OO_TOPIC OO_TS body <<<"$row"
    OO_TEXT="$(base64 -d <<<"$body")" || { do_log "FATAL the hub body of $1 did not decode"; return 1; }
    OO_SOURCE=hub
    if [[ -n "$given" ]]; then
      [[ "$OO_TEXT" == *"$given"* ]] || { do_log "FATAL ORDER_TEXT is not word for word part of message $1 on the $ORDER_FROM_HUB hub: never paraphrase an order"; return 1; }
      OO_TEXT="$given"
    fi
  fi
  [[ "$OO_OWNER" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL message $1 is from '$OO_OWNER', not an owner (HUM-<n>): only the owner gives an order"; return 1; }
}

_spl_oo_add() {
  local dir="$1" repo msg="${ORDER_MSG:-}" gate="${ORDER_GATE:-go}" exp="${ORDER_EXPIRES:-}" by="${AGENT_ID:-}" paths line cur all
  local OO_OWNER OO_TS OO_TOPIC OO_TEXT OO_SOURCE
  repo="$(_spl_oo_repo)" || return 1
  [[ "$msg" =~ $SPL_OO_UUID_RX ]] || { do_log "FATAL ORDER_MSG must be the owner's full message uuid (got '$msg')"; return 1; }
  [[ "$gate" =~ ^(go|content|none)$ ]] || { do_log "FATAL ORDER_GATE must be go, content or none"; return 1; }
  [[ -z "$exp" || "$exp" =~ $SPL_OO_ISO_RX ]] || { do_log "FATAL ORDER_EXPIRES must be YYYY-MM-DDTHH:MM:SSZ"; return 1; }
  [[ -n "$by" ]] || { do_log "FATAL AGENT_ID is required: who writes the order"; return 1; }
  paths="$(_spl_oo_paths | jq -R . | jq -s -c .)" || return 1
  [[ "$paths" != '[]' ]] || { do_log "FATAL ORDER_PATHS is required"; return 1; }
  all="$(_spl_oo_fold "$dir/$repo.jsonl")" || return 2
  _spl_oo_source "$msg" || return 1
  line="$(jq -n -c --arg o "$msg" --arg r "$repo" --argjson p "$paths" --arg t "$OO_TEXT" --arg s "$OO_SOURCE" \
    --arg g "$gate" --arg ts "$OO_TS" --arg w "$OO_OWNER" --arg tp "$OO_TOPIC" --arg e "$exp" --arg n "${ORDER_NOTE:-}" \
    --arg b "$by" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{op: "add", order: $o, repo: $r, paths: $p, text: $t, source: $s, gate: $g, ts: $ts, owner: $w, topic: $tp, expires: $e, note: $n, by: $b, at: $at}')"
  cur="$(jq -c --arg o "$msg" '.[] | select(.order == $o)' <<<"$all")"
  if [[ -n "$cur" ]]; then
    if jq -e -n --argjson a "$cur" --argjson b "$line" '[$a.text, $a.paths, $a.gate] == [$b.text, $b.paths, $b.gate]' >/dev/null; then
      do_log "OK order ${msg:0:8} is already in the $repo ledger ($(jq -r .state <<<"$cur")), nothing written"
      return 0
    fi
    do_log "WARN order ${msg:0:8} is already in the $repo ledger with another text, paths or gate; an order is written once (lift it on the owner's word and add his new message)"
    return 3
  fi
  _spl_oo_append "$dir" "$repo" "$line" || return 1
  [[ "${DRY_RUN:-1}" != 0 ]] || do_log "OK order ${msg:0:8} added to the $repo ledger (source $OO_SOURCE, gate $gate, paths $(jq -r 'join(",")' <<<"$paths"))"
}

_spl_oo_lift() {
  local dir="$1" repo id="${ORDER_ID:-}" lmsg="${ORDER_LIFT_MSG:-}" why="${ORDER_REASON:-}" by="${AGENT_ID:-}" all hits n cur line src
  repo="$(_spl_oo_repo)" || return 1
  [[ "$id" =~ ^[0-9a-f]{8}[0-9a-f-]*$ ]] || { do_log "FATAL ORDER_ID must be the order's id, 8 or more hex digits"; return 1; }
  [[ "$lmsg" =~ $SPL_OO_UUID_RX ]] || { do_log "FATAL ORDER_LIFT_MSG must be the owner's lifting message uuid: only the owner lifts an order"; return 1; }
  [[ -n "$why" ]] || { do_log "FATAL ORDER_REASON is required"; return 1; }
  [[ -n "$by" ]] || { do_log "FATAL AGENT_ID is required"; return 1; }
  all="$(_spl_oo_fold "$dir/$repo.jsonl")" || return 2
  hits="$(jq -c --arg i "$id" '[.[] | select(.order | startswith($i))]' <<<"$all")"
  n="$(jq length <<<"$hits")"
  [[ "$n" == 1 ]] || { do_log "FATAL ORDER_ID $id matches $n orders in the $repo ledger (want 1)"; return 1; }
  cur="$(jq -c '.[0]' <<<"$hits")"
  [[ "$(jq -r .state <<<"$cur")" != lifted ]] || { do_log "WARN order ${id:0:8} is already lifted ($(jq -r '.lift.reason' <<<"$cur"))"; return 3; }
  src="$(_spl_oo_lift_source "$lmsg" "$(jq -r .gate <<<"$cur")")" || return 1
  line="$(jq -n -c --arg o "$(jq -r .order <<<"$cur")" --arg l "$lmsg" --arg r "$why" --arg s "$src" --arg b "$by" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{op: "lift", order: $o, lift_msg: $l, source: $s, reason: $r, by: $b, at: $at}')"
  _spl_oo_append "$dir" "$repo" "$line" || return 1
  [[ "${DRY_RUN:-1}" != 0 ]] || do_log "OK order ${id:0:8} lifted in the $repo ledger on ${lmsg:0:8} (source $src)"
}

# _spl_oo_lift_source <lift msg> <gate>: prints hub or given. Only the owner
# lifts: with ORDER_FROM_HUB the lifting message must be an owner's, and a
# go or content order is never lifted without that check.
_spl_oo_lift_source() {
  local row from
  if [[ -z "${ORDER_FROM_HUB:-}" ]]; then
    [[ "$2" == none ]] || { do_log "FATAL the order's gate is $2: its lift needs ORDER_FROM_HUB, so the hub proves the owner sent $1" >&2; return 1; }
    echo given; return 0
  fi
  [[ "$ORDER_FROM_HUB" =~ ^(dev|prd)$ ]] || { do_log "FATAL ORDER_FROM_HUB must be dev or prd" >&2; return 1; }
  row="$(_spl_oo_hub "$ORDER_FROM_HUB" "$1")" || return 1
  [[ -n "$row" ]] || { do_log "FATAL lifting message $1 is not on the $ORDER_FROM_HUB hub" >&2; return 1; }
  from="${row%%$'\t'*}"
  [[ "$from" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL lifting message $1 is from '$from', not an owner (HUM-<n>): only the owner lifts an order" >&2; return 1; }
  echo hub
}

_spl_oo_list() {
  local dir="$1" f all sel='.[] | select(.state == "active")' rc=0
  [[ "${ORDER_ALL:-0}" == 1 ]] && sel='.[]'
  for f in "$dir"/*.jsonl; do
    [[ -f "$f" ]] || continue
    [[ -z "${ORDER_REPO:-}" || "$(basename "$f" .jsonl)" == "$ORDER_REPO" ]] || continue
    all="$(_spl_oo_fold "$f")" || { rc=2; continue; }
    _spl_oo_show "$(jq -c "$sel" <<<"$all")" || return 1
  done
  return "$rc"
}

_spl_oo_match() {
  local dir="$1" repo paths all out
  repo="$(_spl_oo_repo)" || return 1
  paths="$(_spl_oo_paths | jq -R . | jq -s -c .)" || return 1
  all="$(_spl_oo_fold "$dir/$repo.jsonl")" || return 2
  out="$(jq -c --argjson ps "$paths" "$SPL_OO_G2R"'.[] | select(.state == "active")
    | . as $o | select(any($o.paths[]; g2r as $rx | any($ps[]; test($rx))))' <<<"$all")" ||
    { do_log "FATAL match failed on the $repo ledger"; return 2; }
  [[ -n "$out" ]] || return 0
  _spl_oo_show "$out" || return 1
  return 3
}
