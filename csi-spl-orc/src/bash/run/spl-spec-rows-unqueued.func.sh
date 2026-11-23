#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: list each spec on origin/master whose status header
# @description reads decided or signed and whose open build rows have no citing
# @description commit on master, no queued or placed ask (do_spl_spawn_queue /
# @description asks book) and no live lane (lane-map.sh / do_spl_lane_map).
# @description Fails closed if the asks book or fleet lane map cannot be read
# @description cleanly (e.g. LOCAL-ONLY / hub unreachable), so live work is
# @description never reported as unqueued. Writes nothing to git, hub or spool.
# @description Output formats: table (TSV + # total line), json, or digest
# @description (one markdown summary line for the daily morning digest, empty
# @description when nothing is unqueued).
# @param SPEC_UNQUEUED_REF (optional) - git ref to read specs and commits from, default origin/master
# @param SPEC_UNQUEUED_REPO (optional) - git repo path, default APP_PATH
# @param SPEC_UNQUEUED_DIR (optional) - fixture specs directory instead of git ref
# @param SPEC_UNQUEUED_FORMAT (optional) - table (default), json, or digest
# @param SPEC_UNQUEUED_FETCH (optional) - 1 fetches origin/<branch> first, default 0
# @param SPEC_UNQUEUED_ASKS_FILE (optional, tests) - asks JSON file instead of reading the hub
# @param SPEC_UNQUEUED_LANES_FILE (optional, tests) - lanes JSON file instead of reading the hub
# @param SPEC_UNQUEUED_COMMITS_FILE (optional, tests) - NUL-delimited commits file
# @param SPEC_UNQUEUED_ASKS_FN (optional, tests) - function printing asks JSON
# @param SPEC_UNQUEUED_LANES_FN (optional, tests) - function printing lanes JSON
# @example ./run -a do_spl_spec_rows_unqueued
# @example SPEC_UNQUEUED_FORMAT=json ./run -a do_spl_spec_rows_unqueued
# @example SPEC_UNQUEUED_FORMAT=digest ./run -a do_spl_spec_rows_unqueued
#------------------------------------------------------------------------------

