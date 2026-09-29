#!/bin/bash
#------------------------------------------------------------------------------
# @description Mark a native (email + password) credential's email as verified
# @description in a cloud env's hub DB, through the Cloud SQL proxy as the env's
# @description project service account. The native flow verifies an address by
# @description consuming a mailed token (rdb 0009); an address at a domain whose
# @description mail nobody here can open (a Meta app-review test account at
# @description facebook.com) can never verify itself, so a login stays 403
# @description email_unverified. This operator action does what the mail link
# @description would: it sets password_credentials.email_verified_at = now().
# @description
# @description It REFUSES unless the credential exists AND is still unverified,
# @description so it can neither create an account nor silently re-stamp a
# @description live one. password_credentials is hub-wide, keyed (provider =
# @description 'password', subject = lower(email)); the statement has no tenant
# @description scope. The email travels as a psql variable (:'email'), never
# @description spliced into the SQL. Exactly one row must change, or the
# @description transaction rolls back. Who (the OS user + the pinned SA) and
# @description when (the server timestamp) are logged; no secret is printed.
# @description DRY_RUN=1 (default): print the plan, call no cloud.
# @param ENV - required: dev or prd
# @param EMAIL - required: the credential's address (lower-cased; 3..320 chars, per 0009)
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd EMAIL=facebook-test-user@facebook.com DRY_RUN=0 ./run -a do_spl_native_email_verify
#------------------------------------------------------------------------------
do_spl_native_email_verify() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local email="${EMAIL:-}" dry=1
  email="${email,,}"
  # 0009 password_credentials CHECK: subject = lower(subject) AND length 3..320,
  # and it is an address. A conservative local shape catches typos before any call.
  [[ "$email" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ && ${#email} -ge 3 && ${#email} -le 320 ]] ||
    { do_log "FATAL EMAIL must be a lower-cased address of 3..320 chars, got: '${EMAIL:-}'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( dry )); then
    do_log "OK DRY_RUN would mark $email verified in the $ENV hub DB on $SPL_SQL_CONN (only if it exists and is unverified). Re-run with DRY_RUN=0."
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_native_email_verify_run "$email"
}

_spl_native_email_verify_run() {
  local email="$1" out who
  who="$(id -un 2>/dev/null || echo unknown)/$GCP_ACCOUNT"
  # One transaction: refuse a missing or already-verified credential (each a
  # ROLLBACK), else stamp exactly the one unverified row. present/unverified are
  # 0|1 so psql \if reads them. The address only ever travels as :'email'.
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v email="$email" <<'SQL'
BEGIN;
SELECT (EXISTS (SELECT 1 FROM password_credentials WHERE provider = 'password' AND subject = :'email'))::int AS present,
       (EXISTS (SELECT 1 FROM password_credentials WHERE provider = 'password' AND subject = :'email'
                 AND email_verified_at IS NULL))::int AS unverified \gset
\if :present
  \if :unverified
    UPDATE password_credentials
       SET email_verified_at = now(), updated_at = now()
     WHERE provider = 'password' AND subject = :'email' AND email_verified_at IS NULL
    RETURNING format('VERIFIED %s | %s', subject, email_verified_at);
    SELECT :ROW_COUNT = 1 AS one \gset
    \if :one
COMMIT;
    \else
ROLLBACK;
    \endif
  \else
    \echo ALREADY_VERIFIED
ROLLBACK;
  \endif
\else
  \echo NOT_FOUND
ROLLBACK;
\endif
SQL
)" || { do_log "FATAL email-verify of $email failed: $out"; return 1; }
  case "$out" in
    *NOT_FOUND*)        do_log "FATAL no password credential for $email in the $ENV hub DB: refusing (this action verifies, it does not create)"; return 1 ;;
    *ALREADY_VERIFIED*) do_log "FATAL $email is already verified in the $ENV hub DB: refusing (nothing to do)"; return 1 ;;
  esac
  local n
  n="$(grep -c '^VERIFIED ' <<<"$out")"
  (( n == 1 )) || { do_log "FATAL $n row(s) matched $email: rolled back"; return 1; }
  do_log "OK $email email_verified_at set by $who: ${out#VERIFIED }"
}
