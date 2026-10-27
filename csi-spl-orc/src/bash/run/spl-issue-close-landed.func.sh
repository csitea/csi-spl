#!/bin/bash
#------------------------------------------------------------------------------
# @description A fix landed on master closes the issues it names (owner HUM-10,
# @description t1 dee4081d msg ea519baa: "Done should be the automatic target").
# @description The rule, as code (scripts/issue-close-landed.py holds the parse):
# @description   - a fix / feat / perf / refactor commit whose subject scope
# @description     carries the key, "fix(orc, SPL-12): ...", or any commit with
# @description     a "Closes: SPL-12" trailer; a bare mention in the body or a
# @description     "Refs: SPL-12" trailer never closes
# @description   - each OPEN issue so named gets a comment with the sha(s) and
# @description     the release note link, then moves to done; an issue already
# @description     done or diss is a no-op; an epic or a feature is skipped;
# @description     an issue in qas is a no-op too: it holds a review a human
# @description     asked for, which closes it (spec 135 Q7, owner msg 910b14c9)
# @description   - a move that closes the issue's epic with it (SPL-1729) while
# @description     a queued spawn ask's brief on this box names that epic
# @description     reopens the epic: that lane files its issue under it (SPL-2508);
# @description     a brief on another box: that box's placer reopens it (SPL-2558)
# @description   - every (issue, sha) pair acted on goes to a ledger (closed.tsv:
# @description     key, sha, moved | noop) and never
# @description     acts again: an issue the owner reopens is not closed again by
# @description     the same sha (a newer commit naming it may close it)
# @description Reads the commits after the cursor (the master sha of the last
# @description complete run) up to ISSUE_CLOSE_REF; the first run needs
# @description ISSUE_CLOSE_SINCE=all (the back-fill: master's whole history) or
# @description a sha. Standing: the box cron issue-close-landed (every 5 min,
# @description ISSUE_CLOSE_HOLDER=1), not a CI job: a move needs the desk's
# @description box-signed hub session, which no CI runner holds.
# @description Holder mode (SPL-2631, sat-alone panel row 03): only the box of
# @description the dispatch lease holder sweeps, so the sweep moves with the
# @description lease. The cursor and the ledger travel through the env's box
# @description state store (do_spl_box_state_put / _get) as snapshots
# @description <rw_prefix>/issue-close-landed/<env>-<tenant>/<YYYYMMDD>/<epoch>-<sha>/
# @description {cursor,closed.tsv}, a new object name each time (the store
# @description never overwrites): the holder adopts the newest one that is
# @description ahead of its own cursor (ledger rows merged), sweeps, then
# @description publishes its own; any other box only publishes what it holds.
# @description A store error (an HTTP 403 too) logs "store read failed (HTTP <code>)"
# @description or "store publish failed (HTTP <code>)", never "no snapshot yet" (SPL-2688).
# @description Workspace mode (ISSUE_CLOSE_WORKSPACE=<tenant>, owner HUM-10
# @description msgs ca8a036d, dbead7a1): the commits read are the trunk of that
# @description workspace's repo, its clone on this box from the box map
# @description $SPOOL_ROOT/workspace-repos.tsv (workspace-repo.inc.sh), which
# @description also gives ENV, the desk (DESK_AGENT, DESK_BOX) and the live
# @description url; TENANT_ID is the workspace. The done comment names the
# @description repo, each sha and the live url instead of the release note.
# @description No holder mode (the map is this box's), and the first run with
# @description no cursor reads the last ISSUE_CLOSE_WS_FIRST_N trunk commits
# @description (default 50; all of a shorter trunk): a lane may have cited a
# @description workspace key before the map row existed (SPL-3528).
# @description Prints one TSV row per named key (key, moved | would-move |
# @description noop | skip | failed, sha(s), detail) and a summary line. Reads
# @description the issue list and git even with DRY_RUN=1; writes the hub, the
# @description ledger and the cursor only with DRY_RUN=0.
# @param ENV - required: dev or prd, the hub of the issues
# @param TENANT_ID - required: the tenant the desk is seated in
# @param DESK_AGENT - required: the agent that comments and moves
# @param DESK_BOX (optional) - default the box's desk (spl_desk_box_default)
# @param ISSUE_CLOSE_REF (optional) - the trunk ref read, default origin/master
# @param ISSUE_CLOSE_FETCH (optional) - 1 (default) fetches the ref's remote first
# @param ISSUE_CLOSE_SINCE (optional) - all | <sha>: read from there instead of the cursor
# @param ISSUE_CLOSE_STATE_DIR (optional) - the cursor + ledger dir, default
# @param   ${XDG_STATE_HOME:-$HOME/.local/state}/<org>-<app>/issue-close-landed/<env>-<tenant>
# @param ISSUE_CLOSE_EVIDENCE (optional) - TSV key, sha[,sha], why: landings a review cited
# @param   though no commit names the key by the rule (a triage back-fill); same comment + ledger
# @param ISSUE_CLOSE_WUI_URL (optional) - the release note host, default the cnf's WUI
# @param ISSUE_CLOSE_HOLDER (optional) - 1: holder mode (above); default 0
# @param SPOOL_ROOT (optional) - holder mode: the spool root of dispatch/lease, default /var/spool-hub
# @param SPOOL_BOX_TAG (optional) - holder mode: this box, default SPOOL_BOX_TAG of <SPOOL_ROOT>/box.env
# @param ISSUE_CLOSE_WORKSPACE (optional) - a tenant of the box map: workspace mode (above)
# @param ISSUE_CLOSE_WS_FIRST_N (optional) - workspace mode, first run (no cursor): the trunk commits read, default 50
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ISSUE_CLOSE_WORKSPACE=acme DRY_RUN=0 ./run -a do_spl_issue_close_landed
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-685 DESK_BOX=box-ci ISSUE_CLOSE_SINCE=all ./run -a do_spl_issue_close_landed
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-685 DESK_BOX=box-ci DRY_RUN=0 ./run -a do_spl_issue_close_landed
# @example ENV=prd TENANT_ID=t1 DESK_AGENT=c-685 ISSUE_CLOSE_HOLDER=1 ./run -a do_spl_issue_close_landed
#------------------------------------------------------------------------------
# spl_role_seat: a map desk that is a role seat, in its live id (SPL-3831)
declare -F spl_role_seat >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"
do_spl_issue_close_landed() {
  do_require_bin git python3 || return 1
  local dry=1 ref="${ISSUE_CLOSE_REF:-origin/master}" since="${ISSUE_CLOSE_SINCE:-}" dir head rng wui list plan
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  ICL_REPO="$APP_PATH" ICL_WS="" ICL_WS_ROW=""
  if [[ -n "${ISSUE_CLOSE_WORKSPACE:-}" ]]; then
    spl_icl_ws || return 1
    ref="$ICL_WS_REF"
  fi
  dir="$(spl_icl_state_dir)" || return 1
  if [[ "${ISSUE_CLOSE_HOLDER:-0}" == 1 && -z "$ICL_WS" ]]; then
    spl_icl_holder_tick "$dir" "$dry"; return
  fi
  spl_icl_fetch "$ref" || return 1
  head="$(git -C "$ICL_REPO" rev-parse -q --verify "$ref^{commit}")" || { do_log "FATAL $ref is not a commit"; return 1; }
  if [[ -n "$ICL_WS" && -z "$since" && ! -s "$dir/cursor" ]]; then
    since="$(spl_icl_ws_first "$head")" || return 1
  fi
  rng="$(spl_icl_range "$dir" "$since" "$head")" || return 1
  if [[ -n "$ICL_WS" ]]; then wui="$(wr_field "$ICL_WS_ROW" 5)"; else wui="$(spl_icl_wui_url)" || return 1; fi
  list="$(mktemp)"; plan="$(mktemp)"
  spl_issue_list_fetch --status eval,todo,wip,blocked,onhold,qas --limit 500 >"$list" ||
    { rm -f "$list" "$plan"; return 1; }
  local -a ev=()
  if [[ -n "${ISSUE_CLOSE_EVIDENCE:-}" ]]; then
    [[ -r "$ISSUE_CLOSE_EVIDENCE" ]] || { do_log "FATAL ISSUE_CLOSE_EVIDENCE is not a readable file: '$ISSUE_CLOSE_EVIDENCE'"; rm -f "$list" "$plan"; return 1; }
    ev=("$ISSUE_CLOSE_EVIDENCE")
  fi
  python3 "$PROJ_PATH/src/bash/scripts/issue-close-landed.py" "$list" "$ICL_REPO" "$rng" "$dir/closed.tsv" "${ev[@]}" >"$plan" ||
    { do_log "FATAL issue-close-landed.py failed"; rm -f "$list" "$plan"; return 1; }
  rm -f "$list"
  local rc=0
  spl_icl_apply "$plan" "$dry" "$dir" "$wui" || rc=$?
  rm -f "$plan"
  if (( rc == 0 && ! dry )); then
    printf '%s\n' "$head" >"$dir/cursor.tmp" && mv "$dir/cursor.tmp" "$dir/cursor"
    do_log "OK cursor at ${head:0:12} ($dir/cursor)"
  elif (( rc != 0 )); then
    do_log "WARN the cursor stays: the next run retries the range (the ledger keeps the moves that landed)"
  fi
  return $rc
}

