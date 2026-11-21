#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 190 row T1 (SPL-6152, gap G7; owner poll fd47ab36 Q6 A): each
#          workspace's 052 bucket deletes the NONCURRENT generations of its
#          Qto files after a grace, statically (no terraform, no network):
#   1. one lifecycle_rule on google_storage_bucket.workspace_docs with
#      days_since_noncurrent_time = var.media_noncurrent_retention_days,
#      matches_prefix exactly ["qto-media/", "qto-assets/", ".doctree/"],
#      with_state = "ARCHIVED", action Delete.
#   2. no rule deletes a LIVE object under those prefixes (age, no state,
#      LIVE or ANY): the hub's sweep decides what a doc no longer names.
#   3. the variable is declared and validated (7..365 days).
#   4. the cnf: all.env.yaml 052 media_noncurrent_retention_days: 7, once;
#      the dev and prd tfvars carry it.
#   5. CONTROLS on a copy of the step: the rule on another variable,
#      .doctree/ dropped from its prefixes, with_state LIVE, and a planted
#      age rule on qto-media/ each fail 1 or 2.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
STEP=052-gcs-workspace-docs
SD="$PROJ_ROOT/src/terraform/$STEP"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
PREFIXES='["qto-media/","qto-assets/",".doctree/"]'
fails=0
tmp_dir

[[ -d "$SD" ]] && pass "$STEP exists" || { fail "$STEP dir missing"; exit 1; }

# rules_of <dir> - each lifecycle_rule block of the step on one line, spaces
# and comments dropped
rules_of() {
  sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//' "$1"/*.tf | awk '
    /^[[:space:]]*lifecycle_rule[[:space:]]*\{/ { r = 1; d = 0; b = "" }
    r { b = b $0; l = $0; n = gsub(/\{/, "{", l); m = gsub(/\}/, "}", l); d += n - m
        if (d == 0) { gsub(/[[:space:]]+/, "", b); print b; r = 0 } }'
}

# media_rule <dir> - exactly one rule is the noncurrent delete of the Qto files
media_rule() {
  local hits
  hits=$(rules_of "$1" | grep -F "matches_prefix=$PREFIXES" | grep -F 'days_since_noncurrent_time=var.media_noncurrent_retention_days' \
    | grep -F 'with_state="ARCHIVED"' | grep -cF 'type="Delete"')
  [[ "$hits" == 1 ]]
}

# no_live_delete <dir> - no rule on a Qto prefix can match a live object
no_live_delete() {
  ! rules_of "$1" | grep -E 'qto-media/|qto-assets/|\.doctree/' | grep -vF 'with_state="ARCHIVED"' | grep . >/dev/null
}

media_rule "$SD" && pass "1. one ARCHIVED-only Delete rule: days_since_noncurrent_time = var.media_noncurrent_retention_days on $PREFIXES" \
  || fail "1. no noncurrent rule on $PREFIXES: $(rules_of "$SD" | paste -sd ';')"
no_live_delete "$SD" && pass "2. no rule deletes a live qto-media/, qto-assets/ or .doctree/ object" \
  || fail "2. a rule on a Qto prefix matches live objects"

# --- 3. the variable --------------------------------------------------------------
awk '/^variable "media_noncurrent_retention_days"/ { v = 1 } v && /type *= *number/ { t = 1 }
     v && /var\.media_noncurrent_retention_days >= 7 && var\.media_noncurrent_retention_days <= 365/ { c = 1 }
     v && /^}/ { v = 0 } END { exit !(t && c) }' "$SD/02-variables.tf" \
  && pass "3. variable media_noncurrent_retention_days: number, validated 7..365" || fail "3. variable media_noncurrent_retention_days missing or unvalidated"

# --- 4. the cnf and the renders --------------------------------------------------
[[ "$(yq -r '.env.steps."052-gcs-workspace-docs".media_noncurrent_retention_days // ""' "$CNF/all.env.yaml")" == 7 ]] \
  && [[ $(grep -c 'media_noncurrent_retention_days:' "$CNF/all.env.yaml") == 1 ]] \
  && pass "4. all.env.yaml: 052 media_noncurrent_retention_days: 7, once" || fail "4. all.env.yaml lacks 052 media_noncurrent_retention_days: 7"
for e in dev prd; do
  grep -qx 'media_noncurrent_retention_days = 7' "$CNF/$e/tf/$STEP.vars.tfvars" 2>/dev/null \
    && pass "4. $e render carries media_noncurrent_retention_days = 7" || fail "4. $e render lacks media_noncurrent_retention_days = 7 (re-run ENV=$e ./run -a do_tpl_gen)"
done

# --- 5. controls --------------------------------------------------------------------
B=03-workspace-docs-buckets.tf
plant() { rm -rf "$T/s"; cp -r "$SD" "$T/s"; }
plant; sed -i 's/var\.media_noncurrent_retention_days/var.backup_retention_days/' "$T/s/$B"
! media_rule "$T/s" && pass "5. CONTROL: the rule on another variable fails 1" || fail "5. a rule without the variable passed"
plant; sed -i 's|, "\.doctree/"||' "$T/s/$B"
! media_rule "$T/s" && pass "5. CONTROL: .doctree/ dropped from the prefixes fails 1" || fail "5. a rule without .doctree/ passed"
plant; awk '/qto-media\// { q = 1 } q && /with_state/ { sub(/"ARCHIVED"/, "\"LIVE\""); q = 0 } { print }' "$SD/$B" >"$T/s/$B"
! media_rule "$T/s" && ! no_live_delete "$T/s" && pass "5. CONTROL: with_state LIVE fails 1 and 2" || fail "5. a LIVE rule passed"
plant; printf '\nresource "google_storage_bucket" "x" {\n  lifecycle_rule {\n    condition {\n      age            = 30\n      matches_prefix = ["qto-media/"]\n    }\n    action {\n      type = "Delete"\n    }\n  }\n}\n' >>"$T/s/$B"
! no_live_delete "$T/s" && pass "5. CONTROL: a planted age rule on qto-media/ fails 2" || fail "5. an age rule on qto-media/ passed"

[[ $fails -eq 0 ]] && { echo "PASS: all"; exit 0; } || { echo "FAIL: $fails"; exit 1; }
