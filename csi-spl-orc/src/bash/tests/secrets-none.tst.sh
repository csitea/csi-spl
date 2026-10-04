#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 076 T006, the secrets seam under SPOOL_CLOUD_PROVIDER=none:
#          do_spl_secrets_check and do_spl_secrets_seed_all route through
#          do_spl_cloud_dispatch to the none adapters, which read and write
#          the self-host .env (mode 600) and <state dir>/session.key, in a temp
#          dir:
#          - check: no .env / an empty password / a public compose default /
#            a mode other than 600 / an empty session key -> exit 1; all set
#            -> exit 0; no state dir on this host is no failure.
#          - seed-all: the default dry run writes nothing; DRY_RUN=0 writes the
#            three Postgres passwords into .env (mode 600) and session.key
#            (mode 600), keeps every value and line already there, and a second
#            run changes nothing; an outside value (SMTP) is a NEED.
#          - no generated or fixture value in any output; a gcloud stub on PATH
#            records every call and the test fails on any (0 expected).
#          The gcp side stays secrets-check-seed-all.tst.sh, unchanged.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
mkdir -p "$T/bin" "$T/sh" "$T/state"
printf '#!/bin/sh\necho "gcloud $*" >>"%s"\nexit 1\n' "$T/gcloud.calls" >"$T/bin/gcloud"
chmod +x "$T/bin/gcloud"
ENVF="$T/sh/.env" KEYF="$T/state/session.key"
ALL="$T/all.out"

run_act() {  # <action> [VAR=value ...]
  local act="$1"; shift
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" \
      SPOOL_CLOUD_PROVIDER=none SPOOL_SELF_HOST_DIR="$T/sh" SPOOL_STATE_DIR="$T/state" ACT="$act" "$@" bash -c '
    set -uo pipefail
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_log() { echo "$*"; }
    "$ACT"' 2>&1 | tee -a "$ALL"
  return "${PIPESTATUS[0]}"
}
val() { grep -E "^$1=" "$ENVF" | tail -n 1 | sed -E "s/^[^=]+=//; s/^'(.*)'\$/\\1/"; }
mode() { stat -c '%a' "$1"; }
PW=(SPOOL_DB_OWNER_PASSWORD SPOOL_DB_RUNTIME_PASSWORD SPOOL_DB_SUPERUSER_PASSWORD)

# ------------------------------------------------------------------ check ----
out=$(run_act do_spl_secrets_check); rc=$?
[[ $rc -eq 1 ]] && grep -q "^MISSING $ENVF" <<<"$out" && grep -q '^EMPTY   session.key (required)' <<<"$out" &&
  pass "check: no .env and no session.key -> exit 1, each named" || fail "check empty: rc=$rc $out"

# --------------------------------------------------------------- seed-all ----
out=$(run_act do_spl_secrets_seed_all); rc=$?
[[ $rc -eq 0 && ! -e "$ENVF" && ! -e "$KEYF" ]] && grep -q '^OK DRY_RUN.*4 secret(s) would be generated' <<<"$out" &&
  pass "seed-all: the default is a dry run, nothing written" || fail "seed-all dry: rc=$rc $out"

out=$(run_act do_spl_secrets_seed_all DRY_RUN=0); rc=$?
ok=1; for k in "${PW[@]}"; do [[ "$(val "$k")" =~ ^[0-9a-f]{48}$ ]] || ok=0; done
[[ $rc -eq 0 && $ok -eq 1 ]] && grep -q '^OK every required self-host secret is set' <<<"$out" &&
  pass "seed-all: DRY_RUN=0 writes the 3 Postgres passwords into .env and the check then passes" || fail "seed-all real: rc=$rc $out"
[[ "$(mode "$ENVF")" == 600 ]] && pass "seed-all: .env is mode 600" || fail ".env mode $(mode "$ENVF")"
[[ "$(cat "$KEYF")" =~ ^[0-9a-f]{64}$ && "$(mode "$KEYF")" == 600 ]] &&
  pass "seed-all: session.key is 32 random bytes, hex, mode 600" || fail "session.key shape/mode $(mode "$KEYF")"

