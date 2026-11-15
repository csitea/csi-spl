#!/bin/bash
#------------------------------------------------------------------------------
# @description The replay-set harness of spec 176 section 4.8 (T0.1,
# @description SPL-5556): measures a local-model candidate (client + model
# @description endpoint) on N past LANDED lanes of one task kind with a known
# @description answer. It runs no model and installs nothing.
# @description   REPLAY_CMD=prepare (default): pick N lanes of REPLAY_KIND, newest
# @description     landing first, plus REPLAY_I18N lanes of kind i18n (the
# @description     multilingual slice), and per lane write a fresh git repo of
# @description     the lane's base tree (no later commit in it) plus its brief,
# @description     under REPLAY_DIR/<kind>/cases/<key>/; the landed diffs go
# @description     to REPLAY_DIR/<kind>/answers/, outside every case.
# @description   REPLAY_CMD=pick: print the picked rows only (slice key brief
# @description     base landed files lines), nothing written.
# @description   REPLAY_CMD=run: run REPLAY_CANDIDATE once per case, cwd the
# @description     case repo, with REPLAY_BRIEF, REPLAY_WT, REPLAY_CASE_DIR and
# @description     REPLAY_KEY set: the seam for a client CLI on a model endpoint.
# @description   REPLAY_CMD=judge: per case FAIL (no change), PASS (the landed
# @description     answer's patch-id), else the R7 review line in the case's
# @description     review.line (its sha = the candidate commit), else R7-PENDING
# @description     with an r7-request.md for the cross-vendor reviewer. Writes
# @description     REPLAY_DIR/<kind>/report.md (version, tree, n) and
# @description     results.tsv; exit 3 while a case waits on its review.
# @description   REPLAY_CMD=keymap: read from the hub (DRY_RUN=0, desk ENV,
# @description     TENANT_ID, DESK_AGENT) the issue of each key git cites,
# @description     newest first, up to REPLAY_KEYMAP_MAX, and write
# @description     REPLAY_KEYMAP: brief file -> key, for the briefs whose key
# @description     the spawn filed (no Issue: line), matched by title.
# @description The past-lane source: the spawn's brief store (Kind: and Issue:
# @description lines) joined to git (the commits on REPLAY_REF whose subject
# @description scope cites the key, back to back); the hub only names keys.
# @description Detail: scripts/local-replay.py, csi-spl-doc/specs/176-full-offline-ai-stack/replay-harness.md.
# @param REPLAY_CMD (optional) - prepare (default), pick, run, judge, keymap
# @param REPLAY_KIND (required but for keymap) - the task kind, e.g. complex_coding
# @param REPLAY_N (optional) - lanes of the kind, default 5
# @param REPLAY_I18N (optional) - lanes of the i18n slice, default 1 (none for kind i18n)
# @param REPLAY_DIR (optional) - default SPL_VAR_APP_DIR/local-replay
# @param REPLAY_BRIEFS (optional) - the brief store, default SPOOL_ROOT/spawn-remote/briefs
# @param REPLAY_KEYMAP (optional) - default REPLAY_DIR/keymap.tsv, read when present
# @param REPLAY_REPO (optional) - the git tree, default this checkout
# @param REPLAY_REF (optional) - default origin/master
# @param REPLAY_MAX_LINES (optional) - largest landed diff taken, default 1500 changed lines
# @param REPLAY_CANDIDATE (required for run) - the command a case runs
# @param REPLAY_TIMEOUT (optional) - seconds per case, default 3600
# @param REPLAY_LABEL (optional) - the candidate, e.g. claude-code+<model>@<rev>, for the report
# @param REPLAY_KEYMAP_MAX (optional) - hub lookups for keymap, default 300
# @param DRY_RUN (optional) - keymap only: 1 (default) lists the keys, 0 reads the hub
# @example REPLAY_KIND=complex_coding REPLAY_N=5 ./run -a do_spl_local_replay
#------------------------------------------------------------------------------
do_spl_local_replay() {
  do_require_bin python3 || return 1
  do_require_bin git || return 1
  local cmd="${REPLAY_CMD:-prepare}" kind="${REPLAY_KIND:-}" py="$PROJ_PATH/src/bash/scripts/local-replay.py"
  local repo="${REPLAY_REPO:-${APP_PATH:-$PROJ_PATH/..}}" ref="${REPLAY_REF:-origin/master}" dir map
  dir="$(_spl_local_replay_dir)" || return 1
  map="${REPLAY_KEYMAP:-$dir/keymap.tsv}"
  case "$cmd" in pick|prepare|run|judge|keymap) ;; *) do_log "FATAL REPLAY_CMD must be prepare, pick, run, judge or keymap, got: $cmd"; return 1 ;; esac
  [[ "$cmd" == keymap || "$kind" =~ ^[a-z][a-z0-9_]*$ ]] || { do_log "FATAL REPLAY_KIND must name a task kind (e.g. complex_coding), got: '$kind'"; return 1; }
  case "$cmd" in
    pick) _spl_local_replay_pick "$py" "$kind" "$repo" "$ref" "$map" ;;
    prepare)
      local rows rc=0
      rows="$(_spl_local_replay_pick "$py" "$kind" "$repo" "$ref" "$map")" || return 1
      [[ -n "$rows" ]] || { do_log "FATAL no landed lane of kind $kind with a known answer in $(_spl_local_replay_briefs) on $ref"; return 1; }
      printf '%s\n' "$rows" | python3 "$py" prepare --kind "$kind" --out "$dir" --repo "$repo" --ref "$ref" || rc=$?
      return "$rc" ;;
    run)
      [[ -n "${REPLAY_CANDIDATE:-}" ]] || { do_log "FATAL REPLAY_CANDIDATE must be set (the command each case runs)"; return 1; }
      python3 "$py" run --kind "$kind" --out "$dir" --candidate "$REPLAY_CANDIDATE" --timeout "${REPLAY_TIMEOUT:-3600}" ;;
    judge)
      python3 "$py" judge --kind "$kind" --out "$dir" --label "${REPLAY_LABEL:-}" \
        --harness "$(git -C "$PROJ_PATH" rev-parse HEAD 2>/dev/null)" ;;
    keymap) _spl_local_replay_keymap "$py" "$repo" "$ref" "$map" ;;
  esac
}

