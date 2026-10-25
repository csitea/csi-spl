#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: three small gcloud actions, offline (test round 2 row 10,
#          SPL-2724): each refuses a missing mandatory input before it calls
#          gcloud, and calls gcloud only as the pinned identity, in a private
#          CLOUDSDK_CONFIG that is removed afterwards.
#   do_gcp_sync_local_to_s3
#   1. one `storage rsync`, always --dry-run, dest gs://<org>-<app>-<env>-bucket,
#      src <APP_PATH>/<org>-<app>-dat/src/web/html/ or SRC_DIR, --account=<SA>
#   2. ENV / ORG / APP empty -> refused, no `storage` call
#   3. no key, no ACCOUNT -> refused, no `storage` call
#  3b. a failing `storage rsync` -> the action's rc is not 0 (SPL-2731)
#   do_gcp_sync_s3_to_local
#  3c. a failing `storage rsync` -> the action's rc is not 0, logged (SPL-2737)
#   do_gcp_tail_logs
#   4. ENV=dev: activates the dev key, one `logging read` with the defaults,
#      --project=<org>-<app>-dev and --account=<the dev SA>
#   5. SEVERITY + FILTER + FORMAT=json reach the call
#   6. ENV=all: dev, tst, prd in order; a missing key skips that env only
#   7. ENV empty -> refused; ENV=qa -> refused; no `logging` call either way
#   do_satellite_image_latest
#   8. prints the newest debian-13 image; pin newest -> OK, older -> WARN;
#      --project=debian-cloud --account=<the cnf project SA>
#   9. no gcloud on PATH / no key / no gcp_project / no boot_disk_image /
#      a failing describe -> refused, rc 1
#  10. every gcloud call in a private CLOUDSDK_CONFIG, removed afterwards;
#      ~/.config/gcloud untouched; aws and curl never called
#  11. CONTROL: the checks of 1, 2, 7 and 8 catch planted copies that drop
#      --dry-run, default ENV, accept any ENV, or drop --account
#   account order (SPL-3260): ORG and APP NOT set, derived from the project
#   dir as ./run does, only the per-env keys on disk (no key-<org>-<app>-all)
#  12. tail ENV=prd: the prd SA from its key, its identity logged before the
#      logging read; master resolved the account before ORG/APP and refused
#  13. tail ENV=all: each env resolved and logged as its own SA; with a
#      one-project pin (GCP_SA_KEY_FILE) refused, no logging call
#  14. do_gcp_import_to_cloudsql: same order, the dev SA logged before it
#      refuses a missing SERVICE_KEY_FILE (no storage / secrets call)
# gcloud, aws and curl are stubs on PATH. No network, no GCP, no S3.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v jq >/dev/null || { echo "SKIP: no jq"; exit 0; }
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
for a in gcp-sync-local-to-s3 gcp-sync-s3-to-local gcp-tail-logs satellite-image-latest; do require_action "$RUN/$a.func.sh"; done

SA() { echo "csi-spl-$1@csi-spl-$1.iam.gserviceaccount.com"; }
mkdir -p "$T/home/.gcp/.csi" "$T/stub" "$T/tmp" "$T/empty"
for e in dev tst prd all; do
  printf '{"type":"service_account","client_email":"%s"}\n' "$(SA "$e")" >"$T/home/.gcp/.csi/key-csi-spl-$e.json"
done
SAT_CNF="$T/prd.env.yaml"
sat_cnf() { # sat_cnf <gcp_project> <boot_disk_image>; an empty value is left out
  { echo 'env:'; echo '  steps:'; echo '    060-gcp-vm-satellite:'
    [[ -n "$1" ]] && echo "      gcp_project: $1"
    [[ -n "$2" ]] && echo "      boot_disk_image: $2"; } >"$SAT_CNF"
}

