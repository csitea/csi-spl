#!/bin/bash
#------------------------------------------------------------------------------
# @description The nightly agy review of the cost labels' machine drafts (spec
# @description 123 section 16.6, row L4; owner HUM-10, csitea 720fa031, msg
# @description e9f8e835 answer 3 "1D", msg baae5fb7 follow-up 1 "A": agy
# @description corrects the API's text every night). Through the ENV hub as the
# @description env's project service account (do_gcp_pin_account, never the
# @description owner account), one run per env at a time (flock):
# @description   1. POST /v1/operator/cost-labels/fill: the hub drafts every
# @description      missing text and hr component (Google Cloud Translation);
# @description   2. GET /v1/operator/cost-labels/unreviewed: the masked texts
# @description      and their masked drafts, at most TRANSLATE_MAX_ITEMS;
# @description   3. ONE agy --print call: per locale "ok" or a corrected text,
# @description      one JSON object (assets/spl-cost-labels-translate/
# @description      prompt.txt and schema.json). An agy failure, a timeout or
# @description      an answer off the schema writes NOTHING (16.6.6);
# @description   4. PUT /v1/operator/cost-labels/reviewed per text: "ok" writes
# @description      the draft as reviewed, a correction writes the correction.
# @description      A locale not asked, empty, over 100 characters with no
# @description      mask token, or with "<span" is refused here; the hub
# @description      checks the rest after its unmask. 409 stale_source drops
# @description      the text until the next run.
# @description Only masked text leaves the hub, so this box never sees a name.
# @description The log and stdout carry counts and reasons only, never a label
# @description and never agy's output. A text that fails 3 runs in a row is
# @description one note to the orchestrator (its key's sha256 prefix, never
# @description the text), then none until it succeeds; agy at its vendor limit
# @description is one note per day. DRY_RUN=1 (default): no fill, no agy call,
# @description no write; it reads the unreviewed list and prints its counts.
# @description TRANSLATE_CMD=measure: the agy schema measurement (row L4's
# @description first step): MEASURE_N agy calls with the SAME prompt and
# @description schema, each on one synthetic text of
# @description assets/.../measure-texts.txt with its English text as the draft
# @description in the 18 other locales; no hub, no write; prints
# @description schema_ok=<k>/<n> n=<n>. It needs a signed-in agy on the box.
# @param ENV (optional) - dev or prd; needed by TRANSLATE_CMD=run (the default)
# @param TRANSLATE_CMD (optional) - run (default) | measure
# @param DRY_RUN (optional) - 1 (default) or 0, run only
# @param TRANSLATE_MAX_ITEMS (optional) - texts per run, default 40; the rest wait for the next run
# @param TRANSLATE_AGY_TIMEOUT_S (optional) - agy's --print-timeout in s, default 600
# @param TRANSLATE_FILL_MAX_TIME (optional) - the fill call's cap in s, default 300
# @param MEASURE_N (optional) - measure: the number of agy calls, default 20
# @param AGY_BIN (optional) - the agy binary, default agy on PATH
# @param TRANSLATE_NOTE_TO (optional) - who gets the notes, default the lease's LEASE_ORCH
# @param TRANSLATE_SEND (optional) - the spool-send script, default the spawn-agents one
# @example ENV=dev ./run -a do_spl_cost_labels_translate
# @example ENV=dev DRY_RUN=0 ./run -a do_spl_cost_labels_translate
# @example TRANSLATE_CMD=measure MEASURE_N=20 ./run -a do_spl_cost_labels_translate
#------------------------------------------------------------------------------
do_spl_cost_labels_translate() {
  do_require_bin jq || return 1
  case "${TRANSLATE_CMD:-run}" in
    measure) _spl_clt_measure; return ;;
    run) ;;
    *) do_log "FATAL TRANSLATE_CMD must be run or measure, got: '${TRANSLATE_CMD:-}'"; return 1 ;;
  esac
  do_require_bin curl gcloud flock sha256sum || return 1
  spl_require_cloud_env || return 1
  local dry=0 rc dir lk
  if spl_dry_run; then dry=1; else rc=$?; (( rc == 1 )) || return 1; fi
  _spl_clt_num TRANSLATE_MAX_ITEMS 40 >/dev/null || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  dir="$SPL_STATE_DIR/cost-labels-translate"
  mkdir -p "$dir" && chmod 700 "$dir" || return 1
  exec {lk}>>"$dir/run.lock"
  if ! flock -n "$lk"; then
    exec {lk}>&-
    do_log "FATAL another cost labels translate run of ENV=$ENV holds its lock: this run does nothing"
    return 1
  fi
  _spl_clt_run "$dir" "$dry" "$lk"; rc=$?
  exec {lk}>&-
  return "$rc"
}

