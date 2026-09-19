#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lb_absent_check's counter proves absence only from UNFILTERED
#          lists: every kind empty -> 0; any resource of any kind -> 1; a
#          failed list call -> 2 (never "none found"). Stubbed gcloud; every
#          call carries --account and no --filter.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-lb-absent-check.func.sh"
fails=0
check() { if [[ "$1" == "$2" ]]; then echo "PASS: $3"; else echo "FAIL: $3 (got rc=$1, want $2)"; fails=$((fails + 1)); fi; }
bash -n "$FUNC" || { echo "FAIL: bash -n $FUNC"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gcloud" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
[[ -n "${STUB_FAIL:-}" && "$*" == *"$STUB_FAIL"* ]] && { echo "ERROR: permission denied" >&2; exit 1; }
[[ -n "${STUB_HAS:-}" && "$*" == *"$STUB_HAS"* ]] && echo "some-hub-thing"
exit 0
S
chmod +x "$tmp/bin/gcloud"
export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log"
# shellcheck disable=SC1090
source "$FUNC"
: >"$STUB_LOG"; spl_lb_kinds_count p a@x >/dev/null; check $? 0 "every kind empty -> 0"
n=$(grep -c . "$STUB_LOG"); [[ $n == 13 ]] && echo "PASS: 13 kinds listed" || { echo "FAIL: $n kinds listed, want 13"; fails=$((fails + 1)); }
grep -q -- '--filter' "$STUB_LOG" && { echo "FAIL: a list is filtered"; fails=$((fails + 1)); } || echo "PASS: no list is filtered"
[[ $(grep -c -- '--account=a@x' "$STUB_LOG") == 13 ]] && echo "PASS: every call carries --account" || { echo "FAIL: a call without --account"; fails=$((fails + 1)); }
for k in "security-policies" "backend-services" "certificate-manager maps" "network-endpoint-groups"; do
  STUB_HAS="$k" spl_lb_kinds_count p a@x >/dev/null; check $? 1 "a $k resource -> 1"
done
STUB_FAIL="url-maps" spl_lb_kinds_count p a@x >/dev/null; check $? 2 "a failed list -> 2, not none"
[[ $fails == 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
