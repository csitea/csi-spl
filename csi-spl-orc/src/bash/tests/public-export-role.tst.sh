#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the public dataset logins (spec 091 T004, fence 1):
#   do_spl_public_export_secret_seed
#     1. DRY_RUN (default) adds nothing; a bad ROTATE is refused before a call
#     2. DRY_RUN=0 on missing slots: creates both (user-managed, cnf region),
#        adds one minted 48-hex password each via --data-file=- (stdin), the
#        two differ; a re-run adds nothing; ROTATE=1 adds a new one and
#        disables the older versions
#   do_spl_public_export_role
#     3. DRY_RUN (default) calls no cloud; a stale grants file is refused
#        before any call; empty slots are refused naming the seed, no psql
#     4. DRY_RUN=0: AS THE OWNER applies public-export-role.sql, then
#        public-export-grants.sql, then public-names-role.sql (each password a
#        SCRAM verifier on stdin), writes public_export_workspace = the cnf
#        workspace, reads every flag back, and probes AS each login: OK
#     5. FAIL (exit 1) on: an extra column grant, a BYPASSRLS login, a
#        PUBLIC table grant, a wrong workspace row, a withheld read that is
#        NOT refused; VERIFY_ONLY=1 applies nothing
#   6. no clear-text password in output, any argv or psql stdin; every
#      gcloud secrets call carries --account
# gcloud and psql are stubbed and record every call; the secret store is a
# directory of numbered versions.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v yq >/dev/null && command -v jq >/dev/null || { echo "SKIP: no yq / jq"; exit 0; }

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
EXPORT_SLOT=$(yq -r '.env.public_dataset.export_password_secret' "$CNF/all.env.yaml")
NAMES_SLOT=$(yq -r '.env.public_dataset.names_password_secret' "$CNF/all.env.yaml")
OWNER_SLOT=$(yq -r '.env.hub.db_owner_dsn_secret' "$CNF/all.env.yaml")
WS=$(yq -r '.env.public_dataset.workspace_id' "$CNF/dev.env.yaml")
GRANTS="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/public-export-grants.sql"
OWNER_PW="ownerpw$RANDOM$RANDOM"
OWNER_DSN="postgres://spool_hub:$OWNER_PW@/spool?host=/cloudsql/csi-spl-dev:europe-north1:csi-spl-dev-pg"
mkdir -p "$T/home/.gcp/.csi" "$T/stub"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"

# secret store: $SEC/<id>/<n>, $SEC/<id>/<n>.disabled; a slot exists when its dir does
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
sec_of() { for a; do [[ "$a" == --secret=* ]] && echo "${a#--secret=}"; done; }
latest() { ls "$SEC/$1" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1; }
case "$*" in
  "auth activate-service-account"*) for a; do [[ "$a" == --key-file=* ]] && jq -r .client_email "${a#*=}" >"$CLOUDSDK_CONFIG/active"; done ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "auth print-access-token"*) echo ya29.stub_token_value_long_enough ;;
  "secrets create "*) mkdir -p "$SEC/$3"; echo "CREATE $3" >>"$STUB_LOG" ;;
  "secrets versions access latest"*) s=$(sec_of "$@"); n=$(latest "$s"); [[ -n "$n" ]] && cat "$SEC/$s/$n" || exit 1 ;;
  "secrets versions add "*) s="$4"; [[ -d "$SEC/$s" ]] || exit 1; [[ " $* " == *" --data-file=- "* ]] || exit 9
    n=$(( $(latest "$s" || echo 0) + 1 )); cat >"$SEC/$s/$n"; echo "ADD $s $n" >>"$STUB_LOG" ;;
  "secrets versions list "*) s="$4"; [[ -d "$SEC/$s" ]] || exit 1
    for n in $(ls "$SEC/$s" 2>/dev/null | grep -E '^[0-9]+$' | sort -rn); do [[ -e "$SEC/$s/$n.disabled" ]] || echo "$n"; done ;;
  "secrets versions disable "*) s=$(sec_of "$@"); touch "$SEC/$s/$4.disabled"; echo "DISABLE $s $4" >>"$STUB_LOG" ;;
