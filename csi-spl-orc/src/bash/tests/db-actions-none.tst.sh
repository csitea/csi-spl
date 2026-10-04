#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 076 T008 follow-up, the callers of the db_dsn seam under
#          provider none. do_spl_db_bootstrap pins no GCP account and a fresh
#          env (no SPOOL_HUB_DB_DSN) seeds the self-host .env (mode 600, the
#          T009 seam) instead of Secret Manager. The other callers reach local
#          Postgres through spl_local_dsn and make 0 gcloud / curl /
#          cloud-sql-proxy / docker calls:
#            do_spl_consumer_lag, do_spl_db_message_show,
#            do_spl_db_period_count_check, do_spl_db_rls_check,
#            do_spl_hub_member_list, do_spl_db_compact,
#            do_spl_db_owner_split (split and ROTATE_OWNER),
#            _spl_tenant_create_cloud_dsn.
#          Control: under gcp, do_spl_consumer_lag still reaches the gcloud
#          token call and the cloud-sql-proxy stub (the stub exits, so the
#          action's rc is non-zero; the log is the proof). No fixture or
#          generated password in any output. spl_host_spool is overridden so
#          the test never builds the Go binary.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub" "$T/sh" "$T/home" "$T/state"
# SPOOL_STATE_DIR stays absent: session.key is then INFO, not a failed check.
printf '#!/bin/sh\necho "gcloud $*" >>"$STUB_LOG"\ncase "$*" in\n  *print-access-token*) echo tok ;;\n  *"auth list"*) echo sa@example.com ;;\n  *"secrets versions access"*) printf "%%s\\n" "$GCP_STUB_DSN" ;;\nesac\nexit 0\n' >"$T/stub/gcloud"
printf '#!/bin/sh\necho "cloud-sql-proxy $*" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/cloud-sql-proxy"
printf '#!/bin/sh\necho "docker $*" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/docker"
printf '#!/bin/sh\necho "curl $*" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/curl"
printf '#!/bin/sh\necho "spool $*" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/spool"
cat >"$T/stub/psql" <<'EOF'
#!/bin/sh
echo "psql $*" >>"$STUB_LOG"
in=$(cat)
blob="$in $*"
case "$blob" in
  *"NO FORCE ROW LEVEL SECURITY"*) echo "ERROR:  must be owner of table messages" >&2; exit 3 ;;
  *"TO CURRENT_USER"*) echo "ERROR:  permission denied to grant role" >&2; exit 3 ;;
  *message_period_counts*) echo '{"tenant_id":"t1","period_start":"2026-10-01","counter":1,"rows":1,"equal":true}' ;;
  *relrowsecurity*) echo '{"role":"rt","superuser":false,"bypassrls":false,"migration_0014":true,"migration_0021_fail_closed":true,"liftable":[],"tables":{"messages":[true,true]}}' ;;
  *tenant_memberships*) echo '{"type" : "member"}' ;;
  *body_len*) echo '{"msg_id":"m"}' ;;
  *oldest_age_s*) ;;
  *pg_stat_user_tables*) echo "messages | 1 | 0 | 8 kB | 16 kB | 0 bytes | 24 kB" ;;
  *pg_stat_activity*) echo 0 ;;
  *schema_create*) echo "$FACTS" ;;
esac
exit 0
EOF
chmod +x "$T/stub/"*

ALL="$T/all.out"
: >"$ALL"
RT='postgres://spool_hub_rt:none-fixture-pw@127.0.0.1:5432/spool_hub?sslmode=disable'
GOOD='{"role":"spool_hub_rt","superuser":false,"bypassrls":false,"createrole":false,"createdb":false,"member_of":0,"owns":0,"schema_create":false,"tenants":3}'
GCP_DSN='postgres://rt:gcp-fixture-secret@/cdb?host=/cloudsql/p:r:i'
if [[ -e "$APP_ROOT/.env" ]]; then WT_ENV_BEFORE=$(stat -c '%d:%i:%s' "$APP_ROOT/.env"); else WT_ENV_BEFORE=ABSENT; fi

seed_env() {
  printf "SPOOL_DB_OWNER='spool_hub'\nSPOOL_DB_OWNER_PASSWORD='none-fixture-pw'\nSPOOL_DB_NAME='spool_hub'\n" >"$T/sh/.env"
  chmod 600 "$T/sh/.env"
}

