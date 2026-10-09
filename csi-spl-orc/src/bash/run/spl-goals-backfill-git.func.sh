#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 112 8.1 + 12.7 (ORC-5): backfill ONE workspace's calendar
# @description from git. Builds one batch of the "major" past events since
# @description 2026-09-17 and PUTs it to the hub sync route (4.2), as the env
# @description SA's id token (spl_hub_operator_call), never SQL from a box.
# @description The batch, in this order: the first event "2026-09-17 spool-hub
# @description started"; the dated lines of csi-spl-doc/goals/milestones.yaml
# @description (milestone:<slug>); every x.y.0 tag (release:<tag>, kind
# @description release, its refs/notes/release-notes Lay-What line as the
# @description description; a patch tag x.y.z, z > 0, is never an event); every
# @description spec in state done by do_spl_spec_progress's rule (spec:<NNN>:done,
# @description at the last commit of its tasks.md). Every event names WORKSPACE
# @description and carries NO audience: the route sets it from the workspace's
# @description roadmap switch (HUB-2), and refuses a roadmap event that names
# @description one. The keys are stable and the batch has no clock in it, so a
# @description second run upserts the same keys and adds 0 events.
# @param ENV - required: dev or prd
# @param WORKSPACE - required, no default: the tenant slug the events go to
# @param BACKFILL_REPO (optional) - the git checkout to read; default APP_PATH
# @param DRY_RUN (optional) - 1 prints the batch and sends nothing
# @example ENV=dev WORKSPACE=t1 DRY_RUN=1 ./run -a do_spl_goals_backfill_git
# @example ENV=dev WORKSPACE=t1 ./run -a do_spl_goals_backfill_git
#------------------------------------------------------------------------------
SPL_GOALS_BACKFILL_GIT_START=2026-09-17