esac
exit 0
EOF
# psql: records the login (PGUSER) and stdin; answers the facts query from
# $FACTS; refuses withheld reads like Postgres unless $LEAK names the probe
cat >"$T/stub/psql" <<'EOF'
#!/usr/bin/env bash
in=$(cat); { echo "psql as=$PGUSER"; printf '%s\n' "$in"; } >>"$T_STDIN"
case "$in" in
  *"CREATE ROLE spool_public_export"*) echo "APPLY export-role as=$PGUSER" >>"$STUB_LOG" ;;
  *"GENERATED, do not edit"*)          echo "APPLY grants as=$PGUSER" >>"$STUB_LOG" ;;
  *"CREATE ROLE spool_public_names"*)  echo "APPLY names-role as=$PGUSER" >>"$STUB_LOG" ;;
  *"INSERT INTO public_export_workspace"*) echo "WS $(grep -oE "set ws '[^']*'" <<<"$in") as=$PGUSER" >>"$STUB_LOG" ;;
  *json_build_object*) echo "$FACTS" ;;
  *)
    probe=$(sed -n 2p <<<"$in")
    echo "PROBE as=$PGUSER $probe" >>"$STUB_LOG"
    [[ -n "${LEAK:-}" && "$probe" == *"$LEAK"* ]] && { echo 1; exit 0; }
    case "$probe" in
      *"SELECT msg "*|*"SELECT email "*|*"SELECT root_pubkey "*|*password_credentials*|*"FROM channels"*|*"FROM public_export_workspace"*)
        echo "ERROR:  permission denied for table x" >&2; exit 3 ;;
    esac
    echo 1 ;;
esac
exit 0
EOF
chmod +x "$T/stub/"*

# the facts a correct apply reads back (export columns from the grants file)
good_facts() {
  python3 - "$GRANTS" "$WS" <<'PY'
import json, re, sys
cols = []
for c, t in re.findall(r"^GRANT SELECT \(([^)]*)\) ON (\w+) TO spool_public_export;$", open(sys.argv[1]).read(), re.M):
    cols += ["%s.%s:SELECT" % (t, x.strip()) for x in c.split(",")]
role = lambda cols, tables: dict(login=True, superuser=False, bypassrls=False, createrole=False, createdb=False,
                                 inherit=False, replication=False, member_of=0, owns=0, tables=tables, columns=sorted(cols))
print(json.dumps({"workspace": [sys.argv[2]], "public_grants": [], "roles": {
    "spool_public_export": role(cols, ["public_export_workspace:SELECT"]),
    "spool_public_names": role(["tenants.tenant_id:SELECT", "tenants.display_name:SELECT"], [])}}))
PY
}
GOOD=$(good_facts)
facts_with() { jq -c "$1" <<<"$GOOD"; }

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    T_STDIN="$T/stdin" SEC="$T/sec" FACTS="${FACTS:-$GOOD}" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}
seed_owner() { rm -rf "$T/sec"; mkdir -p "$T/sec/$OWNER_SLOT"; printf '%s' "$OWNER_DSN" >"$T/sec/$OWNER_SLOT/1"; }
newest() { local f b n=0; for f in "$T/sec/$1"/*; do b="${f##*/}"; [[ "$b" =~ ^[0-9]+$ ]] && (( b > n )) && n=$b; done; (( n > 0 )) && cat "$T/sec/$1/$n"; }
cnt() { local n; n=$(grep -c -- "$1" "$T/calls.log" 2>/dev/null); echo "${n:-0}"; }
line() { grep -n -m1 -F "$1" "$T/calls.log" | cut -d: -f1; }

# --- 1. seed: dry run + flags ---------------------------------------------------
seed_owner; in_orc do_spl_public_export_secret_seed; rc=$?
[[ $rc -eq 0 && $(cnt 'CREATE ') -eq 0 && $(cnt 'ADD ') -eq 0 ]] && grep -q '^OK DRY_RUN nothing was touched' "$T/out" &&
  grep -q "would create the slot and add a new spool_public_export password to $EXPORT_SLOT" "$T/out" &&
  pass "1. seed DRY_RUN: names both slots, creates and adds nothing" || fail "1. seed dry: rc=$rc $(cat "$T/out")"
seed_owner; in_orc do_spl_public_export_secret_seed DRY_RUN=0 ROTATE=yes; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "1. seed ROTATE=yes refused before any call" || fail "1. ROTATE=yes: rc=$rc"

