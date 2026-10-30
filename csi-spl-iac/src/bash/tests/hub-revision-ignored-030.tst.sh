#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the hub's revision name in 030, two bugs at once.
#          SPL-3997 -- every hub deploy (the 20 pipeline) names a new Cloud
#          Run revision (csi-spl-hub-dev-01115-raj), so a 030 plan showed
#          `template.revision '<name>' -> null` after each deploy and the
#          dev-leads-prd gate refused the prd apply of 030.
#          SPL-4298 -- the first fix ignored template[0].revision; the
#          provider then re-sent the deployed name with every changed
#          template and Cloud Run refused it (409 "Revision named ... with
#          different configuration already exists").
#          Now: revision is NOT ignored; the template sets it from
#          module.revision (the live name or a fresh one, its logic tested by
#          revision-name-030.tst.sh) and carries the inputs hash as a label.
#          CONTROL: master 8ca8fb600's list (revision ignored) fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
TF="$PROJ_ROOT/src/terraform/030-cloud-run-hub/04-cloud-run-service.tf"

# ignored <tf text> -> the entries of the first ignore_changes list, one a line
ignored() {
  awk '/ignore_changes[[:space:]]*=[[:space:]]*\[/{on=1; next} on&&/^[[:space:]]*\]/{exit} on{gsub(/[[:space:],]/, ""); if ($0 != "") print}' <<<"$1"
}
# list_ok <list> -> 0 when every entry the 20 pipeline owns is ignored and
# the revision is not
list_ok() {
  local e
  for e in client client_version scaling 'template[0].containers[0].image' traffic; do
    grep -qxF -- "$e" <<<"$1" || return 1
  done
  ! grep -qxF -- 'template[0].revision' <<<"$1"
}

got="$(ignored "$(cat "$TF")")"
[[ -n "$got" ]] && pass "030 hub has an ignore_changes list ($(paste -sd' ' <<<"$got"))" || fail "no ignore_changes list in $TF"
list_ok "$got" && pass "ignore_changes holds image, traffic, scaling, client stamps and NOT template[0].revision" \
  || fail "ignore_changes is wrong: '$(paste -sd' ' <<<"$got")'"
old='ignore_changes = [
      client,
      client_version,
      scaling,
      template[0].containers[0].image,
      template[0].revision,
      traffic,
    ]'
list_ok "$(ignored "$old")" && fail "CONTROL master 8ca8fb600's list (revision ignored) passed" \
  || pass "CONTROL master 8ca8fb600's list (revision ignored) fails"

# the template takes its revision name and label from module.revision
tmpl="$(awk '/^[[:space:]]*template[[:space:]]*\{/{on=1} on&&/service_account/{exit} on' "$TF")"
grep -qE '^[[:space:]]*revision[[:space:]]*=[[:space:]]*module\.revision\.revision[[:space:]]*$' <<<"$tmpl" \
  && pass "template.revision = module.revision.revision" || fail "template.revision is not set from module.revision"
grep -qE '^[[:space:]]*labels[[:space:]]*=[[:space:]]*\{[[:space:]]*\(module\.revision\.label_key\)[[:space:]]*=[[:space:]]*local\.template_hash[[:space:]]*\}' <<<"$tmpl" \
  && pass "template.labels carries local.template_hash under module.revision.label_key" || fail "template.labels does not carry the inputs hash"
grep -qE 'source[[:space:]]*=[[:space:]]*"\./revision-name"' "$TF" && pass "module.revision is ./revision-name" || fail "no module \"revision\" from ./revision-name"

# every template input terraform owns is in the hash (the image is the 20
# pipeline's): a var the template reads but the hash misses would re-send the
# live name with a changed template, the SPL-4298 409 again
hash_block="$(awk '/template_hash[[:space:]]*=[[:space:]]*substr/{on=1} on; on&&/\}\)\), 0, 16\)/{exit}' "$TF")"
tmpl_vars="$(awk '/^[[:space:]]*template[[:space:]]*\{/{on=1} on&&/depends_on/{exit} on' "$TF" | grep -oE 'var\.[a-z_]+' | sort -u | grep -vx 'var.image')"
missing=""
for v in $tmpl_vars; do grep -qF -- "$v" <<<"$hash_block" || missing+=" $v"; done
[[ -n "$tmpl_vars" && -z "$missing" ]] && pass "local.template_hash covers every var the template reads ($(wc -w <<<"$tmpl_vars"))" \
  || fail "local.template_hash misses:${missing:- (no template vars found)}"
grep -qF 'filesha1("${path.module}/04-cloud-run-service.tf")' <<<"$hash_block" \
  && pass "local.template_hash covers this file (its constants)" || fail "local.template_hash does not cover 04-cloud-run-service.tf"

# the lifecycle comment says why the revision is no longer ignored
why="$(awk '/lifecycle[[:space:]]*\{/{on=1} on&&/ignore_changes/{exit} on&&/^[[:space:]]*#/' "$TF")"
grep -q 'names each revision' <<<"$why" && grep -q 'SPL-4298' <<<"$why" \
  && pass "the lifecycle comment says the 20 pipeline names each revision and why it is not ignored (SPL-4298)" \
  || fail "the lifecycle comment does not explain the revision handling"

[[ $fails -eq 0 ]] && echo "PASS: all hub-revision-ignored-030.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