# run [VAR=value]... - every orc lib + action in a fresh bash. Stubs first on
# PATH. spl_host_spool stays a no-build. stdin is /dev/null so a psql stub
# that reads it cannot block.
run() {
  : >"$T/calls.log"
  env -u SPOOL_CLOUD_PROVIDER -u SPOOL_HUB_DB_DSN -u GCP_ACCOUNT \
    PATH="$T/stub:$PATH" HOME="$T/home" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" \
    SPL_STATE_DIR="$T/state" SPOOL_SELF_HOST_DIR="$T/sh" SPOOL_STATE_DIR="$T/absent-state" \
    STUB_LOG="$T/calls.log" FACTS="$GOOD" GCP_STUB_DSN="$GCP_DSN" ENV=dev "$@" \
    bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_host_spool() { SPL_SPOOL=$(command -v spool); }
    eval "$SNIPPET"' </dev/null
}

no_cloud() { # <label>
  if grep -qE '^(gcloud|curl|cloud-sql-proxy|docker) ' "$T/calls.log"; then
    fail "$1: a cloud call under none: $(tr '\n' ' ' <"$T/calls.log")"
  else
    pass "$1: no gcloud, curl, cloud-sql-proxy or docker call"
  fi
}
# rc0 <label> <out> <log-needle>
rc0() {
  local label="$1" out="$2" need="$3" bad
  bad=$(printf '%s\n' "$out" | grep -E '^(FATAL|ERROR|FAIL|RC=)' | sed -E 's/[0-9a-f]{24,}/[hex]/g' | sed -n '1,5p')
  grep -qx 'RC=0' <<<"$out" && pass "$label: rc 0" || fail "$label: ${bad:-no RC line}"
  grep -q "$need" "$T/calls.log" && pass "$label: reached $need" || fail "$label: call log has no $need"
  no_cloud "$label"
}

# --- bootstrap: fresh env, no runtime DSN ------------------------------------
rm -f "$T/sh/.env"
out=$(SNIPPET='DRY_RUN=0 do_spl_db_bootstrap; echo RC=$?' run SPOOL_CLOUD_PROVIDER=none 2>&1 | tee -a "$ALL")
rc0 "none bootstrap" "$out" "spool migrate"
mode=$(stat -c '%a' "$T/sh/.env" 2>/dev/null || echo missing)
grep -q '^SPOOL_HUB_DB_DSN=' "$T/sh/.env" && grep -q '^SPOOL_DB_OWNER_PASSWORD=' "$T/sh/.env" && [[ "$mode" == 600 ]] \
  && pass "none bootstrap: self-host .env is mode 600 and holds the runtime DSN and the owner password" \
  || fail "none bootstrap .env: mode=$mode"
python3 - "$T/sh/.env" "$ALL" "$T/calls.log" <<'PY' && pass "none bootstrap: no generated secret in the output or the call log" || fail "none bootstrap: a generated secret reached the output"
import pathlib, sys, urllib.parse
env, *outs = [pathlib.Path(p).read_text(errors="replace") for p in sys.argv[1:]]
blob = "\n".join(outs)
leaked = []
for line in env.splitlines():
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, val = line.split("=", 1)
    val = val.strip()
    if len(val) >= 2 and val[0] == val[-1] and val[0] in "'\"":
        val = val[1:-1]
    secrets = []
    if "PASSWORD" in key or key == "SPOOL_HUB_DB_DSN":
        if key == "SPOOL_HUB_DB_DSN":
            pw = urllib.parse.urlsplit(val).password or ""
            if pw:
                secrets.append(pw)
        elif len(val) >= 8:
            secrets.append(val)
    for s in secrets:
        if s in blob:
            leaked.append(key)
sys.exit(1 if leaked else 0)
PY

# --- the read-only callers ---------------------------------------------------
seed_env
for spec in \
  "consumer-lag|DRY_RUN=0 do_spl_consumer_lag; echo RC=\$?" \
  "message-show|TENANT_ID=acme do_spl_db_message_show; echo RC=\$?" \
  "period-count|TENANT_ID=acme do_spl_db_period_count_check; echo RC=\$?" \
  "rls-check|do_spl_db_rls_check; echo RC=\$?" \
  "hub-member-list|TENANT_ID=acme do_spl_hub_member_list; echo RC=\$?"
