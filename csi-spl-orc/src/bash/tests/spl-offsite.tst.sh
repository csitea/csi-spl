#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the off-project backups (iac 046, spec 044 T077/T078), offline:
#   1. do_spl_backup_offsite while cnf copy_enabled is false: exit 0 and a
#      line that says why (the daily workflow stays green);
#      SPL_OFFSITE_REQUIRED=1 turns it into exit 2
#   2. enabled + DRY_RUN (default): counts what the copy lacks, runs no rsync
#   3. CONTROL: DRY_RUN=0 runs `rsync --no-clobber` per part and passes when
#      every source name then is in the copy; when rsync "succeeds" but a name
#      is still missing it is exit 3 - the name check is the verdict
#   4. never a delete flag: no rsync call carries --delete-unmatched
#   5. do_spl_files_restore: the guard (bad SOURCE/TARGET, env->env, prd
#      without ALLOW_PRD_RESTORE=1) and SOURCE=bkp without the csi-spl-bkp key
#      is a refusal that names the bootstrap
#   6. every gcloud call in the three files is pinned with --account
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  *"print-access-token"*) head -c 1024 /dev/zero | tr '\0' 'x'; echo; exit 0 ;;
  *"storage ls gs://csi-spl-dev-db-backups/dev/**"*)
    printf 'gs://csi-spl-dev-db-backups/dev/spool-1.sql.gz\ngs://csi-spl-dev-db-backups/dev/spool-2.sql.gz\n' ;;
  *"storage ls gs://csi-spl-dev-files/**"*)
    printf 'gs://csi-spl-dev-files/t/t1/files/aa\ngs://csi-spl-dev-files/t/t2/files/bb\n' ;;
  *"storage ls gs://csi-spl-bkp-dev/dev/db/**"*)    [ -f "$T/dst-db" ] && cat "$T/dst-db" ;;
  *"storage ls gs://csi-spl-bkp-dev/dev/files/**"*) [ -f "$T/dst-files" ] && cat "$T/dst-files" ;;
  *"storage rsync gs://csi-spl-dev-db-backups/dev gs://csi-spl-bkp-dev/dev/db"*)
    [ "$RSYNC" = works ] && printf 'gs://csi-spl-bkp-dev/dev/db/spool-1.sql.gz\ngs://csi-spl-bkp-dev/dev/db/spool-2.sql.gz\n' >"$T/dst-db" ;;
  *"storage rsync gs://csi-spl-dev-files gs://csi-spl-bkp-dev/dev/files"*)
    [ "$RSYNC" = works ] && printf 'gs://csi-spl-bkp-dev/dev/files/t/t1/files/aa\ngs://csi-spl-bkp-dev/dev/files/t/t2/files/bb\n' >"$T/dst-files"
    [ "$RSYNC" = short ] && printf 'gs://csi-spl-bkp-dev/dev/files/t/t1/files/aa\n' >"$T/dst-files" ;;
esac
exit 0
STUB
chmod +x "$T/stub/gcloud"

PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };'
ENABLE='eval "$(declare -f do_spl_cloud_cnf | sed 1s/do_spl_cloud_cnf/_orig_cnf/)"; do_spl_cloud_cnf(){ _orig_cnf || return 1; yq -i ".env.steps.\"046-gcs-offsite-backups\".copy_enabled = true" "$SPL_CNF"; };'

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" T="$T" \
    RSYNC="${RSYNC:-works}" HOME="$T/home" PATH="$T/stub:$PATH" ENV="${ENV_:-dev}" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}
reset() { : >"$T/calls.log"; rm -f "$T/dst-db" "$T/dst-files"; }

# --- 1. disabled -----------------------------------------------------------------
reset
o=$(SNIPPET="$PIN do_spl_backup_offsite" in_orc DRY_RUN=0 2>&1); rc=$?
(( rc == 0 )) && pass "copy_enabled=false: exit 0 (workflow 45 stays green)" || fail "disabled rc=$rc: $o"
grep -q 'not enabled yet' <<<"$o" && pass "it says why nothing was copied" || fail "disabled text: $o"
grep -q 'storage' "$T/calls.log" && fail "disabled still touched storage" || pass "disabled: no storage call"
SNIPPET="$PIN do_spl_backup_offsite" in_orc SPL_OFFSITE_REQUIRED=1 >/dev/null 2>&1
(( $? == 2 )) && pass "SPL_OFFSITE_REQUIRED=1: disabled is exit 2" || fail "required did not exit 2"

