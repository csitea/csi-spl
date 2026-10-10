#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: cron_drop_tagged_line (lib/bash/funcs/cron-tagged-line.func.sh), the
# helper the install-cron actions share, on a fixture crontab and a fake
# crontab command. Every check has a failing control.
#   1. drop a present tag: changed, rc 0, the tagged line goes, others stay
#   2. drop an absent tag: unchanged, rc 2, the crontab is not rewritten
#   3. a line that only CONTAINS the tag mid-line (or a longer tag) stays
#   4. a dry run reports PLAN and the diff, rc 2, writes nothing
#   5. append a line: replaced in place, the log dir created; again -> unchanged
#   6. a refusing crontab: FATAL, rc 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CT="$T/crontab"
fixture() {
  printf '%s\n' '0 8 * * * /opt/other/run-me.sh # other:job' \
    '0 9 * * * true # csi-spl:demo mid-line # other:mid' \
    '0 10 * * * x # csi-spl:demo-longer' \
    '*/5 * * * * bash /x/demo.sh # csi-spl:demo' >"$CT"
}
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
printf '#!/bin/sh\n[ "$1" = -l ] && cat %q; exit 1\n' "$CT" >"$T/refusing-crontab"; chmod +x "$T/refusing-crontab"
drop() {
  env PROJ_PATH="$PROJ_ROOT" bash -c 'set -uo pipefail; do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/cron-tagged-line.func.sh"; cron_drop_tagged_line "$@"' _ "$@" 2>&1
}
tagged() { grep -c ' # csi-spl:demo$' "$CT"; }

# 1. a present tag
fixture; cp "$CT" "$T/ct.0"
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log")"; rc=$?
[ "$rc" = 0 ] && [ "$(tagged)" = 0 ] && grep -q '^DO cron' <<<"$out" && grep -q '^  -\*/5 .* # csi-spl:demo$' <<<"$out" \
  && [ "$(wc -l <"$CT")" = 3 ] && pass "1. a present tag is dropped: changed, rc 0, the others stay" || fail "1. present tag ($rc: $out)"
[ ! -d "$T/log" ] && pass "1. ...and a drop alone creates no log dir" || fail "1. log dir created on a drop"
cmp -s "$CT" "$T/ct.0" && fail "1. control: the crontab did not change" || pass "1. control: the crontab differs from the fixture"

# 2. an absent tag (the crontab from 1 has none left)
cp "$CT" "$T/ct.1"; touch -d '1 hour ago' "$CT"; m0=$(stat -c %Y "$CT")
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log")"; rc=$?
[ "$rc" = 2 ] && grep -qx 'OK cron: nothing to change' <<<"$out" && cmp -s "$CT" "$T/ct.1" && [ "$(stat -c %Y "$CT")" = "$m0" ] \
  && pass "2. an absent tag: unchanged, rc 2, not rewritten" || fail "2. absent tag ($rc: $out)"

# 3. mid-line and longer tags stay (checked after 1 and 2)
grep -q '# other:mid$' "$CT" && grep -q '# csi-spl:demo-longer$' "$CT" \
  && pass "3. a line that only CONTAINS the tag mid-line, or a longer tag, stays" || fail "3. ($(cat "$CT"))"

# 4. a dry run
fixture; cp "$CT" "$T/ct.4"
out="$(drop "$T/fake-crontab" csi-spl:demo 1 "$T/log" '1 2 3 4 5 new # csi-spl:demo')"; rc=$?
[ "$rc" = 2 ] && grep -q '^PLAN cron' <<<"$out" && grep -q '^  +1 2 3 4 5 new # csi-spl:demo$' <<<"$out" \
  && grep -q 'OK DRY_RUN nothing was touched' <<<"$out" && cmp -s "$CT" "$T/ct.4" && [ ! -d "$T/log" ] \
  && pass "4. a dry run prints the diff, rc 2, writes nothing" || fail "4. dry run ($rc: $out)"

# 5. append: the tagged line is replaced in place, the log dir created
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log" '1 2 3 4 5 new # csi-spl:demo')"; rc=$?
[ "$rc" = 0 ] && [ "$(tagged)" = 1 ] && grep -q '^1 2 3 4 5 new # csi-spl:demo$' "$CT" && [ -d "$T/log" ] \
  && [ "$(wc -l <"$CT")" = 4 ] && pass "5. append replaces the tagged line and creates the log dir" || fail "5. append ($rc: $out)"
out="$(drop "$T/fake-crontab" csi-spl:demo 0 "$T/log" '1 2 3 4 5 new # csi-spl:demo')"; rc=$?
[ "$rc" = 2 ] && grep -qx 'OK cron: nothing to change' <<<"$out" && pass "5. the same append again is unchanged" || fail "5. again ($rc: $out)"

# 6. a crontab that refuses the new file
fixture
out="$(drop "$T/refusing-crontab" csi-spl:demo 0 "$T/log")"; rc=$?
[ "$rc" = 1 ] && grep -q 'FATAL crontab refused the new file' <<<"$out" && pass "6. a refusing crontab: FATAL, rc 1" || fail "6. refused ($rc: $out)"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
