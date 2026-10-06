#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the public dataset allow-list (spec 091 section 4, T002) is safe by
#          construction: every allow-list.v<N>.yaml parses, its name and
#          `version` agree, no column is both `public` and `withheld`, no
#          section 4.2 table or column is `public`, every `public` column is one
#          section 4.1 names, every constant / forced key is a column of the
#          right list, and every column it names exists in the migrations. The
#          cnf carries the kill switch off on every env and points at this
#          version. Gate C3 (T005) checks the LIVE catalog; this is the file.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

DIR="$PROJ_ROOT/cnf/public-dataset"
MIG="$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

# section 4.1, the spec's table: the ONLY columns that may ever be public
declare -A SPEC_PUBLIC=(
  [tenants]="tenant_id display_name created_at"
  [channels]="channel_id name description created_by created_at"
  [messages]="msg_id task_id parent_task_id channel ts from_id to_id kind body is_parent received_at expires_at"
  [humans]="human_id"
  [tenant_memberships]="tenant_id human_id role created_at"
)
# section 4.2: never public, whatever a file says
NEVER_COLS="email msg env env_sig files typed_by ref_task_id mirror_of root_pubkey"
NEVER_TABLES="password_credentials human_identities human_keys tenant_invites email_verification_tokens
  password_reset_tokens agent_join_tokens pins pins_history operator_audit human_events flow_events
  wui_perf_samples member_activity boxes box_stats box_facts roster deliveries"

files=("$DIR"/allow-list.v*.yaml)
[[ -f "${files[0]}" ]] && pass "${#files[@]} allow-list file(s) found" || { fail "no allow-list under $DIR"; files=(); }

check_file() {  # <file>: every structural rule on one allow-list
  local f="$1" b n v t c hit
  b=$(basename "$f")
  yq -e '.' "$f" >/dev/null 2>&1 && pass "$b parses" || { fail "$b does not parse"; return; }
  n="${b#allow-list.v}"; n="${n%.yaml}"
  # .["version"]: a bare .version is a yq keyword on some yq builds
  v=$(yq -r '.["version"]' "$f")
  [[ "$n" =~ ^[1-9][0-9]*$ && "$v" == "$n" ]] && pass "$b: name and version ($v) agree" || fail "$b: name says $n, version says $v"

  local tables
  tables=$(yq -r '.tables | keys | .[]' "$f" | sort | tr '\n' ' ')
  [[ "$tables" == "channels humans messages tenant_memberships tenants " ]] \
    && pass "$b lists exactly the five section 4.1 tables" || fail "$b tables: $tables"

  for t in $(yq -r '.tables | keys | .[]' "$f"); do
    local pub wh
    pub=$(yq -r ".tables.$t.public[]" "$f")
    wh=$(yq -r ".tables.$t.withheld[]" "$f")
    [[ -n "$pub" && -n "$wh" ]] || fail "$b $t: empty public or withheld list"
    [[ -n "$(yq -r ".tables.$t.rows // \"\"" "$f")" ]] || fail "$b $t: no row rule"
    hit=$(comm -12 <(sort <<<"$pub") <(sort <<<"$wh") | tr '\n' ' ')
    [[ -z "$hit" ]] || fail "$b $t: both public and withheld: $hit"
    hit=$( { sort <<<"$pub"; sort <<<"$wh"; } | uniq -d | tr '\n' ' ')
    [[ -z "$hit" ]] || fail "$b $t: a column is listed twice: $hit"
    for c in $pub; do
      [[ " ${SPEC_PUBLIC[$t]:-} " == *" $c "* ]] || fail "$b $t.$c is public but section 4.1 does not name it"
      [[ " $NEVER_COLS " != *" $c "* ]] || fail "$b $t.$c is a section 4.2 column and public"
    done
    for c in $(yq -r ".tables.$t.constants // {} | keys | .[]" "$f"); do
      grep -qx "$c" <<<"$wh" || fail "$b $t: constant for $c, which is not withheld"
    done
    for c in $(yq -r ".tables.$t.forced // {} | keys | .[]" "$f"); do
      grep -qx "$c" <<<"$pub" || fail "$b $t: forced value for $c, which is not public"
    done
    for c in $pub $wh; do
      grep -rqwE "$c" "$MIG"/*.sql || fail "$b $t.$c: no migration names this column"
    done
  done
  pass "$b: per-table rules checked"

  local never
  never=$(yq -r '.never[]' "$f")
  for t in $NEVER_TABLES; do
    grep -qx "$t" <<<"$never" || fail "$b: section 4.2 table $t missing from never"
  done
  for t in $never; do
    [[ "$(yq -r ".tables | has(\"$t\")" "$f")" == false ]] || fail "$b: never table $t is also listed for export"
  done
  pass "$b: never list carries section 4.2"

  # the section 4.4 constants for the NOT NULL withheld columns
  local want
  for want in messages.msg messages.env messages.env_sig messages.from_box messages.to_box \
              tenants.root_pubkey tenant_memberships.admitted_by; do
    [[ "$(yq -r ".tables.${want%%.*}.constants | has(\"${want#*.}\")" "$f")" == true ]] \
      || fail "$b: no constant for NOT NULL withheld $want"
  done
  pass "$b: NOT NULL withheld columns carry constants"
}
for f in "${files[@]}"; do check_file "$f"; done

# a planted public 4.2 column must fail the same checks (the test is not vacuous)
cp "$DIR/allow-list.v1.yaml" "$T/allow-list.v1.yaml"
yq -i '.tables.humans.public += ["email"] | .tables.humans.withheld -= ["email"]' "$T/allow-list.v1.yaml"
before=$fails
check_file "$T/allow-list.v1.yaml" >/dev/null
(( fails > before )) && { fails=$before; pass "control: a public humans.email fails"; } || fail "control: a public humans.email passed"
yq '.["version"] = 2' "$DIR/allow-list.v1.yaml" >"$T/allow-list.v1.yaml"
before=$fails
check_file "$T/allow-list.v1.yaml" >/dev/null
(( fails > before )) && { fails=$before; pass "control: a name/version mismatch fails"; } || fail "control: a name/version mismatch passed"

# the cnf: kill switch off everywhere, pointing at a file that exists
for e in dev prd; do
  m=$(yq ea '. as $i ireduce ({}; . * $i)' "$CNF/all.env.yaml" "$CNF/$e.env.yaml")
  [[ "$(yq -r '.env.public_dataset.enabled' <<<"$m")" == false ]] && pass "$e: public_dataset.enabled is false" || fail "$e: enabled is not false"
  av=$(yq -r '.env.public_dataset.allow_list_version' <<<"$m")
  [[ -f "$DIR/allow-list.v$av.yaml" ]] && pass "$e: allow_list_version $av has its file" || fail "$e: no file for allow_list_version $av"
  for k in workspace_id topic_channel body_drop_cap_pct size_tolerance_pct candidate_ttl_hours dev_synthetic; do
    [[ "$(yq -r ".env.public_dataset.$k" <<<"$m")" != null ]] || fail "$e: public_dataset.$k unset"
  done
  for k in public_bucket_name staging_bucket_name daily_retention_days stable_retention_days; do
    [[ "$(yq -r ".env.steps.\"053-gcs-public-dataset\".$k" <<<"$m")" != null ]] || fail "$e: steps.053-gcs-public-dataset.$k unset"
  done
  pass "$e: public_dataset and step 053 keys set"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
