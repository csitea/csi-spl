#!/bin/bash
#------------------------------------------------------------------------------
# Shared half of the named rollbacks do_hub_rollback / do_wui_rollback
# (SPL-2131, robustness gap 4: "no documented way to revert to a previous
# version after a bad deploy"). Both point an env back at a release it served
# before, without a rebuild and without touching the deploy workflows:
#   - the target: TO=<v-tag | trunk sha | previous | a component's own id>,
#     resolved to the commit it was built from; an unknown target is refused
#   - dev equals or leads prd: a prd rollback is refused unless dev already
#     serves the same commit (ENV_ORDER_OVERRIDE=<owner msg id> for an
#     emergency, the terraform rule's override)
#   - the schema: migrations are forward-only, so an older hub runs on a newer
#     schema; the migrations newer than the target are listed and a
#     non-additive one refuses the hub rollback (ROLLBACK_SCHEMA_OK=1 after
#     reading it)
# The commit/tag half reuses spl-local-deploy.func.sh (spl_ld_trunk,
# spl_ld_served) and spl-release-version.func.sh (the release key rules).
#------------------------------------------------------------------------------

# Non-additive DDL: an older hub reading or writing what these remove or
# tighten fails per request. A heuristic over the file text (comments
# stripped), not a proof: the action lists every newer migration so a person
# reads them, and this list only decides which of them REFUSE by default.
SPL_RB_DDL_BREAKING='drop[[:space:]]+(table|column|view|materialized[[:space:]]+view|function|type|schema)[[:space:]]|rename[[:space:]]+(column|to)[[:space:]]|set[[:space:]]+not[[:space:]]+null|alter[[:space:]]+column[^;]*[[:space:]]type[[:space:]]'
# A new constraint may refuse a row an older hub writes (a CHECK of allowed
# values that dropped one); usually it only widens a CHECK, so it is listed
# for a read, not refused: 10 of the 40 newest migrations add one (0160-0199).
SPL_RB_DDL_WARN='add[[:space:]]+constraint'

# spl_rb_fetch -> fetch the trunk and the v-tags, so a tag or sha resolves
spl_rb_fetch() {
  local remote="${RELEASE_REMOTE:-origin}"
  git -C "$APP_PATH" fetch -q --tags "$remote" "$(spl_ld_trunk)" 2>/dev/null ||
    { do_log "FATAL cannot fetch $remote $(spl_ld_trunk) and its tags" >&2; return 1; }
}

# spl_rb_commit_of <to> -> the full trunk sha a v-tag or a sha names.
# rc 2: not that form (nothing logged), rc 3: that form but unknown or not on
# the trunk (FATAL logged).
spl_rb_commit_of() {
  local to="$1" sha remote="${RELEASE_REMOTE:-origin}"
  if [[ "$to" =~ ^v[0-9]\.[0-9]\.[0-9](-c[0-9]+)?$ ]]; then
    sha="$(git -C "$APP_PATH" rev-parse -q --verify "refs/tags/$to^{commit}")" ||
      { do_log "FATAL unknown target: no release tag $to (git ls-remote --tags origin 'v*' lists them)" >&2; return 3; }
  elif [[ "$to" =~ ^[0-9a-f]{7,40}$ ]]; then
    sha="$(git -C "$APP_PATH" rev-parse -q --verify "$to^{commit}")" ||
      { do_log "FATAL unknown target: no commit $to" >&2; return 3; }
  else
    return 2
  fi
  git -C "$APP_PATH" merge-base --is-ancestor "$sha" "$remote/$(spl_ld_trunk)" ||
    { do_log "FATAL unknown target: ${sha:0:12} is not on $remote/$(spl_ld_trunk)" >&2; return 3; }
  printf '%s' "$sha"
}

# spl_rb_key_of <sha> -> the release key (the hub image tag) of the newest
# v-tag on <sha>; rc 1, nothing printed, when the commit was never released
spl_rb_key_of() {
  local k
  k="$(git -C "$APP_PATH" tag --points-at "$1" 'v*' | sed 's/^v//' |
    while read -r t; do spl_release_key_valid "$t" && echo "$t"; done | spl_release_key_max)"
  [[ -n "$k" ]] || return 1
  printf '%s' "$k"
}

# spl_rb_sha_of_key <key> -> the commit the v-tag of <key> points at
spl_rb_sha_of_key() {
  git -C "$APP_PATH" rev-parse -q --verify "refs/tags/v$1^{commit}"
}