# --- 2. seed: create, add, re-run, rotate -----------------------------------------
seed_owner; in_orc do_spl_public_export_secret_seed DRY_RUN=0; rc=$?
e1=$(newest "$EXPORT_SLOT"); n1=$(newest "$NAMES_SLOT")
[[ $rc -eq 0 && $(cnt 'CREATE ') -eq 2 && $(cnt 'ADD ') -eq 2 ]] && grep -q '^OK public dataset login passwords for dev' "$T/out" &&
  pass "2. seed DRY_RUN=0: both slots created, one version each, OK" || fail "2. seed real: rc=$rc $(cat "$T/out")"
grep -q -- '--replication-policy=user-managed --locations=europe-north1' <<<"$(grep -F "secrets create $EXPORT_SLOT" "$T/calls.log")" &&
  pass "2. the slot is created user-managed in the cnf region" || fail "2. create argv: $(grep 'secrets create' "$T/calls.log")"
[[ "$e1" =~ ^[0-9a-f]{48}$ && "$n1" =~ ^[0-9a-f]{48}$ && "$e1" != "$n1" ]] &&
  pass "2. each password is 48 minted hex chars, and the two differ" || fail "2. password shape"
in_orc do_spl_public_export_secret_seed DRY_RUN=0; rc=$?
[[ $rc -eq 0 && $(cnt 'ADD ') -eq 0 && $(cnt 'CREATE ') -eq 0 && "$(newest "$EXPORT_SLOT")" == "$e1" ]] &&
  pass "2. a re-run adds nothing" || fail "2. re-run: rc=$rc $(cat "$T/calls.log")"
in_orc do_spl_public_export_secret_seed DRY_RUN=0 ROTATE=1; rc=$?
[[ $rc -eq 0 && $(cnt 'ADD ') -eq 2 && $(cnt 'DISABLE ') -eq 2 && "$(newest "$EXPORT_SLOT")" != "$e1" ]] &&
  pass "2. ROTATE=1: a new password each, the older versions disabled" || fail "2. rotate: rc=$rc $(cat "$T/calls.log")"
SEED_OUT="$(cat "$T/out" "$T/calls.log")"

# --- 3. role: dry run + refusals --------------------------------------------------------
in_orc do_spl_public_export_role; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] && grep -q '^OK DRY_RUN nothing was touched' "$T/out" && grep -q "set public_export_workspace to $WS" "$T/out" &&
  pass "3. role DRY_RUN: no cloud call, names the workspace" || fail "3. role dry: rc=$rc $(cat "$T/out" "$T/calls.log")"
in_orc 'do_spl_public_export_grants_gen() { echo "FAIL stale"; return 1; }; do_spl_public_export_role' DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && pass "3. a stale grants file is refused before any call" || fail "3. stale: rc=$rc"
saved="$T/sec.saved"; rm -rf "$saved"; cp -r "$T/sec" "$saved"; rm -rf "$T/sec/$NAMES_SLOT"
in_orc do_spl_public_export_role DRY_RUN=0; rc=$?
[[ $rc -ne 0 && $(cnt 'APPLY') -eq 0 ]] && grep -q "FATAL $NAMES_SLOT has no readable version: run .*do_spl_public_export_secret_seed" "$T/out" &&
  pass "3. an empty slot is refused naming the seed, no SQL run" || fail "3. empty slot: rc=$rc $(cat "$T/out")"
rm -rf "$T/sec"; cp -r "$saved" "$T/sec"

# --- 4. role: apply + verify ----------------------------------------------------------------
in_orc do_spl_public_export_role DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q "^OK public dataset logins on spool (dev)" "$T/out" && pass "4. role DRY_RUN=0: exit 0, OK" || fail "4. role: rc=$rc $(cat "$T/out")"
a=$(line 'APPLY export-role as=spool_hub'); g=$(line 'APPLY grants as=spool_hub'); n=$(line 'APPLY names-role as=spool_hub'); w=$(line "WS set ws '$WS' as=spool_hub")
[[ -n "$a" && -n "$g" && -n "$n" && -n "$w" && $a -lt $g && $g -lt $n && $n -lt $w ]] &&
  pass "4. as the owner: export role, grants, names role, then the workspace row $WS" || fail "4. order: $(cat "$T/calls.log")"
