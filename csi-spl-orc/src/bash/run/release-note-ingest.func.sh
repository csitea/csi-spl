#!/bin/bash
#------------------------------------------------------------------------------
# @description The deploy-time release-note ingest (spec 065 L5): read the
# @description newest trunk commits and POST them to the hub's
# @description /v1/operator/release-notes, the rows the release notes modal
# @description (the version pop-up's "Release notes") lists. Without this
# @description step the table stays empty and the modal shows nothing.
# @description Per commit it sends the sha, the commit date, the full message
# @description (the hub parses subject, kind, scope and the Lay-* / Tech-*
# @description trailers), a refs/notes/release-notes note when one exists
# @description (spec 6.1, it wins over the message), doc_only when every path
# @description is a .md (spec 5.2) and the area when one top-level dir is
# @description touched. The version is the FIRST v-tag that contains the
# @description commit (trunk is linear: the lowest version tagged at or
# @description after it on the first-parent line); a commit no tag carries
# @description yet goes without one and gains it on a later ingest (the hub
# @description keeps the first version it is given). Idempotent: the hub
# @description upserts by sha, so every deploy re-sends its window.
# @description A missing note never fails it (the row is state=missing); a
# @description row the hub rejects is a WARN; only no HTTP 200 is FATAL.
# @description Authenticated as the env's project service account (operator
# @description id token, spl_hub_operator_call), never the owner account.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): print the request bodies, call nothing; 0: POST them
# @param RELEASE_SHA (optional) - the newest commit to send, default HEAD
# @param RELEASE_NOTE_DEPTH (optional) - how many first-parent commits back, default 500
# @param RELEASE_NOTE_BATCH (optional) - rows per request, default 100 (hub max 500)
# @param RELEASE_REMOTE (optional) - the remote holding the tags and notes, default origin
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev DRY_RUN=0 ./run -a do_release_note_ingest
# @example ENV=prd RELEASE_SHA=9f175b2e RELEASE_NOTE_DEPTH=50 ./run -a do_release_note_ingest
#------------------------------------------------------------------------------
do_release_note_ingest() {
  do_require_bin git jq || return 1
  spl_require_cloud_env || return 1
  local tip="${RELEASE_SHA:-HEAD}" depth="${RELEASE_NOTE_DEPTH:-500}" batch="${RELEASE_NOTE_BATCH:-100}"
  local remote="${RELEASE_REMOTE:-origin}" dry="${DRY_RUN:-1}" g=(git -C "$APP_PATH")
  [[ "$depth" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL RELEASE_NOTE_DEPTH must be 1..99999, got: '$depth'"; return 1; }
  [[ "$batch" =~ ^[1-9][0-9]{0,2}$ ]] && ((batch <= 500)) || { do_log "FATAL RELEASE_NOTE_BATCH must be 1..500, got: '$batch'"; return 1; }

  "${g[@]}" fetch -q --force "$remote" '+refs/tags/v*:refs/tags/v*' 2>/dev/null ||
    do_log "WARN cannot fetch the v-tags from $remote: versions below come from the local tags"
  "${g[@]}" fetch -q --force "$remote" '+refs/notes/release-notes:refs/notes/release-notes' 2>/dev/null || true
  local head
  head="$("${g[@]}" rev-parse -q --verify "$tip^{commit}" 2>/dev/null)" ||
    { do_log "FATAL RELEASE_SHA is not a commit in $APP_PATH: '$tip'"; return 1; }

  local d
  d="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$d'; trap - RETURN" RETURN
  spl_release_note_rows "$head" "$depth" >"$d/rows.jsonl" || return 1
  local n
  n="$(grep -c . "$d/rows.jsonl")"
  ((n > 0)) || { do_log "FATAL no commits read from ${head:0:8}"; return 1; }
  jq -c -s --argjson b "$batch" '. as $r | range(0; length; $b) | {notes: $r[.:. + $b]}' "$d/rows.jsonl" >"$d/bodies.jsonl" || return 1

  if [[ "$dry" != 0 ]]; then
    cat "$d/bodies.jsonl"
    do_log "INFO DRY_RUN: $n commit(s) from ${head:0:8} in $(grep -c . "$d/bodies.jsonl") request(s), nothing sent (DRY_RUN=0 sends them)" >&2
    return 0
  fi

  do_require_bin yq curl gcloud || return 1
  do_spl_cloud_cnf || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local body stored=0 redacted=0 rejected=0 i=0 w
  while IFS= read -r body; do
    i=$((i + 1))
    printf '%s' "$body" >"$d/body.json"
    spl_hub_operator_call POST /v1/operator/release-notes "@$d/body.json" || return 1
    [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
      { do_log "FATAL POST /v1/operator/release-notes (request $i) answered HTTP $SPL_HUB_OP_STATUS: $(jq -r '.message // .error // empty' <<<"$SPL_HUB_OP_BODY" 2>/dev/null)"; return 1; }
    stored=$((stored + $(jq -r '.stored // 0' <<<"$SPL_HUB_OP_BODY")))
    redacted=$((redacted + $(jq -r '.redacted // 0' <<<"$SPL_HUB_OP_BODY")))
    rejected=$((rejected + $(jq -r '.rejected // [] | length' <<<"$SPL_HUB_OP_BODY")))
    while IFS= read -r w; do do_log "$w"; done < <(jq -r '.rejected // [] | .[] | "WARN rejected \(.sha[0:8]): \(.why)"' <<<"$SPL_HUB_OP_BODY")
  done <"$d/bodies.jsonl"
  printf '{"env":"%s","hub":"%s","from":"%s","commits":%d,"stored":%d,"redacted":%d,"rejected":%d}\n' \
    "$ENV" "$SPL_HUB_URL" "${head:0:8}" "$n" "$stored" "$redacted" "$rejected"
  do_log "OK $stored of $n release note row(s) stored on $SPL_HUB_URL (from ${head:0:8})"
}

# spl_release_note_rows <head-sha> <depth> -> one ingest row (JSON) per
# first-parent commit, newest first. The version map walks newest -> oldest:
# a tag at a commit contains every older commit on the line, so the running
# minimum of the tags seen so far is the first version that shipped it. Tags
# are ordered as release keys (cycle, then X.Y.Z); the row carries the plain
# X.Y.Z the hub accepts.
spl_release_note_rows() {
  local head="$1" depth="$2" g=(git -C "$APP_PATH")
  local -A tagv=()
  local obj ref v
  # an annotated tag's commit is %(*objectname); a lightweight one's is %(objectname)
  while read -r obj ref; do
    v="${ref#v}"
    spl_release_key_valid "$v" || continue
    if [[ -z "${tagv[$obj]:-}" ]] || spl_release_key_gt "${tagv[$obj]}" "$v"; then tagv[$obj]="$v"; fi
  done < <("${g[@]}" for-each-ref 'refs/tags/v*' --format='%(objectname) %(*objectname) %(refname:strip=2)' | awk 'NF == 3 {print $2, $3; next} {print $1, $2}')
  local has_notes=0
  "${g[@]}" rev-parse -q --verify refs/notes/release-notes >/dev/null 2>&1 && has_notes=1
  local sha min="" t msg note files area doc
  while read -r sha; do
    t="${tagv[$sha]:-}"
    if [[ -n "$t" ]] && { [[ -z "$min" ]] || spl_release_key_gt "$min" "$t"; }; then min="$t"; fi
    msg="$("${g[@]}" log -1 --format=%B "$sha")"
    note=""
    ((has_notes)) && note="$("${g[@]}" notes --ref=release-notes show "$sha" 2>/dev/null)"
    files="$("${g[@]}" diff-tree --no-commit-id --name-only -r --root "$sha")"
    doc=false
    [[ -n "$files" ]] && ! grep -qv '\.md$' <<<"$files" && doc=true
    area="$(sed -n 's|/.*||p' <<<"$files" | sort -u)"
    [[ "$(grep -c . <<<"$area")" == 1 ]] || area=""
    jq -cn --arg sha "$sha" --arg version "${min:+v${min%%-c*}}" --arg at "$("${g[@]}" log -1 --format=%cI "$sha")" \
      --arg message "$msg" --arg note "$note" --arg area "$area" --argjson doc "$doc" \
      '{sha: $sha, committed_at: $at, message: $message}
       + (if $version != "" then {version: $version} else {} end)
       + (if $note != "" then {note: $note} else {} end)
       + (if $area != "" then {area: $area} else {} end)
       + (if $doc then {doc_only: true} else {} end)' || return 1
  done < <("${g[@]}" rev-list --first-parent -n "$depth" "$head")
}