# --- 2. enabled, dry run -------------------------------------------------------------
reset
o=$(SNIPPET="$PIN $ENABLE do_spl_backup_offsite" in_orc 2>&1); rc=$?
(( rc == 0 )) && pass "enabled dry run: exit 0" || fail "dry rc=$rc: $o"
grep -q '2 source object(s), 2 missing' <<<"$o" && pass "it counts what the copy lacks" || fail "counts: $o"
grep -q 'storage rsync' "$T/calls.log" && fail "DRY_RUN=1 ran rsync" || pass "DRY_RUN=1: no rsync"

# --- 3. CONTROL: the copy, and the name check as verdict -------------------------------
reset
o=$(SNIPPET="$PIN $ENABLE do_spl_backup_offsite" in_orc DRY_RUN=0 2>&1); rc=$?
(( rc == 0 )) && pass "CONTROL: DRY_RUN=0 copies and passes the name check" || fail "copy rc=$rc: $o"
[[ $(grep -c 'storage rsync .*--no-clobber' "$T/calls.log") == 2 ]] && pass "one no-clobber rsync per part (db, files)" ||
  fail "rsync calls: $(grep rsync "$T/calls.log")"
reset
o=$(RSYNC=short SNIPPET="$PIN $ENABLE do_spl_backup_offsite" in_orc DRY_RUN=0 2>&1); rc=$?
(( rc == 3 )) && pass "rsync 'succeeds' but a file is missing: exit 3" || fail "short copy rc=$rc: $o"
grep -q 't/t2/files/bb' <<<"$o" && pass "the refusal names the first missing object" || fail "short text: $o"

# --- 4. never a delete -----------------------------------------------------------------
grep -q -- '--delete' "$T/calls.log" "$PROJ_ROOT/src/bash/run/spl-backup-offsite.func.sh" &&
  fail "a delete flag appears in the copy" || pass "the copy never deletes (no --delete-unmatched)"

# --- 5. do_spl_files_restore guard ------------------------------------------------------
for a in 'SOURCE=nope' 'TARGET=nope' 'SOURCE=env TARGET=env' 'TARGET=local:../x'; do
  # shellcheck disable=SC2086
  o=$(SNIPPET="$PIN do_spl_files_restore" in_orc $a 2>&1) && fail "$a was accepted: $o" || pass "files restore refuses $a"
done
o=$(ENV_=prd SNIPPET="$PIN do_spl_files_restore" in_orc TARGET=env SPL_STATE_DIR="$T/state-prd" 2>&1) &&
  fail "prd TARGET=env without the flag was accepted" || pass "files restore: prd TARGET=env needs ALLOW_PRD_RESTORE=1"
grep -q 'ALLOW_PRD_RESTORE=1' <<<"$o" && pass "the refusal names the flag" || fail "prd text: $o"
mkdir -p "$T/home"
o=$(SNIPPET="$PIN do_spl_files_restore" in_orc SOURCE=bkp 2>&1) && fail "SOURCE=bkp without a key was accepted: $o" ||
  pass "SOURCE=bkp without the csi-spl-bkp key is refused"
grep -q 'ENV=bkp do_gcp_000_bootstrap_gcp_env' <<<"$o" && pass "the refusal names the bootstrap that mints the key" || fail "key text: $o"
reset
o=$(SNIPPET="$PIN do_spl_files_restore" in_orc SOURCE=env 2>&1); rc=$?
(( rc == 0 )) && grep -q 'objects=2' <<<"$o" && pass "CONTROL: SOURCE=env dry run counts 2 objects" || fail "files dry rc=$rc: $o"
grep -q 'storage rsync' "$T/calls.log" && fail "files DRY_RUN=1 ran rsync" || pass "files DRY_RUN=1: no rsync"

# --- 6. --account everywhere -------------------------------------------------------------
for f in src/bash/run/spl-backup-offsite.func.sh src/bash/run/spl-files-restore.func.sh lib/bash/funcs/spl-offsite.func.sh; do
  bad=$(sed -e ':a' -e '/\\$/{N;s/\\\n//;ba' -e '}' "$PROJ_ROOT/$f" |
        grep -E '(^|[^_[:alnum:]])gcloud[[:space:]]' | grep -vE '^[[:space:]]*#' |
        grep -v 'do_require_bin' | grep -v 'spl_bkp_gcloud' | grep -v -- '--account')
  [[ -z "$bad" ]] && pass "$(basename "$f"): every gcloud call carries --account" || fail "unpinned gcloud in $f: $bad"
done

(( fails == 0 )) && echo "OK spl-offsite: all checks passed" || { echo "FAIL spl-offsite: $fails check(s)"; exit 1; }
