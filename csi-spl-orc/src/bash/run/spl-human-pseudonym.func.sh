#!/bin/bash
#------------------------------------------------------------------------------
# @description Give one human a pseudonym in a cloud env's hub DB: set
# @description humans.display_name to DISPLAY_NAME and drop the picture, so
# @description the other members cannot tell who the person is. Through the
# @description Cloud SQL proxy as the env's project service account. humans
# @description and human_identities are hub-wide, outside row level security
# @description (rdb 0014), so the statement has no tenant scope.
# @description The picture: avatar_file_id and idp_avatar_file_id are cleared
# @description and avatar_own is set (rdb 0150), because a sign-in stores the
# @description IdP picture again unless avatar_own is true (Postgres.SetAvatar).
# @description A sign-in keeps a set display_name (COALESCE). The person can
# @description still rename themselves (PATCH /v1/me) or upload a picture:
# @description this action does not lock the pseudonym.
# @description EMAIL is resolved through human_identities to exactly one
# @description human, or the transaction is rolled back. Exactly one humans
# @description row must change, or it is rolled back. Values travel as psql
# @description variables (:'var'), never spliced into the SQL. The output
# @description names the human_id and the new name only, never the email or
# @description the old name. DRY_RUN=1 (default): print the change, call no
# @description cloud.
# @param ENV - required: dev or prd
# @param HUMAN_ID - a human id, e.g. HUM-4. Set this or EMAIL, not both.
# @param EMAIL - the human's email, resolved through human_identities to
# @param   exactly one human_id. Set this or HUMAN_ID, not both. Compared
# @param   lower-cased.
# @param DISPLAY_NAME - required: 1..200 characters after trimming, no
# @param   control or direction-override characters (auth.ValidDisplayName)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd HUMAN_ID=HUM-4 DISPLAY_NAME='FirstName LastName' DRY_RUN=0 ./run -a do_spl_human_pseudonym
#------------------------------------------------------------------------------
do_spl_human_pseudonym() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local human="${HUMAN_ID:-}" email="${EMAIL:-}" name dry=1 who
  if [[ -n "$human" && -n "$email" ]] || [[ -z "$human" && -z "$email" ]]; then
    do_log "FATAL set exactly one of HUMAN_ID or EMAIL"
    return 1
  fi
  if [[ -n "$human" ]]; then
    [[ "$human" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL HUMAN_ID must look like HUM-4"; return 1; }
    who="$human"
  else
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { do_log "FATAL EMAIL is not an email"; return 1; }
    email="${email,,}"
    who="the human with the given EMAIL"
  fi
  name="$(_spl_human_pseudonym_name "${DISPLAY_NAME:-}")" || {
    do_log "FATAL DISPLAY_NAME must be 1..200 characters, valid UTF-8, no control or direction-override characters"
    return 1
  }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would set the display name of $who to '$name' and drop the picture on $SPL_SQL_CONN. Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_human_pseudonym_run "$human" "$email" "$name"
}

# _spl_human_pseudonym_name <raw>: print the trimmed name, or fail - the rule
# of auth.ValidDisplayName (1..MaxDisplayNameLen=200 runes, valid UTF-8, no
# control, line/paragraph separator or direction-override runes).
_spl_human_pseudonym_name() {
  local LC_ALL=C.UTF-8 n="$1" bad i
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  LC_ALL=C.UTF-8 grep -qax -- '.*' <<<"$n" || return 1
  (( ${#n} >= 1 && ${#n} <= 200 )) || return 1
  [[ "$n" == *[[:cntrl:]]* ]] && return 1
  # U+2028 U+2029 U+061C U+200E U+200F U+202A..U+202E U+2066..U+2069
  bad="$(printf '%b' '\u2028\u2029\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069')"
  for (( i = 0; i < ${#bad}; i++ )); do
    [[ "$n" == *"${bad:i:1}"* ]] && return 1
  done
  printf '%s\n' "$n"
}

_spl_human_pseudonym_run() {
  local out rc=0 mark line n who="$1"
  [[ -n "$who" ]] || who="the human with the given EMAIL"
  out="$(_spl_human_pseudonym_sql |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
      -v human="$1" -v email="$2" -v name="$3")" || rc=$?
  # A refusal is read from the line the script printed: psql exits 0 on \quit.
  if mark="$(spl_psql_mark "$out" refuse-human)"; then
    do_log "FATAL the EMAIL matches $mark human(s) in human_identities; want exactly one: rolled back"
    return 1
  elif grep -q '^refuse-count$' <<<"$out"; then
    do_log "FATAL no humans row for $who: rolled back"
    return 1
  elif (( rc != 0 )); then
    do_log "FATAL pseudonym update of $who failed (psql rc $rc)"
    return 1
  fi
  n="$(grep -c '^set | ' <<<"$out" || true)"
  (( n == 1 )) || { do_log "FATAL $n row(s) changed for $who: rolled back"; return 1; }
  line="$(grep '^set | ' <<<"$out")"
  do_log "OK ${line#set | } ($GCP_ACCOUNT): display name set, picture dropped"
}

# _spl_human_pseudonym_sql: the one-transaction script - resolve EMAIL to
# exactly one human, then set the name and drop the picture on exactly one
# row, printing "set | <human_id> | <name>"; else roll back.
_spl_human_pseudonym_sql() {
  cat <<'SQL'
BEGIN;
SELECT CASE
         WHEN :'human' <> '' THEN 1
         ELSE (SELECT count(DISTINCT human_id)::int FROM human_identities WHERE email = :'email')
       END AS nhum \gset
SELECT (:nhum = 1)::int AS onehuman \gset
\if :onehuman
\else
ROLLBACK;
SELECT format('refuse-human | %s', :nhum);
\quit
\endif
SELECT CASE
         WHEN :'human' <> '' THEN :'human'
         ELSE (SELECT min(human_id) FROM human_identities WHERE email = :'email')
       END AS hid \gset
UPDATE humans SET display_name = :'name', avatar_file_id = NULL,
       avatar_own = true, idp_avatar_file_id = NULL
 WHERE human_id = :'hid'
RETURNING format('set | %s | %s', human_id, display_name);
SELECT (:ROW_COUNT = 1)::int AS one \gset
\if :one
COMMIT;
\else
ROLLBACK;
SELECT 'refuse-count';
\quit
\endif
SQL
}