# _spl_clt_assets -> the prompt assets' dir
_spl_clt_assets() {
  printf '%s' "$(dirname "${BASH_SOURCE[0]}")/assets/spl-cost-labels-translate"
}

# _spl_clt_num <NAME> <default> -> the env var NAME as a whole number above
# 0, else its default; FATAL on anything else
_spl_clt_num() {
  local v="${!1:-$2}"
  [[ "$v" =~ ^[1-9][0-9]{0,5}$ ]] || { do_log "FATAL $1 must be a whole number above 0, got: '$v'" >&2; return 1; }
  printf '%s' "$v"
}

# _spl_clt_run <state dir> <dry> <lock fd>: fill, read, one agy call, write
_spl_clt_run() {
  local dir="$1" dry="$2" lk="$3" tmp rc=0 n why
  tmp="$(umask 077 && mktemp -d)" || return 1
  if (( dry )); then
    do_log "INFO DRY_RUN=1: no fill, no agy call, no write in $ENV"
  else
    _spl_clt_fill || rc=3
  fi
  if ! _spl_clt_unreviewed "$tmp/work.json"; then rm -rf "$tmp"; return 1; fi
  n="$(jq '.items | length' "$tmp/work.json")"
  if (( n == 0 || dry )); then
    why=""; (( dry )) && why=" (DRY_RUN=1: nothing sent to agy, nothing written)"
    do_log "OK $ENV cost labels unreviewed: texts=$n locales=$(jq '[.items[].masked_drafts | length] | add // 0' "$tmp/work.json")$why"
    rm -rf "$tmp"; return "$rc"
  fi
  if ! _spl_clt_agy "$tmp/work.json" "$tmp/answer.json" "$tmp" "$lk"; then
    why="$SPL_CLT_WHY"
    _spl_clt_fail_all "$dir" "$tmp/work.json"
    [[ "$why" == vendor_limit ]] && _spl_clt_vendor_note "$dir"
    do_log "FATAL $ENV agy review failed ($why): texts=$n written=0; the drafts stay unreviewed until the next run${SPL_CLT_WHY_AT:-}"
    rm -rf "$tmp"; return 2
  fi
  _spl_clt_write "$tmp/work.json" "$tmp/answer.json" "$dir" || rc=3
  rm -rf "$tmp"
  return "$rc"
}

# _spl_clt_fill: POST the fill; a failure is a WARN (the review still runs)
_spl_clt_fill() {
  local max err
  max="$(_spl_clt_num TRANSLATE_FILL_MAX_TIME 300)" || return 1
  SPL_HUB_OP_MAX_TIME="$max" spl_hub_operator_call POST /v1/operator/cost-labels/fill "" || return 1
  err="$(jq -r '.error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null | grep -xE '[a-z_]{1,40}')"
  if [[ "$SPL_HUB_OP_STATUS" != 200 ]]; then
    do_log "WARN $ENV cost labels fill answered $SPL_HUB_OP_STATUS${err:+ ($err)}: the review still runs"
    return 1
  fi
  do_log "OK $ENV cost labels fill: $(jq -r '[ "texts", "written", "refused", "failed", "capped" ] as $k
    | [ $k[] as $f | "\($f)=\(.[$f] | if type == "number" then . else "?" end)" ] | join(" ")' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"
}

# _spl_clt_unreviewed <out>: the hub's unreviewed items, shape-checked, at
# most TRANSLATE_MAX_ITEMS, as {items: [...]} in out; FATAL else (never the
# body: it holds labels)
_spl_clt_unreviewed() {
  local max err
  max="$(_spl_clt_num TRANSLATE_MAX_ITEMS 40)" || return 1
  spl_hub_operator_call GET /v1/operator/cost-labels/unreviewed "" || return 1
  err="$(jq -r '.error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null | grep -xE '[a-z_]{1,40}')"
  if [[ "$SPL_HUB_OP_STATUS" != 200 ]]; then
    do_log "FATAL $ENV cost labels unreviewed answered $SPL_HUB_OP_STATUS${err:+ ($err)}"
    return 1
  fi
  jq -ce --argjson max "$max" '
    def str: type == "string";
    select(type == "object" and (.items | type == "array")
      and all(.items[]; type == "object" and (.key | str) and (.source_sha | str) and (.masked_text | str)
        and (.masked_drafts | type == "object") and all(.masked_drafts[]; str)))
    | {items: .items[:$max]}' <<<"$SPL_HUB_OP_BODY" >"$1" 2>/dev/null ||
    { do_log "FATAL $ENV the hub's unreviewed answer is not a list of masked labels (it is not printed)"; return 1; }
}