sum="$(md5sum "$ENVF" "$KEYF")"
out=$(run_act do_spl_secrets_seed_all DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(md5sum "$ENVF" "$KEYF")" == "$sum" ]] && [[ $(grep -c '^KEEP' <<<"$out") -eq 4 ]] &&
  pass "seed-all: a second run keeps every value (4 KEEP, files unchanged)" || fail "seed-all re-run: rc=$rc $out"

# an existing .env: other lines and a value kept, a loose mode fixed, SMTP asked
rm -f "$ENVF" "$KEYF"
printf "SPOOL_DOMAIN='chat.example.com'\nSPOOL_DB_OWNER_PASSWORD='kept-owner-fixture'\nSPOOL_MAIL_TRANSPORT=smtp\n" >"$ENVF"
chmod 644 "$ENVF"
out=$(run_act do_spl_secrets_check); rc=$?
[[ $rc -eq 1 ]] && grep -q "^MODE    $ENVF is 644" <<<"$out" && grep -q '^EMPTY   SPOOL_MAIL_SMTP_PASSWORD (required' <<<"$out" &&
  grep -q '^OK      SPOOL_DB_OWNER_PASSWORD' <<<"$out" &&
  pass "check: mode 644 and an empty SMTP password under smtp -> exit 1; a set password is OK" || fail "check partial: rc=$rc $out"
out=$(run_act do_spl_secrets_seed_all DRY_RUN=0); rc=$?
[[ $rc -eq 1 && "$(val SPOOL_DB_OWNER_PASSWORD)" == kept-owner-fixture && "$(val SPOOL_DOMAIN)" == chat.example.com && "$(mode "$ENVF")" == 600 ]] &&
  [[ "$(val SPOOL_DB_RUNTIME_PASSWORD)" =~ ^[0-9a-f]{48}$ ]] && grep -q '^NEED SPOOL_MAIL_SMTP_PASSWORD' <<<"$out" && [[ -z "$(val SPOOL_MAIL_SMTP_PASSWORD)" ]] &&
  pass "seed-all: keeps lines and values, fills the rest, mode 600, SMTP is a NEED (exit 1), never invented" || fail "seed-all partial: rc=$rc $out $(cut -d= -f1 "$ENVF")"

# a public compose default is a failure the seed does not paper over
sed -i "s/^SPOOL_DB_OWNER_PASSWORD=.*/SPOOL_DB_OWNER_PASSWORD=spool-local-owner/; s/^SPOOL_MAIL_TRANSPORT=.*/SPOOL_MAIL_TRANSPORT=log/" "$ENVF"
out=$(run_act do_spl_secrets_seed_all DRY_RUN=0); rc=$?
[[ $rc -eq 1 && "$(val SPOOL_DB_OWNER_PASSWORD)" == spool-local-owner ]] && grep -q '^DEFAULT SPOOL_DB_OWNER_PASSWORD' <<<"$out" &&
  grep -q '^NEED SPOOL_DB_OWNER_PASSWORD is the public compose default' <<<"$out" && grep -q '^INFO    SPOOL_MAIL_SMTP_PASSWORD (optional)' <<<"$out" &&
  pass "seed-all: a compose default is reported, not replaced (exit 1); SMTP optional off smtp" || fail "seed-all default: rc=$rc $out"

# no state dir on this host: hub-init owns the key, no failure
sed -i "s/^SPOOL_DB_OWNER_PASSWORD=.*/SPOOL_DB_OWNER_PASSWORD='kept-owner-fixture'/" "$ENVF"
out=$(run_act do_spl_secrets_check SPOOL_STATE_DIR="$T/absent"); rc=$?
[[ $rc -eq 0 && ! -e "$T/absent" ]] && grep -q '^INFO    session.key: no state dir' <<<"$out" &&
  pass "check: no state dir on this host is no failure (hub-init mints the key)" || fail "check no state dir: rc=$rc $out"

# --------------------------------------------------------------- no leaks ----
leak=0
for v in kept-owner-fixture "$(cat "$KEYF")" "$(val SPOOL_DB_RUNTIME_PASSWORD)" "$(val SPOOL_DB_SUPERUSER_PASSWORD)"; do
  [[ -n "$v" ]] && grep -qF -- "$v" "$ALL" && leak=$((leak + 1))
done
[[ $leak -eq 0 ]] && pass "no secret value in any output ($(wc -l <"$ALL") lines read)" || fail "$leak secret value(s) printed"
[[ ! -e "$T/gcloud.calls" ]] && pass "provider none: 0 gcloud calls" || fail "gcloud called: $(cat "$T/gcloud.calls")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