do_spl_goals_backfill_git() {
  : "${WORKSPACE:?WORKSPACE must be set (no default)}"
  spl_require_cloud_env || return 1
  [[ "$WORKSPACE" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL WORKSPACE must be a tenant slug, got: '$WORKSPACE'"; return 1; }
  local root="${BACKFILL_REPO:-${APP_PATH:-}}" body n
  [[ -n "$root" ]] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 ||
    { do_log "FATAL BACKFILL_REPO / APP_PATH is not a git checkout: '$root'"; return 1; }
  do_require_bin git jq || return 1
  body="$(umask 077; mktemp)" || return 1
  spl_goals_backfill_git_body "$root" "$WORKSPACE" >"$body" || { do_log "FATAL could not build the batch from $root"; rm -f "$body"; return 1; }
  spl_goals_backfill_git_check "$body" || { rm -f "$body"; return 1; }
  n="$(jq '.events | length' "$body")"
  if [[ "${DRY_RUN:-0}" == 1 ]]; then
    cat "$body"; rm -f "$body"
    do_log "OK DRY_RUN: $n event(s) for workspace $WORKSPACE, nothing sent"; return 0
  fi
  do_require_bin yq curl gcloud || { rm -f "$body"; return 1; }
  { do_spl_cloud_cnf && spl_hub_operator_url && do_gcp_pin_account "$SPL_CNF" &&
    do_gcp_require_live_account "$GCP_ACCOUNT" &&
    spl_hub_operator_call PUT /v1/calendar/sync "@$body"; } || { rm -f "$body"; return 1; }
  rm -f "$body"
  [[ "$SPL_HUB_OP_STATUS" == 200 ]] ||
    { do_log "FATAL the sync answered $SPL_HUB_OP_STATUS $(jq -r '.error // ""' <<<"$SPL_HUB_OP_BODY" 2>/dev/null) ($n event(s) not written)"; return 1; }
  do_log "OK $n git event(s) of workspace $WORKSPACE synced in $ENV ($GCP_ACCOUNT): $(jq -c '{created, updated, unchanged, deleted, carried}' <<<"$SPL_HUB_OP_BODY")"
}

# spl_goals_backfill_git_check <body.json>: the batch's own contract, checked
# before any call: {events} only, the first event is the 2026-09-17 start, no
# event carries an audience, every event names the one workspace, and a
# release: event is an x.y.0 tag.
spl_goals_backfill_git_check() {
  jq -e --arg ws "$WORKSPACE" --arg d "${SPL_GOALS_BACKFILL_GIT_START}T00:00:00Z" '
    (keys == ["events"])
    and (.events[0] | .source_key == "milestone:spool-hub-started" and .starts_at == $d)
    and all(.events[]; (has("audience") | not) and .workspace == $ws)
    and all(.events[] | select(.source_key | startswith("release:")); .release_version | test("^v[0-9]+\\.[0-9]+\\.0$"))' \
    "$1" >/dev/null || { do_log "FATAL the batch breaks its contract (first event, audience, workspace or a patch tag): refused, nothing sent"; return 1; }
}

# spl_goals_backfill_git_body <root> <workspace> -> {"events": [...]} on stdout.
spl_goals_backfill_git_body() {
  local root="$1" ws="$2"
  { spl_goals_backfill_git_start
    spl_goals_backfill_git_milestones "$root/csi-spl-doc/goals/milestones.yaml"
    spl_goals_backfill_git_tags "$root"
    spl_goals_backfill_git_specs "$root"
  } | jq -s -c --arg ws "$ws" --arg from "$SPL_GOALS_BACKFILL_GIT_START" '
      map(select(.date >= $from)) | unique_by(.source_key) as $u
      | {events: ([$u[] | select(.source_key == "milestone:spool-hub-started")]
                  + ([$u[] | select(.source_key != "milestone:spool-hub-started")] | sort_by(.date, .source_key))
          | map({workspace: $ws, source_key, title: .title[0:200], description: (.description // "")[0:4000],
                 kind, starts_at: (.date + "T00:00:00Z"), ends_at: (.date + "T00:00:00Z"), all_day: true}
                + (if .release_version then {release_version} else {} end)))}'
}

# The rows below are one JSON object per line: {source_key, date, title, kind, ...}.
spl_goals_backfill_git_start() {
  jq -cn --arg d "$SPL_GOALS_BACKFILL_GIT_START" \
    '{source_key: "milestone:spool-hub-started", date: $d, title: "spool-hub started", kind: "milestone"}'
}

# spl_goals_backfill_git_milestones <milestones.yaml>: its lines
# "YYYY-MM-DD <title> (<source>)"; the source becomes the description.
spl_goals_backfill_git_milestones() {
  [[ -f "$1" ]] || return 0
  sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+(.+)$/\1\t\2/p' "$1" |
    jq -R -c 'split("\t") | .[1] as $t | ($t | capture("^(?<title>.*?)\\s*\\((?<src>[^()]*)\\)\\s*$") // {title: $t, src: ""}) as $m
      | {source_key: ("milestone:" + ($m.title | ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-"))),
         date: .[0], title: $m.title, description: $m.src, kind: "milestone"}'
}

# spl_goals_backfill_git_tags <root>: the x.y.0 tags (a patch tag is not major,
# spec 8.1), dated by the tag (UTC). The description is the release note's
# Lay-What line, else its first line that is not a "Key: value" trailer; only
# the notes the checkout has (git fetch origin refs/notes/release-notes first).
spl_goals_backfill_git_tags() {
  local root="$1" tag day sha note
  TZ=UTC git -C "$root" for-each-ref --sort=creatordate \
    --format='%(refname:short)%09%(creatordate:format-local:%Y-%m-%d)%09%(*objectname)%(objectname)' refs/tags |
    while IFS=$'\t' read -r tag day sha; do
      [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.0$ ]] || continue
      note="$(git -C "$root" notes --ref=release-notes show "${sha:0:40}" 2>/dev/null |
        awk '/^Lay-What:/ { sub(/^Lay-What:[[:space:]]*/, ""); print; exit }
             /[^[:space:]]/ && !/^[A-Z][A-Za-z-]*:/ && f == "" { f = $0 }
             END { if (NR && f != "") print f }' | sed -n 1p)" || note=""
      jq -cn --arg t "$tag" --arg d "$day" --arg n "$note" \
        '{source_key: ("release:" + $t), date: $d, title: ("Release " + $t), description: $n, kind: "release", release_version: $t}'
    done
}

# spl_goals_backfill_git_specs <root>: the specs in state done (spec 5.1, the
# rule of do_spl_spec_progress), dated by the last commit of their tasks.md.
spl_goals_backfill_git_specs() {
  local root="$1" id state title day
  # shellcheck source=spl-spec-progress.func.sh
  declare -F _spl_spec_progress_rows >/dev/null || source "${BASH_SOURCE[0]%/*}/spl-spec-progress.func.sh"
  [[ -d "$root/csi-spl-doc/specs" ]] || return 0
  _spl_spec_progress_rows "$root/csi-spl-doc/specs" "" |
    while IFS=$'\t' read -r id state _ _ _ _ title; do
      [[ "$state" == "done" ]] || continue
      day="$(TZ=UTC git -C "$root" log -1 --date=format-local:%Y-%m-%d --format=%cd -- "csi-spl-doc/specs/$id/tasks.md")"
      [[ -n "$day" ]] || continue
      jq -cn --arg k "spec:${id:0:3}:done" --arg d "$day" --arg t "Spec ${id:0:3} done: ${title:-$id}" \
        '{source_key: $k, date: $d, title: $t, kind: "milestone"}'
    done
}