grep -qE '^\\set export_verifier .SCRAM-SHA-256[$]4096:' "$T/stdin" && grep -qE '^\\set names_verifier .SCRAM-SHA-256[$]4096:' "$T/stdin" &&
  pass "4. both passwords reach psql as SCRAM verifiers on stdin" || fail "4. verifiers not on stdin"
for want in 'OK spool_public_export: login, noinherit' 'OK spool_public_names: login, noinherit' "OK public_export_workspace = $WS" \
            'OK PUBLIC holds no table or column privilege' 'OK refused as spool_public_export: SELECT msg FROM messages' \
            'OK refused as spool_public_export: SELECT email FROM humans' 'OK refused as spool_public_export: SELECT count(*) FROM password_credentials' \
            'OK spool_public_names reads: ' 'OK refused as spool_public_names: SELECT root_pubkey FROM tenants'; do
  grep -qF "$want" "$T/out" || fail "4. missing line: $want"
done
[[ $(cnt 'PROBE as=spool_public_export ') -eq 5 && $(cnt 'PROBE as=spool_public_names ') -eq 4 ]] &&
  pass "4. every flag read back, 5 probes as the export login and 4 as the names login" || fail "4. probes: $(grep PROBE "$T/calls.log")"

# --- 5. role: each defect FAILs ----------------------------------------------------------------
for c in '.roles.spool_public_export.columns += ["messages.msg:SELECT"]|extra column grant messages.msg' \
         '.roles.spool_public_names.bypassrls = true|spool_public_names: bypassrls' \
         '.roles.spool_public_export.inherit = true|spool_public_export: inherit' \
         '.roles.spool_public_export.owns = 1|owns=1' \
         '.public_grants = ["humans:SELECT"]|PUBLIC holds 1 privilege' \
         '.workspace = ["t9"]|public_export_workspace holds'; do
  FACTS=$(facts_with "${c%%|*}") in_orc do_spl_public_export_role DRY_RUN=0; rc=$?
  [[ $rc -ne 0 ]] && grep -q "FAIL .*${c#*|}" "$T/out" && pass "5. FAIL on: ${c#*|}" || fail "5. not caught: ${c%%|*}: rc=$rc $(grep -E 'OK|FAIL' "$T/out")"
done
in_orc do_spl_public_export_role DRY_RUN=0 LEAK='SELECT msg FROM messages'; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FAIL spool_public_export ran what it must not: SELECT msg FROM messages' "$T/out" &&
  pass "5. FAIL when a withheld read is not refused" || fail "5. leak: rc=$rc $(cat "$T/out")"
in_orc do_spl_public_export_role DRY_RUN=0 VERIFY_ONLY=1; rc=$?
[[ $rc -eq 0 && $(cnt 'APPLY') -eq 0 && $(cnt 'WS ') -eq 0 && $(cnt 'PROBE') -eq 9 ]] &&
  pass "5. VERIFY_ONLY=1 applies nothing and still verifies" || fail "5. verify only: rc=$rc $(cat "$T/calls.log")"

# --- 6. no leak; every gcloud call pinned --------------------------------------------------------------
in_orc do_spl_public_export_role DRY_RUN=0
leak=0
for pw in "$OWNER_PW" "$(newest "$EXPORT_SLOT")" "$(newest "$NAMES_SLOT")"; do
  grep -qF "$pw" "$T/out" "$T/calls.log" "$T/stdin" <<<"$SEED_OUT" && leak=1
  grep -qF "$pw" <<<"$SEED_OUT" && leak=1
done
(( leak == 0 )) && pass "6. no clear-text password in output, any argv or psql stdin" || fail "6. a password leaked"
# (the pin's own auth list / activate-service-account run in its throwaway CLOUDSDK_CONFIG)
[[ $(grep '^gcloud|secrets' "$T/calls.log" | grep -vc -- '--account=') -eq 0 && $(grep -c '^gcloud|secrets' "$T/calls.log") -gt 0 ]] &&
  pass "6. every gcloud secrets call carries --account" || fail "6. unpinned: $(grep '^gcloud|secrets' "$T/calls.log" | grep -v -- '--account=')"

[[ $fails -eq 0 ]] && { echo "PASS: all public-export-role.tst.sh assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in public-export-role.tst.sh"; exit 1
