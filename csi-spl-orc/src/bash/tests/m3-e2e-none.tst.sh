#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 076, do_spl_m3_e2e under provider none makes NO gcloud call.
#          The relay password for IMAP is SPOOL_MAIL_SMTP_PASSWORD of the
#          self-host .env (0600 file, in no output) and the invite reaches
#          local Postgres through spl_db_runtime_local, the helper the
#          db-actions-none callers use. The gcloud and cloud-sql-proxy shims
#          FAIL on any call, so a gcloud path reached under none turns the run
#          red as well as the call log. m3-e2e.py is replaced by a function
#          (auth-check exit 3 until M3_INVITED=1) and spl_host_spool never
#          builds. Control: under gcp spl_m3_imap_pass still reaches the
#          gcloud shim.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 97 gcloud cloud-sql-proxy docker curl
orc_stub 0 spool
mkdir -p "$T/sh" "$T/home" "$T/tenants"
RT='postgres://spool_hub_rt:none-fixture-pw@127.0.0.1:5432/spool_hub?sslmode=disable'
printf "SPOOL_MAIL_SMTP_PASSWORD='none-relay-s3cret'\n" >"$T/sh/.env"
chmod 600 "$T/sh/.env"
printf '%s\n' '{"tenant":"e2e","root_private_key":"none-root-key-fixture"}' >"$T/tenants/e2e.20261005T000000Z.json"

run() {
  : >"$T/calls.log"
  env -u SPOOL_CLOUD_PROVIDER -u SPOOL_HUB_DB_DSN -u GCP_ACCOUNT \
    PATH="$T/stub:$PATH" HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" SPL_TENANTS_DIR="$T/tenants" SPOOL_SELF_HOST_DIR="$T/sh" \
    STUB_LOG="$T/calls.log" ENV=prd M3_NOTIFY_CMD= "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_host_spool() { SPL_SPOOL=$(command -v spool); }
    python3() {
      if [[ "${1-}" == *m3-e2e.py ]]; then
        echo "m3py $2 invited=${M3_INVITED:-0} pass=$(cat "$M3_IMAP_PASS_FILE" 2>/dev/null) mode=$(stat -c %a "$M3_IMAP_PASS_FILE" 2>/dev/null)" >>"$STUB_LOG"
        [[ "$2" == auth-check && -z "${M3_INVITED:-}" ]] && return 3
        return 0
      fi
      command python3 "$@"
    }
    eval "$SNIPPET"' </dev/null
}

# --- the whole action, prd test tenant, under none ---------------------------
out=$(SNIPPET='do_spl_m3_e2e; echo RC=$?' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1)
grep -qx 'RC=0' <<<"$out" && pass "none m3-e2e: rc 0" \
  || fail "none m3-e2e: $(printf '%s\n' "$out" | grep -E '^(FATAL|FAIL|RC=)' | sed -n '1,5p')"
if grep -qE '^(gcloud|cloud-sql-proxy|docker|curl) ' "$T/calls.log"; then
  fail "none m3-e2e: a cloud call: $(grep -E '^(gcloud|cloud-sql-proxy|docker|curl) ' "$T/calls.log" | tr '\n' ' ')"
else
  pass "none m3-e2e: no gcloud, cloud-sql-proxy, docker or curl call"
fi
grep -q '^spool hub-invite --tenant e2e --email .*+spl-e2e-.* --role owner$' "$T/calls.log" \
  && pass "none m3-e2e: the owner human is invited through local Postgres" \
  || fail "none m3-e2e: no hub-invite: $(tr '\n' ' ' <"$T/calls.log")"
grep -q '^m3py auth-check invited=1 pass=none-relay-s3cret mode=600$' "$T/calls.log" \
  && pass "none m3-e2e: the IMAP password is the self-host .env value, in a 0600 file" \
  || fail "none m3-e2e: IMAP pass file: $(grep '^m3py' "$T/calls.log" | sed 's/pass=[^ ]*/pass=[x]/' | tr '\n' ' ')"
grep -q '^m3py run ' "$T/calls.log" && pass "none m3-e2e: the run step is reached" || fail "none m3-e2e: no run step"
[[ ! -e "$T/state/m3-e2e/e2e/imap-pass" ]] && pass "none m3-e2e: the IMAP pass file is removed after the run" \
  || fail "none m3-e2e: imap-pass left behind"

# --- none with no SMTP password in the .env: stops before any call -----------
printf "SPOOL_DB_NAME='spool_hub'\n" >"$T/sh/.env"
out2=$(SNIPPET='do_spl_m3_e2e; echo RC=$?' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1)
grep -q 'FATAL no SPOOL_MAIL_SMTP_PASSWORD' <<<"$out2" && ! grep -qx 'RC=0' <<<"$out2" && ! grep -q '^gcloud ' "$T/calls.log" \
  && pass "none m3-e2e: no SMTP password in .env stops with FATAL, no gcloud" \
  || fail "none m3-e2e without a password: $(printf '%s\n' "$out2" | grep -E '^(FATAL|RC=)' | sed -n '1,3p')"
printf "SPOOL_MAIL_SMTP_PASSWORD='none-relay-s3cret'\n" >"$T/sh/.env"

# --- control: under gcp the relay password still comes from gcloud ----------
mkdir -p "$T/home/.gcp/.csi" "$T/ctl"
printf '%s\n' '{"type":"service_account","client_email":"sa@example.com"}' >"$T/home/.gcp/.csi/key-csi-spl-prd.json"
out3=$(SNIPPET="do_spl_cloud_cnf && spl_m3_imap_pass $T/ctl/pass; echo RC=\$?" run SPOOL_CLOUD_PROVIDER=gcp GCP_ACCOUNT=sa@example.com 2>&1)
grep -q '^gcloud secrets versions access latest ' "$T/calls.log" && ! grep -qx 'RC=0' <<<"$out3" \
  && pass "control: under gcp spl_m3_imap_pass reaches the gcloud shim (which fails)" \
  || fail "control gcp: $(tr '\n' ' ' <"$T/calls.log") / $(grep -E '^(FATAL|RC=)' <<<"$out3" | sed -n '1,3p')"

# --- nothing secret in any output ---------------------------------------------
if grep -qE 'none-relay-s3cret|none-fixture-pw|none-root-key-fixture' <<<"$out$out2$out3"; then
  fail "a fixture secret reached the output"
else
  pass "no fixture secret in any output"
fi

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