do
  name=${spec%%|*}
  snip=${spec#*|}
  seed_env
  out=$(SNIPPET="$snip" run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1 | tee -a "$ALL")
  rc0 "none $name" "$out" "^psql "
done

# --- compact (dry: still connects) and owner-split ---------------------------
seed_env
out=$(SNIPPET='DRY_RUN=1 do_spl_db_compact; echo RC=$?' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1 | tee -a "$ALL")
rc0 "none compact" "$out" "^psql "

seed_env
out=$(SNIPPET='DRY_RUN=0 do_spl_db_owner_split; echo RC=$?' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1 | tee -a "$ALL")
rc0 "none owner-split" "$out" "^psql "

seed_env
before=$(python3 -c 'import hashlib,pathlib,sys; t=pathlib.Path(sys.argv[1]).read_text();
[print(hashlib.sha256(l.split("=",1)[1].encode()).hexdigest()[:12]) for l in t.splitlines() if l.startswith("SPOOL_DB_OWNER_PASSWORD=")]' "$T/sh/.env")
out=$(SNIPPET='DRY_RUN=0 ROTATE_OWNER=1 do_spl_db_owner_split; echo RC=$?' run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1 | tee -a "$ALL")
rc0 "none owner-rotate" "$out" "^psql "
after=$(python3 -c 'import hashlib,pathlib,sys; t=pathlib.Path(sys.argv[1]).read_text();
[print(hashlib.sha256(l.split("=",1)[1].encode()).hexdigest()[:12]) for l in t.splitlines() if l.startswith("SPOOL_DB_OWNER_PASSWORD=")]' "$T/sh/.env")
[[ -n "$before" && -n "$after" && "$before" != "$after" ]] \
  && pass "none owner-rotate: the owner password in .env changed" \
  || fail "none owner-rotate: the owner password did not change"

# --- tenant-create helper (the action only calls it when the DSN is empty) ---
seed_env
out=$(SNIPPET='do_spl_cloud_cnf || { echo RC=$?; exit 0; }; proxied=0; _spl_tenant_create_cloud_dsn; rc=$?; if [[ "$dsn" == "$SPOOL_HUB_DB_DSN" ]]; then echo DSN-SAME; else echo DSN-DIFF; fi; echo "RC=$rc PROXIED=$proxied"' \
  run SPOOL_CLOUD_PROVIDER=none SPOOL_HUB_DB_DSN="$RT" 2>&1 | tee -a "$ALL")
grep -qx 'DSN-SAME' <<<"$out" && grep -qx 'RC=0 PROXIED=1' <<<"$out" \
  && pass "none tenant-create: the helper sets the local DSN and proxied=1, rc 0" \
  || fail "none tenant-create: $(printf '%s\n' "$out" | grep -E '^(FATAL|ERROR|FAIL|RC=|DSN-|PROXIED=)' | sed -n '1,8p')"
no_cloud "none tenant-create"

# --- control: gcp still reaches the proxy stub --------------------------------
mkdir -p "$T/home/.gcp/.csi"
printf '%s\n' '{"type":"service_account","client_email":"sa@example.com"}' >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
: >"$T/calls.log"
out=$(SNIPPET='do_spl_consumer_lag; echo RC=$?' run SPOOL_CLOUD_PROVIDER=gcp 2>&1 | tee -a "$ALL")
grep -q '^gcloud auth print-access-token' "$T/calls.log" && grep -q '^cloud-sql-proxy --address 127.0.0.1' "$T/calls.log" \
  && pass "control: under gcp consumer-lag reaches gcloud auth print-access-token and cloud-sql-proxy" \
  || fail "control gcp: $(tr '\n' ' ' <"$T/calls.log" | cut -c1-400) / $(printf '%s\n' "$out" | grep -E '^(FATAL|RC=)' | sed -n '1,3p')"

# --- nothing secret, and the worktree .env was not touched -------------------
if grep -qE 'none-fixture-pw|gcp-fixture-secret' "$ALL" "$T/calls.log"; then
  fail "a fixture secret reached the output or the call log"
else
  pass "no fixture secret in any output or call log"
fi
if [[ -e "$APP_ROOT/.env" ]]; then WT_ENV_AFTER=$(stat -c '%d:%i:%s' "$APP_ROOT/.env"); else WT_ENV_AFTER=ABSENT; fi
[[ "$WT_ENV_BEFORE" == "$WT_ENV_AFTER" ]] && pass "the worktree .env was not created or changed" || fail "the worktree .env changed ($WT_ENV_BEFORE -> $WT_ENV_AFTER)"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
