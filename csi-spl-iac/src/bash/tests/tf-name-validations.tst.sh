#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 072 A8 - the steps' name validations are each resource's own id
#          rule, not this estate's names. A clone with its own project id
#          (acme-spool-dev-7f3a) and its own env (stg) must pass them; a name
#          GCP itself refuses must still fail. The regexes are READ from each
#          step's 02-variables.tf and run (grep -E), so the test follows the
#          file, not a copy of it.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
TF="$PROJ_ROOT/src/terraform"
fails=0

# --- 1. the acceptance grep: no estate name in any step's validation ----------
n=$(grep -rnF 'regex("^csi-spl' "$TF" | wc -l)
[[ "$n" -eq 0 ]] && pass "grep 'regex(\"^csi-spl' src/terraform -> 0" || fail "$n validation(s) still pin csi-spl names"

# re_of <step> <var>: the regex inside `condition = can(regex("<re>", var.<var>))`
re_of() {
  local f
  f=$(ls "$TF"/"$1"-*/02-variables.tf)
  sed -n "s/.*condition *= *can(regex(\"\\(.*\\)\", var\\.$2)).*/\\1/p" "$f" | sed -n 1p
}

# check <step> <var> <good,...> <bad,...>
check() {
  local step="$1" var="$2" re v
  re=$(re_of "$step" "$var")
  [[ -n "$re" ]] || { fail "$step: no regex validation on var.$var"; return; }
  IFS=, read -ra good <<<"$3"
  IFS=, read -ra bad <<<"$4"
  for v in "${good[@]}"; do
    grep -qE "$re" <<<"$v" && pass "$step $var accepts $v" || fail "$step $var refuses $v ($re)"
  done
  for v in "${bad[@]}"; do
    grep -qE "$re" <<<"$v" && fail "$step $var accepts $v ($re)" || pass "$step $var refuses $v"
  done
}

# --- 2. env: any cnf env name, never lde --------------------------------------
for s in 019 020 028 040 045 046 050 051; do
  check "$s" env "dev,prd,stg" "Dev,x,dev-1"
  f=$(ls "$TF"/"$s"-*/02-variables.tf)
  grep -qF 'var.env != "lde"' "$f" && pass "$s env refuses lde" || fail "$s env does not refuse lde"
done

# --- 3. each resource's own id rule -------------------------------------------
check 019 site_id "csi-spl-dev-site,acme-spool-dev-7f3a-site" "short,Bad_Site,-acme-site"
check 020 relay_bucket_name "csi-spl-dev-rel,acme-spool-dev-7f3a-rel" "Bad-Rel,-rel,rel-"
check 028 repository_id "csi-spl-dev-hub,acme-spool-dev-7f3a-hub" "1hub,hub-,Hub"
check 040 instance_name "csi-spl-dev-pg,acme-spool-dev-7f3a-pg" "1pg,pg-,Pg"
check 045 instance_name "csi-spl-prd-pg,acme-spool-dev-7f3a-pg" "1pg,pg-"
check 045 backups_bucket_name "csi-spl-dev-db-backups,acme-spool-dev-7f3a-db-backups" "Bad,-b"
check 046 tf_key_project "csi-spl-bkp,acme-spool-bkp-7f3a" "bkp,Bad_Project,acme-"
check 046 offsite_bucket_name "csi-spl-bkp-dev,acme-spool-bkp-7f3a-stg" "Bad,-b"
check 050 files_bucket_name "csi-spl-dev-files,acme-spool-dev-7f3a-files" "Bad,files-"
check 051 docs_bucket_name "csi-spl-dev-docs,acme-spool-dev-7f3a-docs" "Bad,docs-"

# CONTROL: the extraction is live - an old pinned regex refuses the clone name
grep -qE '^csi-spl-(dev|prd)-rel$' <<<"acme-spool-dev-7f3a-rel" \
  && fail "CONTROL: the old pinned regex accepted a clone name" \
  || pass "CONTROL: the old pinned regex refuses acme-spool-dev-7f3a-rel"

if [[ "$fails" -eq 0 ]]; then
  echo "PASS: all $(basename "$0") assertions"
  exit 0
fi
echo "FAIL: $fails assertion(s) in $(basename "$0")"
exit 1