# _spl_clt_slot <text> <slot> <value> -> text with {{slot}} replaced once by
# value, taken literally (no & or pattern meaning, bash 5.2 patsub)
_spl_clt_slot() {
  local s="{{$2}}"
  [[ "$1" == *"$s"* ]] || { printf '%s' "$1"; return 0; }
  printf '%s%s%s' "${1%%"$s"*}" "$3" "${1#*"$s"}"
}

# _spl_clt_prompt <work> -> the prompt: prompt.txt with the schema and the
# work's masked texts and drafts (each with its number i), no key, no sha
_spl_clt_prompt() {
  local a p schema input
  a="$(_spl_clt_assets)"
  p="$(cat "$a/prompt.txt")" && schema="$(jq -c . "$a/schema.json")" || return 1
  input="$(jq -c '{items: [.items | to_entries[] | {i: .key, text: .value.masked_text, drafts: .value.masked_drafts}]}' "$1")" || return 1
  p="$(_spl_clt_slot "$p" SCHEMA "$schema")"
  _spl_clt_slot "$p" INPUT "$input"
}

# _spl_clt_agy <work> <answer out> <tmp> <lock fd or ""> -> 0 and the
# answer's JSON in out when agy answered on the schema; else 1 and
# SPL_CLT_WHY = no_agy | too_large | vendor_limit | timeout | exit_<rc> |
# off_schema (no_agy also sets SPL_CLT_WHY_AT: the user and the PATH
# searched). agy's output is never printed.
_spl_clt_agy() {
  local work="$1" out="$2" tmp="$3" lk="$4" bin="${AGY_BIN:-agy}" t prompt rc
  SPL_CLT_WHY="" SPL_CLT_WHY_AT=""
  t="$(_spl_clt_num TRANSLATE_AGY_TIMEOUT_S 600)" || { SPL_CLT_WHY=bad_timeout; return 1; }
  command -v "$bin" >/dev/null 2>&1 || { SPL_CLT_WHY=no_agy; SPL_CLT_WHY_AT="; '$bin' not found as user $(id -un) on PATH=$PATH"; return 1; }
  prompt="$(_spl_clt_prompt "$work")" || { SPL_CLT_WHY=no_prompt; return 1; }
  (( ${#prompt} <= 120000 )) || { SPL_CLT_WHY=too_large; return 1; }
  mkdir -p "$tmp/agy-wd" || return 1
  (
    [[ -n "$lk" ]] && exec {lk}>&-
    cd "$tmp/agy-wd" && timeout -k 10 "$((t + 30))" "$bin" -p "$prompt" --print-timeout "${t}s" \
      </dev/null >"$tmp/agy.out" 2>"$tmp/agy.err"
  )
  rc=$?
  if (( rc != 0 )); then
    if grep -qiE 'weekly limit|quota|resource_exhausted|rate.?limit' "$tmp/agy.out" "$tmp/agy.err" 2>/dev/null; then
      SPL_CLT_WHY=vendor_limit
    elif (( rc == 124 )); then SPL_CLT_WHY=timeout
    else SPL_CLT_WHY="exit_$rc"; fi
    return 1
  fi
  if ! _spl_clt_extract "$tmp/agy.out" >"$out" || ! _spl_clt_valid "$work" "$out"; then
    SPL_CLT_WHY=off_schema; return 1
  fi
}

# _spl_clt_extract <file> -> the one JSON object agy printed: the whole
# output, else the span from its first { to its last }; 1 when neither
_spl_clt_extract() {
  local s pre
  s="$(cat "$1")"
  jq -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else error end' <<<"$s" 2>/dev/null && return 0
  pre="${s%%\{*}"
  [[ "$pre" != "$s" ]] || return 1
  s="${s:${#pre}}"
  [[ "$s" == *"}"* ]] || return 1
  s="${s%\}*}}"
  jq -cse 'if length == 1 and (.[0] | type) == "object" then .[0] else error end' <<<"$s" 2>/dev/null
}

# _spl_clt_valid <work> <answer> -> 0 when the answer keeps schema.json's
# shape: {items: [{i, labels: {locale: string}}]} and nothing else, each i a
# distinct item number of work, each locale one asked for that item
_spl_clt_valid() {
  jq -e --slurpfile w "$1" '
    ($w[0].items) as $work
    | type == "object" and (keys == ["items"]) and (.items | type == "array")
      and ([.items[] | .i?] | length == (unique | length))
      and all(.items[]; type == "object" and (keys == ["i", "labels"])
        and (.i | type == "number" and . == floor and . >= 0 and . < ($work | length))
        and (.labels | type == "object")
        and (. as $a | all(.labels | to_entries[]; (.value | type == "string")
          and (.key as $l | $work[$a.i].masked_drafts | has($l)))))' "$2" >/dev/null 2>&1
}

# _spl_clt_labels <work> <answer> <i> -> {labels, refused} of item i: "ok"
# takes the draft; a text that is empty, over 100 characters with no mask
# token, or holds "<span" is refused here (the hub checks the rest after
# its unmask); null when agy did not answer item i
_spl_clt_labels() {
  jq -c --slurpfile w "$1" --argjson i "$3" '
    ($w[0].items[$i].masked_drafts) as $d
    | (first(.items[] | select(.i == $i)) // null) as $a
    | if $a == null then null else
      [$a.labels | to_entries[] | .value = (if .value == "ok" then $d[.key] else .value end)
        | .bad = ((.value | gsub("\\s"; "") == "") or (.value | contains("<span"))
          or ((.value | length) > 100 and (.value | test("\\[(EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\\]") | not)))]
      | {labels: (map(select(.bad | not) | {key, value}) | from_entries), refused: (map(select(.bad)) | length)} end' "$2"
}

# _spl_clt_write <work> <answer> <state dir>: one PUT per answered text;
# the counts line; 1 when a PUT failed
_spl_clt_write() {
  local work="$1" ans="$2" dir="$3" n i one body key w=0 r=0 s=0 f=0 u=0 a=0 wn rn
  n="$(jq '.items | length' "$work")"
  for ((i = 0; i < n; i++)); do
    one="$(_spl_clt_labels "$work" "$ans" "$i")" || one=null
    key="$(jq -r --argjson i "$i" '.items[$i].key' "$work")"
    [[ "$one" == null ]] && { u=$((u + 1)); continue; }
    a=$((a + 1)); r=$((r + $(jq '.refused' <<<"$one")))
    if [[ "$(jq '.labels | length' <<<"$one")" == 0 ]]; then _spl_clt_fail "$dir" "$key"; continue; fi
    body="$(jq -c --slurpfile w "$work" --argjson i "$i" '{key: $w[0].items[$i].key, source_sha: $w[0].items[$i].source_sha, labels}' <<<"$one")"
    if ! spl_hub_operator_call PUT /v1/operator/cost-labels/reviewed "$body"; then f=$((f + 1)); _spl_clt_fail "$dir" "$key"; continue; fi
    case "$SPL_HUB_OP_STATUS" in
      200)
        wn="$(jq '.written | if type == "number" then . else 0 end' <<<"$SPL_HUB_OP_BODY" 2>/dev/null || echo 0)"
        rn="$(jq '.refused | if type == "object" then length else 0 end' <<<"$SPL_HUB_OP_BODY" 2>/dev/null || echo 0)"
        w=$((w + wn)); r=$((r + rn))
        if (( wn > 0 )); then _spl_clt_ok "$dir" "$key"; else _spl_clt_fail "$dir" "$key"; fi ;;
      409) s=$((s + 1)) ;;
      *) f=$((f + 1)); _spl_clt_fail "$dir" "$key"
         do_log "WARN $ENV reviewed PUT of text $(_spl_clt_prefix "$key") answered $SPL_HUB_OP_STATUS" ;;
    esac
  done
  do_log "OK $ENV cost labels reviewed: texts=$n answered=$a unanswered=$u locales_written=$w locales_refused=$r stale=$s failed=$f"
  (( f == 0 ))
}

# _spl_clt_prefix <key> -> the key's sha256, first 12 hex: the only name of a
# text that reaches a log or a note
_spl_clt_prefix() {
  printf '%s' "$1" | sha256sum | cut -c1-12
}

# _spl_clt_ok <dir> <key>: the text succeeded, its failure count goes
_spl_clt_ok() {
  local f="$1/fails.tsv" p
  p="$(_spl_clt_prefix "$2")"
  [[ -f "$f" ]] || return 0
  awk -v p="$p" '$1 != p' "$f" >"$f.tmp" && mv -f "$f.tmp" "$f"
}

# _spl_clt_fail <dir> <key>: one more failed run for the text; at 3 in a
# row, one note to the orchestrator (the prefix and the count only), then
# none until it succeeds
_spl_clt_fail() {
  local f="$1/fails.tsv" p c noted
  p="$(_spl_clt_prefix "$2")"
  touch "$f"
  read -r c noted < <(awk -v p="$p" '$1 == p { print $2, $3 }' "$f")
  c=$(( ${c:-0} + 1 )); noted="${noted:-0}"
  if (( c >= 3 )) && [[ "$noted" == 0 ]]; then
    _spl_clt_note "do_spl_cost_labels_translate ENV=$ENV: cost label text $p (sha256 prefix of its key) failed its agy review $c runs in a row; its drafts stay unreviewed. No other note for it until it succeeds."
    noted=1
  fi
  { awk -v p="$p" '$1 != p' "$f"; printf '%s\t%s\t%s\n' "$p" "$c" "$noted"; } >"$f.tmp" && mv -f "$f.tmp" "$f"
}

# _spl_clt_fail_all <dir> <work>: one more failed run for every text of work
_spl_clt_fail_all() {
  local key
  while IFS= read -r key; do _spl_clt_fail "$1" "$key"; done < <(jq -r '.items[].key' "$2")
}

# _spl_clt_vendor_note <dir>: agy at its vendor limit, one note per UTC day
_spl_clt_vendor_note() {
  local f="$1/vendor-limit.day" today
  today="$(date -u +%F)"
  [[ "$(cat "$f" 2>/dev/null)" == "$today" ]] && return 0
  _spl_clt_note "do_spl_cost_labels_translate ENV=$ENV: agy answered at its vendor limit; tonight's drafts stay unreviewed. One note per day."
  printf '%s\n' "$today" >"$f"
}

# _spl_clt_note <body>: one spool note to the orchestrator; never fails
# the run
_spl_clt_note() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" to
  to="${TRANSLATE_NOTE_TO:-$(sed -n 's/^LEASE_ORCH=\([A-Za-z0-9_-]*\)$/\1/p' "$root/dispatch/lease.conf" 2>/dev/null | sed -n 1p)}"
  [[ -n "$to" ]] || { do_log "WARN no orchestrator to tell (no LEASE_ORCH): $1"; return 0; }
  SPOOL_ROOT="$root" bash "${TRANSLATE_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}" \
    --from "$to" --to "$to" --kind note --task cost-labels-translate --no-ask --body "$1" >/dev/null 2>&1 7>&- 8>&- 9>&- ||
    do_log "WARN the note to $to could not be sent"
  return 0
}