# spl_rb_dev_served <hub|wui> -> the commit dev serves (hub GET /version, wui
# GET <site>.web.app/build.json), read from dev's cnf whatever ENV is
spl_rb_dev_served() {
  local cnf="$APP_PATH/csi-spl-cnf/csi-spl/dev.env.json" host
  [[ -f "$cnf" ]] || { do_log "FATAL no dev cnf $cnf" >&2; return 1; }
  case "$1" in
    hub) host="$(jq -r '.env.dns.api_fqdn // ""' "$cnf")"
      [[ -n "$host" ]] && spl_ld_served "https://$host/version" commit ;;
    wui) host="$(jq -r '.env.steps."019-firebase-static-site".site_id // ""' "$cnf")"
      [[ -n "$host" ]] && spl_ld_served "https://$host.web.app/build.json?rb=$(date +%s)" commit ;;
  esac
}

# spl_rb_prd_gate <hub|wui> <sha> -> 0 for dev, and for prd when dev already
# serves <sha>; rc 4 (FATAL) otherwise. ENV_ORDER_OVERRIDE=<owner msg id> lets
# an emergency through, named in the log.
spl_rb_prd_gate() {
  local comp="$1" sha="$2" dev
  [[ "$ENV" == prd ]] || return 0
  if [[ -n "${ENV_ORDER_OVERRIDE:-}" ]]; then
    do_log "WARN prd $comp rollback without dev first: ENV_ORDER_OVERRIDE=$ENV_ORDER_OVERRIDE"
    return 0
  fi
  [[ -n "$sha" ]] || { do_log "FATAL prd refused: the target names no commit, so dev cannot be compared (use a v-tag or a sha)"; return 4; }
  dev="$(spl_rb_dev_served "$1")"
  if [[ "$dev" == "$sha" ]]; then
    echo "  order     dev already serves ${sha:0:12} (dev equals or leads prd)"
    return 0
  fi
  do_log "FATAL prd refused: dev $comp serves ${dev:-unknown}, not ${sha:0:12}; roll dev back to the same target first (ENV=dev TO=${TO:-})"
  return 4
}

# spl_rb_schema_check <target sha> <served sha> -> lists the migrations the
# served code has and the target lacks. rc 5 (FATAL) when one of them is
# non-additive (SPL_RB_DDL_BREAKING) and ROLLBACK_SCHEMA_OK is not 1. An
# unread served commit falls back to trunk head: no env's schema is ahead of
# trunk's migrations.
spl_rb_schema_check() {
  local to="$1" from="${2:-}" dir="${SPL_IMAGE_SQL_SRC:-csi-spl-rdb/src/sql/postgres/spool-hub}" f body
  [[ -n "$from" ]] || from="$(git -C "$APP_PATH" rev-parse "${RELEASE_REMOTE:-origin}/$(spl_ld_trunk)")"
  if [[ "$to" == "$from" ]] || git -C "$APP_PATH" merge-base --is-ancestor "$from" "$to"; then
    echo "  schema    the target is not older than ${from:0:12}: no newer migration to run over"
    return 0
  fi
  local -a files breaking=()
  mapfile -t files < <(git -C "$APP_PATH" diff --name-only --diff-filter=A "$to" "$from" -- "$dir" | sort)
  echo "  schema    ${#files[@]} migration(s) newer than the target stay applied (forward-only):"
  for f in "${files[@]}"; do
    body="$(git -C "$APP_PATH" show "$from:$f" | sed 's/--.*$//')"
    if grep -qiE "$SPL_RB_DDL_BREAKING" <<<"$body"; then
      breaking+=("$f"); echo "    BREAKING $f"
    elif grep -qiE "$SPL_RB_DDL_WARN" <<<"$body"; then
      echo "    read     $f (adds a constraint: can it refuse a row the older hub writes?)"
    else
      echo "    additive $f"
    fi
  done
  ((${#breaking[@]})) || return 0
  if [[ "${ROLLBACK_SCHEMA_OK:-0}" == 1 ]]; then
    do_log "WARN ROLLBACK_SCHEMA_OK=1: rolling back over ${#breaking[@]} non-additive migration(s)"
    return 0
  fi
  do_log "FATAL ${#breaking[@]} newer migration(s) drop, rename or tighten what the target's code may use: read them, then ROLLBACK_SCHEMA_OK=1 (or roll forward with a fix instead)"
  return 5
}

# spl_rb_hold_note <hub|wui> -> how long a rollback holds (printed after one)
spl_rb_hold_note() {
  echo "rollback $1 $ENV NOTE: this holds until the next $1 deploy. A push that changes a $1 input, or the"
  echo "  21 catch-up (every 15 min, once trunk's $1 is unserved past its grace), rolls $ENV forward again."
  echo "  Land the fix or a revert on master; to hold longer, disable 21 meanwhile (DEPLOY.md, Rollback)."
}