# spl_icl_fetch REF: fetch the ref's remote first (ISSUE_CLOSE_FETCH=1, default).
spl_icl_fetch() {
  [[ "${ISSUE_CLOSE_FETCH:-1}" == 1 && "$1" == */* ]] || return 0
  git -C "${ICL_REPO:-$APP_PATH}" fetch -q "${1%%/*}" "${1#*/}" || { do_log "FATAL git fetch $1 failed"; return 1; }
}

# spl_icl_ws_first HEAD -> the since of a workspace's first run (no cursor):
# the commit ISSUE_CLOSE_WS_FIRST_N first-parent steps below HEAD, or "all"
# when the trunk is shorter. The head itself is read: a lane may have cited a
# workspace key before its map row existed.
spl_icl_ws_first() {
  local head="$1" n="${ISSUE_CLOSE_WS_FIRST_N:-50}" c
  [[ "$n" =~ ^[1-9][0-9]{0,4}$ ]] || { do_log "FATAL ISSUE_CLOSE_WS_FIRST_N must be a count 1..99999, got: '$n'" >&2; return 1; }
  c="$(git -C "$ICL_REPO" rev-list --first-parent --skip="$n" --max-count=1 "$head")" || return 1
  do_log "INFO workspace $ICL_WS: no cursor yet, it reads the last $n trunk commits up to ${head:0:12}${c:+ (from ${c:0:12})}" >&2
  printf '%s\n' "${c:-all}"
}

# spl_icl_ws: workspace mode. The box map's row of ISSUE_CLOSE_WORKSPACE sets
# ICL_WS, ICL_WS_ROW, ICL_REPO (its clone), ICL_WS_REF (origin/<trunk>), and
# ENV, TENANT_ID, DESK_AGENT, DESK_BOX where the caller left them unset. A
# map desk that is a role seat (c-001) acts as the seat's live id
# (spl_role_seat): a vendor switch moves the seat to g-001 and its desk then
# announces g-001 only, so the hub refuses c-001 (SPL-3831).
spl_icl_ws() {
  local t="$ISSUE_CLOSE_WORKSPACE" row b rc=0 n live
  # shellcheck source=../features/spawn-agents/lib/workspace-repo.inc.sh
  declare -F wr_row >/dev/null || . "$PROJ_PATH/src/bash/features/spawn-agents/lib/workspace-repo.inc.sh" || return 1
  row="$(wr_row "$t")" || rc=$?
  (( rc == 0 )) || { (( rc == 1 )) && do_log "FATAL ISSUE_CLOSE_WORKSPACE=$t has no row in the box map $(wr_map)"; return 1; }
  ICL_WS="$t" ICL_WS_ROW="$row" ICL_REPO="$(wr_field "$row" 3)"
  [[ -d "$ICL_REPO/.git" ]] || { do_log "FATAL the clone of workspace $t, $ICL_REPO, is not a git repo on this box"; return 1; }
  b="$(wr_field "$row" 4)"
  if [[ "$b" == - ]]; then
    b="$(git -C "$ICL_REPO" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"; b="${b#origin/}"
    [[ -n "$b" ]] || { git -C "$ICL_REPO" rev-parse -q --verify refs/remotes/origin/main >/dev/null && b=main; }
  fi
  ICL_WS_REF="origin/${b:-master}"
  TENANT_ID="$t" ENV="${ENV:-$(wr_field "$row" 1)}"
  if [[ -z "${DESK_AGENT:-}" ]]; then
    DESK_AGENT="$(wr_field "$row" 6)" n="$(spl_role_seat_num "$DESK_AGENT" 2>/dev/null)"
    [[ -n "$n" ]] && live="$(spl_role_seat "$n")" && [[ -n "$live" && "$live" != "$DESK_AGENT" ]] &&
      { do_log "INFO workspace $t: the map's desk $DESK_AGENT is role seat $n, live as $live" >&2; DESK_AGENT="$live"; }
  fi
  DESK_BOX="${DESK_BOX:-$(wr_field "$row" 7)}"
  export TENANT_ID ENV DESK_AGENT DESK_BOX
}

# spl_icl_holder_tick DIR DRY: holder mode (SPL-2631). The box of the dispatch
# lease holder adopts the store's newest snapshot, sweeps, publishes its own;
# any other box only publishes the state it holds, so the next holder finds it.
spl_icl_holder_tick() {
  local dir="$1" dry="$2" root="${SPOOL_ROOT:-/var/spool-hub}" holder="" box hbox rc=0
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  box="${SPOOL_BOX_TAG:-$(sed -n 's/^SPOOL_BOX_TAG=//p' "$root/box.env" 2>/dev/null | tail -n 1)}"
  hbox="${holder#*@}"; [[ "$holder" == *@* ]] || hbox="$box"
  if [[ ! "$holder" =~ ^[A-Za-z][A-Za-z0-9-]*(@[a-z0-9][a-z0-9-]*)?$ || -z "$box" || "$hbox" != "$box" ]]; then
    do_log "OK issue-close-landed: the dispatch holder ${holder:-<none>} is not on this box (${box:-<unknown>}); its box sweeps"
    spl_icl_publish "$dir" "$dry" || do_log "WARN issue-close-landed: the hand-over snapshot was not published; the next tick retries"
    return 0
  fi
  spl_icl_fetch "${ISSUE_CLOSE_REF:-origin/master}" || return 1
  spl_icl_adopt "$dir" "$dry" || do_log "WARN issue-close-landed: the box state store was not read; this run goes on with the local cursor"
  ISSUE_CLOSE_HOLDER=0 ISSUE_CLOSE_FETCH=0 do_spl_issue_close_landed || rc=$?
  (( rc == 0 )) || return $rc
  spl_icl_publish "$dir" "$dry" || do_log "WARN issue-close-landed: the snapshot was not published; the next tick retries"
  return 0
}

# spl_icl_store_prefix -> the snapshot prefix under rw_prefix: issue-close-landed/<env>-<tenant>
spl_icl_store_prefix() { printf 'issue-close-landed/%s-%s\n' "${ENV:?ENV unset}" "$TENANT_ID"; }

# spl_icl_newest -> <YYYYMMDD>/<epoch>-<sha> of the store's newest snapshot,
# empty when it holds none: the newest day dir, then its newest snapshot.
spl_icl_newest() {
  local pre day snap
  pre="$(spl_icl_store_prefix)"
  day="$(spl_icl_store_ls "$pre/")" || return 1
  day="$(grep -oE '/[0-9]{8}/$' <<<"$day" | tr -d / | sort | tail -n 1)"
  [[ -n "$day" ]] || return 0
  snap="$(spl_icl_store_ls "$pre/$day/")" || return 1
  snap="$(grep -oE '/[0-9]{10}-[0-9a-f]{40}/$' <<<"$snap" | tr -d / | sort | tail -n 1)"
  [[ -z "$snap" ]] || printf '%s/%s\n' "$day" "$snap"
}

# spl_icl_adopt DIR DRY: take the store's newest cursor when this box has none
# or it is ahead of this box's; the ledgers are merged (a row is never lost).
spl_icl_adopt() {
  local dir="$1" dry="$2" snap rsha lsha="" tmp
  snap="$(spl_icl_newest)" || return 1
  [[ -n "$snap" ]] || { do_log "INFO issue-close-landed: the box state store holds no snapshot yet"; return 0; }
  rsha="${snap##*-}"
  [[ -s "$dir/cursor" ]] && lsha="$(head -n 1 "$dir/cursor")"
  [[ "$rsha" != "$lsha" ]] || return 0
  if [[ -n "$lsha" ]] && ! git -C "$APP_PATH" merge-base --is-ancestor "$lsha" "$rsha" 2>/dev/null; then
    do_log "INFO issue-close-landed: the store's cursor ${rsha:0:12} is not ahead of this box's ${lsha:0:12}: kept"
    return 0
  fi
  (( dry )) && { do_log "OK DRY_RUN: would adopt the store's cursor ${rsha:0:12} and ledger ($snap)"; return 0; }
  tmp="$(mktemp -d)"
  if ! spl_icl_store_get "$(spl_icl_store_prefix)/$snap" "$tmp" || [[ "$(head -n 1 "$tmp/cursor" 2>/dev/null)" != "$rsha" ]]; then
    rm -rf "$tmp"; do_log "WARN issue-close-landed: snapshot $snap could not be read or names another sha"; return 1
  fi
  local rc=0
  touch "$dir/closed.tsv" "$tmp/closed.tsv" && awk 'NF && !seen[$0]++' "$dir/closed.tsv" "$tmp/closed.tsv" >"$dir/closed.tsv.tmp" &&
    mv "$dir/closed.tsv.tmp" "$dir/closed.tsv" && printf '%s\n' "$rsha" >"$dir/cursor.tmp" && mv "$dir/cursor.tmp" "$dir/cursor" &&
    printf '%s\n' "$rsha" >"$dir/published" || rc=1
  rm -rf "$tmp"
  (( rc == 0 )) || { do_log "WARN issue-close-landed: snapshot $snap was read but not written to $dir"; return 1; }
  do_log "OK issue-close-landed: adopted the store's cursor ${rsha:0:12} and ledger ($snap)"
}

# spl_icl_publish DIR DRY: put this box's cursor + ledger as a new snapshot,
# once per cursor ($DIR/published remembers the last one put).
spl_icl_publish() {
  local dir="$1" dry="$2" sha now day tmp rc=0
  [[ -s "$dir/cursor" ]] || return 0
  sha="$(head -n 1 "$dir/cursor")"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { do_log "WARN issue-close-landed: $dir/cursor holds no sha"; return 1; }
  [[ "$(head -n 1 "$dir/published" 2>/dev/null)" != "$sha" ]] || return 0
  now="$(date -u +%s)"; day="$(date -u -d "@$now" +%Y%m%d)"
  (( dry )) && { do_log "OK DRY_RUN: would publish cursor ${sha:0:12} as $day/$now-$sha"; return 0; }
  tmp="$(mktemp -d)"; mkdir -p "$tmp/$now-$sha"
  cp "$dir/cursor" "$tmp/$now-$sha/cursor" && { cp "$dir/closed.tsv" "$tmp/$now-$sha/closed.tsv" 2>/dev/null || : >"$tmp/$now-$sha/closed.tsv"; } &&
    chmod 0644 "$tmp/$now-$sha/"* && spl_icl_store_put "$tmp/$now-$sha" "$(spl_icl_store_prefix)/$day" || rc=1
  rm -rf "$tmp"
  (( rc == 0 )) || return 1
  printf '%s\n' "$sha" >"$dir/published"
  do_log "OK issue-close-landed: published cursor ${sha:0:12} as $day/$now-$sha"
}

# spl_icl_store_ls REL -> the child URLs under <rw_prefix>/REL of the store
# (gcloud storage ls); empty, not a failure, when nothing is there. Any other
# error (a 403 too) is a failed read, never "no snapshot yet" (SPL-2688).
spl_icl_store_ls() {
  local out
  spl_box_state_gs_begin gcloud >&2 || { do_log "WARN issue-close-landed: store read failed (HTTP none): no store credential" >&2; return 1; }
  if out="$(gcloud storage ls "gs://$SPL_BOX_STATE_BUCKET/$SPL_BOX_STATE_RW_PREFIX/$1" --account="$GCP_ACCOUNT" 2>&1)"; then
    printf '%s\n' "$out"; return 0
  fi
  grep -q 'matched no objects' <<<"$out" && ! grep -qE '(HTTP|Error|Exception)[: ]*[0-9]{3}' <<<"$out" && return 0
  do_log "WARN issue-close-landed: store read failed (HTTP $(spl_icl_http_code "$out")): cannot list $1: ${out##*$'\n'}" >&2
  return 1
}

# spl_icl_http_code TEXT -> the HTTP status gcloud printed (HTTPError 403,
# AccessDeniedException: 403, ...), else "unknown".
spl_icl_http_code() {
  local c
  c="$(grep -oE '(HTTP[A-Za-z]*|Exception|Error)[: ]+[0-9]{3}' <<<"$1" | grep -oE '[0-9]{3}$' | sed -n 1p)"
  printf '%s\n' "${c:-unknown}"
}

# spl_icl_store_get REL DEST: download the snapshot <rw_prefix>/REL/ into DEST.
spl_icl_store_get() {
  local out
  spl_box_state_gs_begin >&2 || { do_log "WARN issue-close-landed: store read failed (HTTP none): no store credential" >&2; return 1; }
  out="$(DRY_RUN=0 SRC="$SPL_BOX_STATE_RW_PREFIX/$1/" DEST="$2" do_spl_box_state_get 2>&1)" && { printf '%s\n' "$out" >&2; return 0; }
  printf '%s\n' "$out" >&2
  do_log "WARN issue-close-landed: store read failed (HTTP $(spl_icl_http_code "$out")): cannot get $1" >&2
  return 1
}

# spl_icl_store_put SRC PREFIX: upload the snapshot dir SRC under <rw_prefix>/PREFIX/.
spl_icl_store_put() {
  local out
  out="$(DRY_RUN=0 SRC="$1" PREFIX="$2" do_spl_box_state_put 2>&1)" && { printf '%s\n' "$out" >&2; return 0; }
  printf '%s\n' "$out" >&2
  do_log "WARN issue-close-landed: store publish failed (HTTP $(spl_icl_http_code "$out")): cannot put $2/${1##*/}" >&2
  return 1
}

# spl_icl_state_dir -> the cursor + ledger dir of ENV + TENANT_ID, created.
spl_icl_state_dir() {
  [[ "${TENANT_ID:-}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { do_log "FATAL TENANT_ID is not a tenant id: '${TENANT_ID:-}'" >&2; return 1; }
  local oa
  oa="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"; oa="${oa%-orc}"
  local d="${ISSUE_CLOSE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/$oa/issue-close-landed/${ENV:?ENV unset}-$TENANT_ID}"
  mkdir -p "$d" || { do_log "FATAL cannot create $d" >&2; return 1; }
  printf '%s\n' "$d"
}

# spl_icl_range DIR SINCE HEAD -> the git range: SINCE=all the whole history,
# a sha <sha>..HEAD, empty the saved cursor (none saved = refuse: run the
# back-fill first, so a first cron tick never reads 5000 commits unasked).
spl_icl_range() {
  local dir="$1" since="$2" head="$3" c
  if [[ "$since" == all ]]; then printf '%s\n' "$head"; return 0; fi
  if [[ -z "$since" ]]; then
    [[ -s "$dir/cursor" ]] || { do_log "FATAL no cursor in $dir: run the back-fill once (ISSUE_CLOSE_SINCE=all, DRY_RUN=1 then 0)" >&2; return 1; }
    since="$(head -n 1 "$dir/cursor")"
  fi
  c="$(git -C "${ICL_REPO:-$APP_PATH}" rev-parse -q --verify "$since^{commit}")" || { do_log "FATAL '$since' is not a commit in ${ICL_REPO:-$APP_PATH}" >&2; return 1; }
  git -C "${ICL_REPO:-$APP_PATH}" merge-base --is-ancestor "$c" "$head" ||
    { do_log "FATAL ${c:0:12} is not an ancestor of ${head:0:12}: master was rewritten? set ISSUE_CLOSE_SINCE" >&2; return 1; }
  printf '%s..%s\n' "$c" "$head"
}

# spl_icl_wui_url -> the WUI base of ENV (the release note host), from the cnf.
spl_icl_wui_url() {
  if [[ -n "${ISSUE_CLOSE_WUI_URL:-}" ]]; then printf '%s\n' "${ISSUE_CLOSE_WUI_URL%/}"; return 0; fi
  do_spl_desk_cnf >&2 || return 1
  [[ -n "${SPL_WUI_URL:-}" ]] || { do_log "FATAL the cnf gives no WUI host for $ENV" >&2; return 1; }
  printf '%s\n' "$SPL_WUI_URL"
}

# spl_icl_apply PLAN DRY DIR WUI: act on each row, print the report. A failed
# move is reported, the others still run, and the return is 1.
spl_icl_apply() {
  local plan="$1" dry="$2" dir="$3" wui="$4" key verdict shas detail moved=0 noop=0 skip=0 failed=0 s
  while IFS=$'\t' read -r key verdict shas detail; do
    [[ -n "$key" ]] || continue
    case "$verdict" in
      close)
        if (( dry )); then
          printf '%s\twould-move\t%s\t%s\n' "$key" "$shas" "$detail"; moved=$((moved + 1))
        elif spl_icl_move "$key" "$shas" "$detail" "$wui"; then
          for s in ${shas//,/ }; do printf '%s\t%s\tmoved\n' "$key" "$s" >>"$dir/closed.tsv"; done
          printf '%s\tmoved\t%s\t%s\n' "$key" "$shas" "$detail"; moved=$((moved + 1))
        else
          printf '%s\tfailed\t%s\tthe comment or the move failed (see the log)\n' "$key" "$shas"; failed=$((failed + 1))
        fi ;;
      noop)
        (( dry )) || for s in ${shas//,/ }; do printf '%s\t%s\tnoop\n' "$key" "$s" >>"$dir/closed.tsv"; done
        printf '%s\tnoop\t%s\t%s\n' "$key" "$shas" "$detail"; noop=$((noop + 1)) ;;
      *)
        printf '%s\tskip\t%s\t%s\n' "$key" "$shas" "$detail"; skip=$((skip + 1)) ;;
    esac
  done <"$plan"
  do_log "OK issue close landed: $moved $( ((dry)) && echo would-move || echo moved), $noop no-op, $skip skipped, $failed failed"
  (( failed == 0 ))
}

# spl_icl_move KEY SHAS SUBJECT WUI: the audit comment, then status done.
spl_icl_move() {
  local key="$1" shas="$2" subject="$3" wui="$4" body s lines="" ans
  if [[ -n "${ICL_WS:-}" ]]; then
    for s in ${shas//,/ }; do lines+="- $(wr_field "$ICL_WS_ROW" 2) ${s:0:12}"$'\n'; done
    body="Landed on $(wr_field "$ICL_WS_ROW" 2) ${ICL_WS_REF#origin/}, so done, by do_spl_issue_close_landed.

${lines}
Live: $wui

The newest: $subject

Reopen it if it is not done: the same commit never closes it again."
    spl_desk_issue_run comment --ref "$key" --body "$body" >/dev/null || return 1
    spl_desk_issue_run update --ref "$key" --status "done" >/dev/null
    return
  fi
  for s in ${shas//,/ }; do lines+="- ${s:0:12}: $wui/releases/$s"$'\n'; done
  body="Landed on master, so done (owner rule, t1 dee4081d msg ea519baa), by do_spl_issue_close_landed.

${lines}
The newest: $subject

Reopen it if it is not done: the same commit never closes it again."
  spl_desk_issue_run comment --ref "$key" --body "$body" >/dev/null || return 1
  ans="$(spl_desk_issue_run update --ref "$key" --status "done")" || return 1
  spl_icl_keep_epic "$key" "$ans"
}

# spl_icl_keep_epic KEY ANSWER: the move closed KEY's epic with it (SPL-1729:
# its last open issue closed, so the epic closed and was archived) while a
# queued spawn ask's brief on this box still names that epic: reopen it, or
# that lane's issue is refused at launch (unknown_parent; SPL-2508, epic
# SPL-2372 on 2026-10-18). A brief on another box is not seen here: its
# placer reopens the auto-closed epic when that row is next (do_spl_spawn_place,
# SPL-2558). The reopen is li_epic_reopen (lane-issue.inc.sh), shared with it.
spl_icl_keep_epic() {
  local key="$1" epic asks
  epic="$(tail -n 1 <<<"$2" | jq -r '(.result.epic_closed // .epic_closed // {}).key // empty' 2>/dev/null)"
  [[ -n "$epic" ]] || return 0
  asks="$(spl_icl_queued_for "$epic")"
  if [[ -z "$asks" ]]; then
    do_log "INFO $key closed its epic $epic (SPL-1729); no queued spawn brief here names it"
    return 0
  fi
  declare -F li_epic_reopen >/dev/null || . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
  if li_epic_reopen "$epic" "Reopened by do_spl_issue_close_landed: $key closed it as its last open issue, but queued spawn asks still name it on their Epic: line ($asks), and their lanes file their issues under it (SPL-2508)."; then
    do_log "OK $epic reopened: queued spawn asks $asks name it"
  else
    do_log "WARN $key closed its epic $epic, which queued spawn asks $asks name, and reopening it failed: reopen it by hand"
  fi
  return 0
}

# spl_icl_queued_for EPIC -> the queued spawn asks (8 hex each, space
# separated) whose brief on this box names EPIC. ISSUE_CLOSE_QUEUE_CMD (tests)
# prints the queue JSON; else do_spl_spawn_queue's. No queue: nothing.
spl_icl_queued_for() {
  local rows id slug brief e out=""
  if [[ -n "${ISSUE_CLOSE_QUEUE_CMD:-}" ]]; then
    rows="$($ISSUE_CLOSE_QUEUE_CMD 2>/dev/null)"
  else
    rows="$(SPAWN_QUEUE_FORMAT=json SPAWN_QUEUE_SHARE=0 do_spl_spawn_queue 2>/dev/null)"
  fi
  declare -F spl_spawn_place_brief >/dev/null || source "$PROJ_PATH/src/bash/run/spl-spawn-place.func.sh"
  declare -F li_brief_epic_spec >/dev/null || . "$PROJ_PATH/src/bash/features/spawn-agents/lib/lane-issue.inc.sh"
  while IFS=$'\t' read -r id slug; do
    brief="$(SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" spl_spawn_place_brief "$slug")"
    [[ -n "$brief" ]] || continue
    e="$(li_brief_epic_spec "$brief" 2>/dev/null)"
    [[ -n "$e" && "${e#*$'\t'}" == "$1" ]] && out+="${out:+ }${id:0:8}"
  done < <(jq -r '.queue[]? | select((.placement // "") != "") | "\(.ask_id)\t\(.placement | sub("^[^:]*:"; ""))"' <<<"$rows" 2>/dev/null)
  printf '%s' "$out"
}