# _spl_clt_measure: the agy schema measurement, MEASURE_N calls with the
# write path's own prompt, schema and checks; no hub, no write
_spl_clt_measure() {
  local n a locs tmp i t ok=0 why
  local -a texts=()
  n="$(_spl_clt_num MEASURE_N 20)" || return 1
  a="$(_spl_clt_assets)"
  locs="$(_spl_clt_locales)" || return 1
  tmp="$(umask 077 && mktemp -d)" || return 1
  mapfile -t texts <"$a/measure-texts.txt"
  for ((i = 0; i < n; i++)); do
    t="${texts[i % ${#texts[@]}]}"
    jq -cn --arg t "$t" --argjson l "$locs" --arg k "measure-$i" \
      '{items: [{key: $k, source_sha: "-", masked_text: $t, masked_drafts: ($l | map({key: ., value: $t}) | from_entries)}]}' >"$tmp/work.json"
    rm -f "$tmp/answer.json" "$tmp/agy.out" "$tmp/agy.err"
    if _spl_clt_agy "$tmp/work.json" "$tmp/answer.json" "$tmp" ""; then ok=$((ok + 1)); why=ok; else why="$SPL_CLT_WHY"; fi
    do_log "INFO measure call $((i + 1))/$n: $why"
  done
  rm -rf "$tmp"
  echo "schema_ok=$ok/$n n=$n"
}

# _spl_clt_locales -> the WUI's locales but en, as a JSON array
_spl_clt_locales() {
  local d="${TRANSLATE_LOCALES_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../../../csi-spl-wui/i18n/locales}" f
  local -a l=()
  for f in "$d"/*.json; do [[ -f "$f" ]] && l+=("$(basename "$f" .json)"); done
  (( ${#l[@]} > 1 )) || { do_log "FATAL no locales under $d"; return 1; }
  printf '%s\n' "${l[@]}" | grep -vx en | jq -Rsc 'split("\n") | map(select(. != ""))'
}