# stub gcloud: logs "<CLOUDSDK_CONFIG>|<argv>"; activate needs a real key file
# and records its email as the active one; STUB_FAIL=<word> fails the call
# whose argv holds it; describe-from-family prints $STUB_LATEST
cat >"$T/stub/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
[[ -n "${STUB_FAIL:-}" && "$*" == *"$STUB_FAIL"* ]] && exit 1
case "$*" in
  "auth activate-service-account"*)
    k=$(arg --key-file "$@"); [[ -f "$k" ]] || exit 1
    jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "compute images describe-from-family"*) echo "${STUB_LATEST:-debian-13-trixie-v20261001}" ;;
  "logging read"*) echo "LOGLINE $(arg --project "$@")" ;;
esac
exit 0
EOF
for n in aws curl; do printf '#!/usr/bin/env bash\necho "<net>|%s $*" >>"$STUB_LOG"; exit 99\n' "$n" >"$T/stub/$n"; done
chmod +x "$T/stub/"*

# act <action file> <function> [VAR=value ...] -> rc; output in $T/out, calls
# in $T/calls.log, private config dirs land in $T/tmp. Runs in a fresh bash:
# do_require_var exits the shell it runs in.
act() {
  local file="$1" fn="$2"; shift 2
  : >"$T/calls.log"; rm -rf "${T:?}/tmp"; mkdir -p "$T/tmp"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT \
    -u GCP_SA_KEY_FILE -u SRC_DIR -u LINES -u FRESHNESS -u SEVERITY -u FILTER -u FORMAT \
    HOME="$T/home" TMPDIR="$T/tmp" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" \
    PROJ_PATH="$PROJ_ROOT" ACT_FILE="$file" ACT_FN="$fn" APP_PATH="$T/app" \
    SATELLITE_CNF_FILE="$SAT_CNF" ORG=csi APP=spl ENV=dev "$@" /bin/bash -c '
    do_log() { echo "$*"; }
    quit_on() { rv=$?; if [ $rv -ne 0 ]; then echo "FATAL Error: Failed to $1"; exit $rv; fi; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$ACT_FILE"; do source "$f"; done
    "$ACT_FN"' >"$T/out" 2>&1
}
calls() { grep "|$1 " "$T/calls.log" | cut -d'|' -f2-; }
SYNC="$RUN/gcp-sync-local-to-s3.func.sh" TAIL="$RUN/gcp-tail-logs.func.sh" SAT="$RUN/satellite-image-latest.func.sh"
sync() { act "${SYNC_FILE:-$SYNC}" do_gcp_sync_local_to_s3 "$@"; }
tail_logs() { act "${TAIL_FILE:-$TAIL}" do_gcp_tail_logs "$@"; }
sat() { act "${SAT_FILE:-$SAT}" do_satellite_image_latest "$@"; }

# check_isolated -> why the last run's gcloud calls were not private; empty when they were
check_isolated() {
  local cfgs
  cfgs=$(grep -v '^<net>|' "$T/calls.log" | cut -d'|' -f1 | sort -u)
  [[ -n "$cfgs" ]] || { echo "no gcloud call"; return; }
  grep -qx -e '<unset>' -e "$T/home/.config/gcloud" <<<"$cfgs" && echo "a call in the shared config: $cfgs"
  [[ -z "$(ls -A "$T/tmp")" ]] || echo "private config left: $(ls -A "$T/tmp")"
  [[ ! -e "$T/home/.config/gcloud" ]] || echo "the shared HOME/.config/gcloud was written"
  grep -q '^<net>|' "$T/calls.log" && echo "network tool called: $(grep '^<net>|' "$T/calls.log")"
}
# check_sync <src> <sa> -> why the last sync run was not the pinned dry run; empty when it was
check_sync() {
  local s; s=$(calls storage)
  [[ "$s" == "storage rsync --delete-unmatched-destination-objects -r --dry-run -x .git/|wp-config.php $1 gs://csi-spl-dev-bucket --account=$2" ]] \
    || echo "rsync call: '$s'"
}
# check_refused <tool> <msg> -> why the last run was not a clean refusal; empty when it was
check_refused() {
  [[ $rc -ne 0 ]] || echo "rc=0"
  [[ -z "$(calls "$1")" ]] || echo "$1 called: $(calls "$1")"
  grep -q -- "$2" "$T/out" || echo "no '$2' in: $(cat "$T/out")"
}
# check_sat <image> -> why the last image run was not right; empty when it was
check_sat() {
  local c; c=$(calls compute)
  [[ $rc -eq 0 ]] || echo "rc=$rc"
  [[ "$c" == "compute images describe-from-family debian-13 --project=debian-cloud --account=$(SA all) --format=value(name)" ]] \
    || echo "describe call: '$c'"
  [[ "$(tail -1 "$T/out")" == "projects/debian-cloud/global/images/$1" ]] || echo "last line: $(tail -1 "$T/out")"
}

# --- 1. sync: the pinned dry run ---------------------------------------------
sync; rc=$?
bad=$(check_sync "$T/app/csi-spl-dat/src/web/html/" "$(SA dev)")
[[ $rc -eq 0 && -z "$bad" ]] && pass "1. sync: one rsync --dry-run of the dat html dir to gs://csi-spl-dev-bucket as the dev SA" \
  || fail "1. rc=$rc $bad $(cat "$T/out")"
grep -q "INFO gcloud project=<unset> account=$(SA dev) .*(do_gcp_sync_local_to_s3)" "$T/out" \
  && pass "1. sync: the identity log names the dev SA" || fail "1. $(grep 'gcloud project=' "$T/out")"
bad=$(check_isolated)
[[ -z "$bad" ]] && pass "10. sync: private config, removed; no aws/curl" || fail "10. sync: $bad"
sync SRC_DIR="$T/site/" ACCOUNT=ci@example.com; rc=$?
bad=$(check_sync "$T/site/" ci@example.com)
[[ $rc -eq 0 && -z "$bad" ]] && pass "1. sync: SRC_DIR and ACCOUNT override the source and the identity" || fail "1. override: $bad"

# --- 2./3. sync refusals --------------------------------------------------------
for v in ENV ORG APP; do
  sync "$v=" ACCOUNT=ci@example.com; rc=$?
  bad=$(check_refused storage "\"$v\" does not have a value")
  [[ -z "$bad" ]] && pass "2. sync: $v empty -> refused, no storage call" || fail "2. sync $v empty: $bad"
done
mv "$T/home/.gcp/.csi/key-csi-spl-dev.json" "$T/key.json"
sync; rc=$?
bad=$(check_refused storage 'no gcloud account')
[[ -z "$bad" ]] && pass "3. sync: no key, no ACCOUNT -> refused, no storage call" || fail "3. $bad"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-dev.json"
sync STUB_FAIL='storage rsync'; rc=$?
[[ $rc -ne 0 && -n "$(calls storage)" ]] && grep -q 'ERROR gcloud storage rsync failed' "$T/out" \
  && pass "3b. sync: a failing rsync -> rc $rc, logged" || fail "3b. failing rsync: rc=$rc $(cat "$T/out")"
act "$RUN/gcp-sync-s3-to-local.func.sh" do_gcp_sync_s3_to_local STUB_FAIL='storage rsync'; rc=$?
[[ $rc -ne 0 && -n "$(calls storage)" ]] && grep -q 'ERROR gcloud storage rsync failed' "$T/out" \
  && pass "3c. s3-to-local: a failing rsync -> rc $rc, logged" || fail "3c. s3-to-local failing rsync: rc=$rc $(cat "$T/out")"

# --- 4. tail: ENV=dev, the defaults ----------------------------------------------
tail_logs; rc=$?
r=$(calls logging)
want="logging read --project=csi-spl-dev --limit=50 --freshness=1h --order=desc --format=value(timestamp,severity,textPayload,jsonPayload.message) --account=$(SA dev) --project=csi-spl-dev"
[[ $rc -eq 0 && "$r" == "$want" ]] && grep -q 'OK Done for dev' "$T/out" \
  && pass "4. tail: one logging read with the defaults as the dev SA, project csi-spl-dev" || fail "4. rc=$rc '$r' $(cat "$T/out")"
calls auth | grep -x -- "auth activate-service-account --key-file=$T/home/.gcp/.csi/key-csi-spl-dev.json --quiet" >/dev/null \
  && pass "4. tail: activates the dev key in the private config" || fail "4. auth: $(calls auth)"
bad=$(check_isolated)
[[ -z "$bad" ]] && pass "10. tail: private config, removed; no aws/curl" || fail "10. tail: $bad"

# --- 5. tail: severity, filter, format ---------------------------------------------
tail_logs SEVERITY=ERROR FILTER='resource.type="cloud_run_revision"' FORMAT=json LINES=7 FRESHNESS=6h; rc=$?
r=$(calls logging)
want="logging read --project=csi-spl-dev --limit=7 --freshness=6h --order=desc --format=json severity>=ERROR resource.type=\"cloud_run_revision\" --account=$(SA dev) --project=csi-spl-dev"
[[ $rc -eq 0 && "$r" == "$want" ]] && pass "5. tail: SEVERITY, FILTER, FORMAT, LINES and FRESHNESS reach the call" || fail "5. '$r'"

# --- 6. tail: ENV=all, a missing key skips one env ---------------------------------
mv "$T/home/.gcp/.csi/key-csi-spl-tst.json" "$T/key.json"
tail_logs ENV=all; rc=$?
got=$(calls logging | grep -o 'read --project=[a-z-]*' | cut -d= -f2 | paste -sd' ')
accts=$(calls logging | grep -o -- '--account=[^ ]*' | cut -d= -f2 | paste -sd' ')
[[ $rc -eq 0 && "$got" == "csi-spl-dev csi-spl-prd" && "$accts" == "$(SA dev) $(SA prd)" ]] \
  && grep -q "no key at $T/home/.gcp/.csi/key-csi-spl-tst.json) — skipping tst" "$T/out" \
  && pass "6. tail: ENV=all reads dev and prd, each as its own SA; tst without a key is skipped" \
  || fail "6. rc=$rc projects='$got' accounts='$accts' $(cat "$T/out")"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-tst.json"

# --- 7. tail refusals ------------------------------------------------------------------
tail_logs ENV= ACCOUNT=ci@example.com; rc=$?
bad=$(check_refused logging '"ENV" does not have a value')
[[ -z "$bad" ]] && pass "7. tail: ENV empty -> refused, no logging call" || fail "7. ENV empty: $bad"
tail_logs ENV=qa ACCOUNT=ci@example.com; rc=$?
bad=$(check_refused logging 'ENV must be one of: dev, tst, prd, all')
[[ -z "$bad" ]] && pass "7. tail: ENV=qa -> refused, no logging call" || fail "7. ENV=qa: $bad"

# --- 8. satellite image: newest vs pinned ----------------------------------------------
sat_cnf csi-spl-all projects/debian-cloud/global/images/debian-13-trixie-v20261001
sat; rc=$?
bad=$(check_sat debian-13-trixie-v20261001)
[[ -z "$bad" ]] && grep -q '^OK the pin is the newest image' "$T/out" \
  && pass "8. image: pin = newest -> OK, prints the image, as the csi-spl-all SA" || fail "8. $bad $(cat "$T/out")"
grep -q "INFO gcloud project=csi-spl-all account=$(SA all)" "$T/out" \
  && pass "8. image: the identity log names the cnf project and its SA" || fail "8. $(grep 'gcloud project=' "$T/out")"
bad=$(check_isolated)
[[ -z "$bad" ]] && pass "10. image: private config, removed; no aws/curl" || fail "10. image: $bad"
sat STUB_LATEST=debian-13-trixie-v20261015; rc=$?
bad=$(check_sat debian-13-trixie-v20261015)
[[ -z "$bad" ]] && grep -q '^WARN the pin is not the newest image' "$T/out" \
  && pass "8. image: pin older than newest -> WARN, prints the newest" || fail "8. older: $bad $(cat "$T/out")"

# --- 9. satellite image refusals -------------------------------------------------------
sat PATH="$T/empty"; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'FATAL gcloud is not installed' "$T/out" \
  && pass "9. image: no gcloud on PATH -> refused" || fail "9. no gcloud: rc=$rc $(cat "$T/out")"
mv "$T/home/.gcp/.csi/key-csi-spl-all.json" "$T/key.json"
sat; rc=$?
bad=$(check_refused compute 'no gcloud account')
[[ -z "$bad" ]] && pass "9. image: no key, no ACCOUNT -> refused, no compute call" || fail "9. no key: $bad"
mv "$T/key.json" "$T/home/.gcp/.csi/key-csi-spl-all.json"
sat_cnf "" projects/debian-cloud/global/images/debian-13-trixie-v20261001
sat; rc=$?
bad=$(check_refused compute 'gcp_project is not set')
[[ -z "$bad" ]] && pass "9. image: no cnf gcp_project -> refused, no compute call" || fail "9. no project: $bad"
sat_cnf csi-spl-all ""
sat; rc=$?
[[ $rc -ne 0 ]] && grep -q 'boot_disk_image is not set' "$T/out" \
  && pass "9. image: no cnf boot_disk_image -> refused" || fail "9. no pin: rc=$rc $(cat "$T/out")"
sat_cnf csi-spl-all projects/debian-cloud/global/images/debian-13-trixie-v20261001
sat STUB_FAIL=describe-from-family; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL cannot read the debian-13 family' "$T/out" \
  && pass "9. image: a failing describe -> refused" || fail "9. describe fails: rc=$rc $(cat "$T/out")"

# --- 11. CONTROL: the checks see planted breaks -----------------------------------------
plant() { # plant <name> <action> <sed expr>
  sed "$3" "$2" >"$T/$1.func.sh"
  cmp -s "$2" "$T/$1.func.sh" && fail "11. CONTROL: the $1 plant matched nothing in the action"
}
plant no-dry-run "$SYNC" 's/ -r --dry-run / -r /'
plant sync-env-default "$SYNC" 's/do_require_var ENV \${ENV:-}/ENV="${ENV:-dev}"/'
plant tail-any-env "$TAIL" 's/^    dev|tst|prd|all) ;;$/    *) ;;/'
plant sat-no-account "$SAT" 's/ *--account="\${GCP_ACCOUNT}"//'
SYNC_FILE="$T/no-dry-run.func.sh" sync; rc=$?
[[ -n "$(check_sync "$T/app/csi-spl-dat/src/web/html/" "$(SA dev)")" ]] \
  && pass "11. CONTROL: a sync copy without --dry-run fails check 1" || fail "11. CONTROL: check 1 is blind to a dropped --dry-run"
SYNC_FILE="$T/sync-env-default.func.sh" sync ENV= ACCOUNT=ci@example.com; rc=$?
[[ -n "$(check_refused storage '"ENV" does not have a value')" ]] \
  && pass "11. CONTROL: a sync copy that defaults ENV fails check 2" || fail "11. CONTROL: check 2 is blind to a defaulted ENV"
TAIL_FILE="$T/tail-any-env.func.sh" tail_logs ENV=qa ACCOUNT=ci@example.com; rc=$?
[[ -n "$(check_refused logging 'ENV must be one of: dev, tst, prd, all')" ]] \
  && pass "11. CONTROL: a tail copy that accepts any ENV fails check 7" || fail "11. CONTROL: check 7 is blind to an unchecked ENV"
SAT_FILE="$T/sat-no-account.func.sh" sat; rc=$?
[[ -n "$(check_sat debian-13-trixie-v20261001)" ]] \
  && pass "11. CONTROL: an image copy that drops --account fails check 8" || fail "11. CONTROL: check 8 is blind to a dropped --account"

# --- 12..14. account resolved AFTER ORG / APP / ENV (SPL-3260) --------------------------
# ORG= APP= : do_resolve_oap derives both from PROJ_PATH, as under ./run.
# idline <project> <sa> <fn> -> the line number of that identity log in $T/out
idline() { grep -n "INFO gcloud project=$1 account=$2 .*($3)" "$T/out" | sed -n 1p | cut -d: -f1; }
mv "$T/home/.gcp/.csi/key-csi-spl-all.json" "$T/key-all.json"
tail_logs ORG= APP= ENV=prd LINES=1; rc=$?
r=$(calls logging)
want="logging read --project=csi-spl-prd --limit=1 --freshness=1h --order=desc --format=value(timestamp,severity,textPayload,jsonPayload.message) --account=$(SA prd) --project=csi-spl-prd"
[[ $rc -eq 0 && "$r" == "$want" ]] \
  && pass "12. tail: ORG/APP derived, ENV=prd -> one logging read as the prd SA" || fail "12. rc=$rc '$r' $(cat "$T/out")"
id=$(idline csi-spl-prd "$(SA prd)" do_gcp_tail_logs); ll=$(grep -n '^LOGLINE' "$T/out" | sed -n 1p | cut -d: -f1)
[[ -n "$id" && -n "$ll" && "$id" -lt "$ll" ]] \
  && pass "12. tail: the identity line names csi-spl-prd and its SA, before the first log line" \
  || fail "12. identity line=${id:-none} first log=${ll:-none}: $(grep 'gcloud project=' "$T/out")"
tail_logs ORG= APP= ENV=all; rc=$?
got=$(calls logging | grep -o 'read --project=[a-z-]*' | cut -d= -f2 | paste -sd' ')
accts=$(calls logging | grep -o -- '--account=[^ ]*' | cut -d= -f2 | paste -sd' ')
ids=0; for e in dev tst prd; do [[ -n "$(idline "csi-spl-$e" "$(SA "$e")" do_gcp_tail_logs)" ]] && ids=$((ids+1)); done
[[ $rc -eq 0 && "$got" == "csi-spl-dev csi-spl-tst csi-spl-prd" && "$accts" == "$(SA dev) $(SA tst) $(SA prd)" && $ids -eq 3 ]] \
  && pass "13. tail: ENV=all, no -all key: each env resolved and logged as its own SA" \
  || fail "13. rc=$rc projects='$got' accounts='$accts' identity lines=$ids $(cat "$T/out")"
tail_logs ORG= APP= ENV=all GCP_SA_KEY_FILE="$T/home/.gcp/.csi/key-csi-spl-dev.json"; rc=$?
bad=$(check_refused logging 'name one project: set ENV to one env')
[[ -z "$bad" ]] && pass "13. tail: ENV=all with GCP_SA_KEY_FILE -> refused, no logging call" || fail "13. pin: $bad"
act "$RUN/gcp-import-to-cloudsql.func.sh" do_gcp_import_to_cloudsql ORG= APP= ENV=dev \
  SERVICE_KEY_FILE="$T/no-such-key.json" GS_UTIL_URI=gs://csi-spl-dev-backups/x.sql; rc=$?
[[ $rc -ne 0 && -n "$(idline csi-spl-dev "$(SA dev)" do_gcp_import_to_cloudsql)" && -z "$(calls storage)$(calls secrets)" ]] \
  && grep -q 'The service key file does not exist' "$T/out" \
  && pass "14. import: ORG/APP derived -> the dev SA logged, then refused on SERVICE_KEY_FILE, no storage/secrets call" \
  || fail "14. rc=$rc $(cat "$T/out")"
mv "$T/key-all.json" "$T/home/.gcp/.csi/key-csi-spl-all.json"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