# _spl_local_replay_dir -> REPLAY_DIR, else <var>/<org>/<app>/local-replay
# (spl_run_paths: the same answer in every worktree).
_spl_local_replay_dir() {
  if [[ -n "${REPLAY_DIR:-}" ]]; then printf '%s\n' "$REPLAY_DIR"; return 0; fi
  declare -F spl_run_paths >/dev/null || source "$PROJ_PATH/lib/bash/funcs/spl-run-paths.func.sh"
  spl_run_paths || { do_log "FATAL cannot derive SPL_VAR_APP_DIR: set REPLAY_DIR"; return 1; }
  printf '%s\n' "$SPL_VAR_APP_DIR/local-replay"
}

_spl_local_replay_briefs() {
  printf '%s\n' "${REPLAY_BRIEFS:-${SPOOL_ROOT:-/var/spool-hub}/spawn-remote/briefs}"
}

# _spl_local_replay_pick PY KIND REPO REF KEYMAP -> the TSV rows on stdout.
_spl_local_replay_pick() {
  local briefs; briefs="$(_spl_local_replay_briefs)"
  [[ -d "$briefs" ]] || { do_log "FATAL no brief store at $briefs (set REPLAY_BRIEFS)" >&2; return 1; }
  [[ "${REPLAY_N:-5}" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL REPLAY_N must be a positive number, got: ${REPLAY_N:-}" >&2; return 1; }
  [[ "${REPLAY_I18N:-1}" =~ ^[0-9]+$ ]] || { do_log "FATAL REPLAY_I18N must be a number, got: ${REPLAY_I18N:-}" >&2; return 1; }
  local -a km=()
  [[ -r "$5" ]] && km=(--keymap "$5")
  python3 "$1" pick --kind "$2" --n "${REPLAY_N:-5}" --i18n "${REPLAY_I18N:-1}" --briefs "$briefs" \
    --repo "$3" --ref "$4" --max-lines "${REPLAY_MAX_LINES:-1500}" "${km[@]}"
}

# _spl_local_replay_keymap PY REPO REF KEYMAP: the hub issue of each key
# local-replay.py keys names (one `spool issue get` each, read-only), then
# the title match into KEYMAP. A dry run (the default) only counts the keys.
_spl_local_replay_keymap() {
  local briefs keys k n=0 tmp rc=0
  briefs="$(_spl_local_replay_briefs)"
  [[ -d "$briefs" ]] || { do_log "FATAL no brief store at $briefs (set REPLAY_BRIEFS)"; return 1; }
  keys="$(python3 "$1" keys --briefs "$briefs" --repo "$2" --ref "$3" --n "${REPLAY_KEYMAP_MAX:-300}")" || return 1
  if [[ "${DRY_RUN:-1}" != 0 ]]; then
    do_log "INFO DRY_RUN would: read $(grep -c . <<<"$keys") hub issues (spool issue get) and write $4"
    return 0
  fi
  tmp="$(mktemp)"
  for k in $keys; do
    RUN_STDOUT_IS_DATA=1 spl_desk_issue_run get --ref "$k" 2>/dev/null | tr -d '\n' >>"$tmp" && n=$((n + 1))
    printf '\n' >>"$tmp"
  done
  mkdir -p "$(dirname "$4")" && python3 "$1" keymap --briefs "$briefs" --issues "$tmp" >"$4" || rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || { do_log "FATAL keymap failed (rc $rc)"; return 1; }
  do_log "OK read $n hub issues, $(grep -c . "$4") briefs mapped -> $4"
}