do_spl_spec_rows_unqueued() {
  local fmt="${SPEC_UNQUEUED_FORMAT:-table}" ref="${SPEC_UNQUEUED_REF:-origin/master}"
  local repo="${SPEC_UNQUEUED_REPO:-${APP_PATH:-}}" py sha work rc=0
  [[ "$fmt" =~ ^(table|json|digest)$ ]] || { do_log "FATAL SPEC_UNQUEUED_FORMAT must be table, json or digest, got '$fmt'"; return 1; }
  py="${PROJ_PATH:?PROJ_PATH must be set}/src/bash/scripts/spec-rows-unqueued.py"
  [[ -f "$py" ]] || { do_log "FATAL missing parser script: $py"; return 1; }
  if [[ -z "${SPEC_UNQUEUED_DIR:-}" ]]; then
    [[ -n "$repo" && -d "$repo" ]] || { do_log "FATAL SPEC_UNQUEUED_REPO or APP_PATH must be a git repo"; return 1; }
    if [[ "${SPEC_UNQUEUED_FETCH:-0}" == 1 && "$ref" == origin/* ]]; then
      timeout 120 git -c safe.directory='*' -C "$repo" fetch -q origin "${ref#origin/}" </dev/null >/dev/null 2>&1 ||
        do_log "WARN spec-rows-unqueued: fetch of $ref failed; reading local ref"
    fi
    sha="$(git -c safe.directory='*' -C "$repo" rev-parse --short=9 --verify "${ref}^{commit}" 2>/dev/null)" ||
      { do_log "FATAL spec-rows-unqueued: cannot resolve $ref in $repo"; return 1; }
  else
    [[ -d "$SPEC_UNQUEUED_DIR" ]] || { do_log "FATAL SPEC_UNQUEUED_DIR is not a directory: $SPEC_UNQUEUED_DIR"; return 1; }
    sha="fixture"
  fi
  work="$(mktemp -d)" || return 1
  if _spl_sru_collect_inputs "$work"; then
    local py_args=(--ref "$ref" --sha "$sha" --asks-file "$work/asks.json" --lanes-file "$work/lanes.json" --format "$fmt")
    if [[ -n "${SPEC_UNQUEUED_DIR:-}" ]]; then
      py_args+=(--specs-dir "$SPEC_UNQUEUED_DIR")
      [[ -n "$repo" && -d "$repo" ]] && git -c safe.directory='*' -C "$repo" rev-parse --verify "${ref}^{commit}" >/dev/null 2>&1 &&
        py_args+=(--repo "$repo")
    else
      py_args+=(--repo "$repo")
    fi
    [[ -n "${SPEC_UNQUEUED_COMMITS_FILE:-}" ]] && py_args+=(--commits-file "$SPEC_UNQUEUED_COMMITS_FILE")
    python3 "$py" "${py_args[@]}" || rc=$?
  else
    rc=1
  fi
  rm -rf "$work"
  return "$rc"
}

# _spl_sru_collect_inputs <work>: populate <work>/asks.json and <work>/lanes.json,
# failing closed when either hub read is unavailable or LOCAL-ONLY.
_spl_sru_collect_inputs() {
  local work="$1" out
  if [[ -n "${SPEC_UNQUEUED_ASKS_FILE:-}" ]]; then
    [[ -r "$SPEC_UNQUEUED_ASKS_FILE" ]] || { do_log "FATAL unreadable SPEC_UNQUEUED_ASKS_FILE: $SPEC_UNQUEUED_ASKS_FILE"; return 1; }
    cp -- "$SPEC_UNQUEUED_ASKS_FILE" "$work/asks.json" || return 1
  else
    out="$("${SPEC_UNQUEUED_ASKS_FN:-spl_spec_rows_unqueued_asks_read}")" || { do_log "FATAL spec-rows-unqueued: could not read the asks book"; return 1; }
    printf '%s\n' "$out" >"$work/asks.json"
  fi
  jq -e '(type == "array") or (((.asks // .queue) | type == "array") and ((.hub // "ok") == "ok" or .hub == "partial"))' \
    "$work/asks.json" >/dev/null 2>&1 || {
    do_log "FATAL spec-rows-unqueued: asks book unreadable or hub offline (fail closed)"
    return 1
  }
  if [[ -n "${SPEC_UNQUEUED_LANES_FILE:-}" ]]; then
    [[ -r "$SPEC_UNQUEUED_LANES_FILE" ]] || { do_log "FATAL unreadable SPEC_UNQUEUED_LANES_FILE: $SPEC_UNQUEUED_LANES_FILE"; return 1; }
    cp -- "$SPEC_UNQUEUED_LANES_FILE" "$work/lanes.json" || return 1
  else
    out="$("${SPEC_UNQUEUED_LANES_FN:-spl_spec_rows_unqueued_lanes_read}")" || { do_log "FATAL spec-rows-unqueued: could not read the fleet lane map"; return 1; }
    printf '%s\n' "$out" >"$work/lanes.json"
  fi
  jq -e '(type == "array") or ((.lanes | type == "array") and ((.hub // "ok") == "ok"))' \
    "$work/lanes.json" >/dev/null 2>&1 || {
    do_log "FATAL spec-rows-unqueued: fleet lane map unreadable or LOCAL-ONLY (fail closed)"
    return 1
  }
}

# spl_spec_rows_unqueued_asks_read: asks book (every state, JSON) via do_spl_asks_open.
spl_spec_rows_unqueued_asks_read() {
  local run_dir
  run_dir="$(dirname "${BASH_SOURCE[0]}")"
  declare -F do_spl_asks_open >/dev/null || source "$run_dir/spl-asks-open.func.sh"
  ASKS_ALL=1 ASKS_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_asks_open 2>/dev/null | grep '^{' | tail -1
}

# spl_spec_rows_unqueued_lanes_read: fleet lane map (JSON) via do_spl_lane_map.
spl_spec_rows_unqueued_lanes_read() {
  local run_dir
  run_dir="$(dirname "${BASH_SOURCE[0]}")"
  declare -F do_spl_lane_map >/dev/null || source "$run_dir/spl-lane-map.func.sh"
  LANE_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_lane_map 2>/dev/null | grep '^{' | tail -1
}
