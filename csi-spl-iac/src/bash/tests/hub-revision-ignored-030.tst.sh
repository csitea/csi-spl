#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3997 -- every hub deploy (the 20 pipeline) names a new Cloud
#          Run revision (csi-spl-hub-dev-01115-raj), so a 030 plan showed
#          `template.revision '<name>' -> null` on dev after each deploy and
#          the dev-leads-prd gate refused the prd apply of 030. The service's
#          lifecycle ignore_changes carries template[0].revision, next to the
#          image and traffic the 20 pipeline also owns, and its comment says
#          why. CONTROL: the previous list (no revision) fails the check.
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
# has_all <list> -> 0 when every entry the 20 pipeline owns is ignored
has_all() {
  local e
  for e in client client_version scaling 'template[0].containers[0].image' traffic 'template[0].revision'; do
    grep -qxF -- "$e" <<<"$1" || return 1
  done
}

got="$(ignored "$(cat "$TF")")"
[[ -n "$got" ]] && pass "030 hub has an ignore_changes list ($(paste -sd' ' <<<"$got"))" || fail "no ignore_changes list in $TF"
has_all "$got" && pass "ignore_changes holds template[0].revision plus image, traffic, scaling, client stamps" || fail "ignore_changes misses an entry: '$(paste -sd' ' <<<"$got")'"
old='ignore_changes = [
      client,
      client_version,
      scaling,
      template[0].containers[0].image,
      traffic,
    ]'
has_all "$(ignored "$old")" && fail "CONTROL the list without the revision passed" || pass "CONTROL the list without the revision fails"

# the lifecycle comment says the 20 pipeline names each revision
why="$(awk '/lifecycle[[:space:]]*\{/{on=1} on&&/ignore_changes/{exit} on&&/^[[:space:]]*#/' "$TF")"
grep -q 'names each revision' <<<"$why" && pass "the lifecycle comment says the 20 pipeline names each revision" \
  || fail "the lifecycle comment does not say why template.revision is ignored"

[[ $fails -eq 0 ]] && echo "PASS: all hub-revision-ignored-030.tst.sh assertions" || { echo "FAIL: $fails"; exit 1; }
