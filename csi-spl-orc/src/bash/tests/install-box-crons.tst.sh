#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_install_box_crons (specs/069 lane Y3) on a fixture crontab shaped
# like the box owner's (spec 069 section 2.2: C1..C4 inside the engine's managed
# blocks, two commented engine lines, other projects' and csi-spl's own lines).
#   1. the real manifest parses and plans C1..C4 and the daily msg-unreadable
#      run (spec 117 incident report) from this checkout
#   2. the dry run prints the diff and changes nothing
#   3. DRY_RUN=0: five tagged lines, no engine path left, every other line kept
#      byte for byte and in order; a second install is a no-op
#   4. a row whose script is not landed is refused; BOX_CRONS_ONLY installs the
#      rest and leaves the refused row's engine lines alone
#   5. remove drops the tagged lines only
#   6. a malformed manifest and an unknown BOX_CRONS_ONLY name are refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

E=/opt/box-user/ysg-box
CT="$T/crontab"
cat >"$CT" <<EOF
# m h  dom mon dow   command
#cs-replaced# * * * * * $E/src/bash/scripts/agent-save-sessions.sh >> /var/x/save.log 2>&1 # ysg-box:agent-save-sessions
#cs-replaced# @reboot $E/src/bash/scripts/agent-tmux-boot.sh >> /var/x/boot.log 2>&1 # ysg-box:agent-tmux-boot
# >>> box-crontab (edit that file, not these lines) >>>
0 8 * * * /opt/other/run-me.sh # other:job
# >>> claude-sessions >>>
* * * * * /bin/bash '$E/ysg-box-orc/src/bash/features/claude-sessions/scripts/claude-save-sessions.sh' >> '/var/x/save.log' 2>&1
@reboot /bin/bash '$E/ysg-box-orc/src/bash/features/claude-sessions/scripts/claude-sessions-boot.sh' >> '/var/x/boot.log' 2>&1
# <<< claude-sessions <<<
*/15 8-19 * * * $E/ysg-box-orc/src/bash/features/graft/scripts/graft-cron.sh # graft:index-refresh
0 20 * * * $E/ysg-box-orc/src/bash/features/graft/scripts/graft-cron.sh # graft:index-refresh-final
# <<< box-crontab <<<
* * * * * bash /x/a.sh # csi-spl:desk-reconcile
0 7 * * * echo '# csi-spl:box-cron:box-save-sessions' mid-line, not a tag
0 6 * * * bash $E/ysg-box-orc/src/bash/features/dotfiles/scripts/wifi-up.sh
EOF
cp "$CT" "$T/crontab.orig"
grep -vE 'claude-(save-sessions|sessions-boot)\.sh|agent-(save-sessions|tmux-boot)|graft-cron' "$CT" >"$T/crontab.kept"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"

O="$T/orc"
mkdir -p "$O/cnf/box-crons" "$O/src/bash/features/box-sessions/scripts" "$O/src/bash/features/graft/scripts" "$O/src/bash/scripts"
cp "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" "$O/cnf/box-crons/"
touch "$O/src/bash/features/box-sessions/scripts/save-sessions.sh" "$O/src/bash/features/box-sessions/scripts/sessions-boot.sh" \
  "$O/src/bash/features/graft/scripts/graft-cron.sh" "$O/src/bash/scripts/msg-unreadable-cron.sh"
inst() { SNIPPET="PROJ_PATH=$O; do_install_box_crons" in_orc BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_STATE_DIR="$T/state" "$@" 2>&1; }

out="$(SNIPPET='do_install_box_crons' in_orc BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_ALLOW_WORKTREE=1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^  +.* # csi-spl:box-cron:[a-z-]*$' <<<"$out")" = 5 ] \
  && grep -q "^  +@reboot /bin/bash '$PROJ_ROOT/src/bash/features/box-sessions/scripts/sessions-boot.sh' >> '/var/csi/csi-spl/box-sessions/boot.log' 2>&1 # csi-spl:box-cron:box-sessions-boot$" <<<"$out" \
  && grep -q "^  +17 7 \* \* \* /bin/bash '$PROJ_ROOT/src/bash/scripts/msg-unreadable-cron.sh' >> '/var/csi/csi-spl/msg-unreadable/cron.log' 2>&1 # csi-spl:box-cron:msg-unreadable$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/msg-unreadable-cron.sh" ] \
  && pass "1. the real manifest plans C1..C4 and the daily msg-unreadable run from this checkout" || fail "1. real manifest (rc $rc: $out)"

out="$(inst)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^  +' <<<"$out")" = 6 ] && [ "$(grep -c "^  -.*$E" <<<"$out")" = 6 ] \
  && pass "2. the dry run prints the diff: +5 tagged, -6 engine lines" || fail "2. dry-run diff (rc $rc: $out)"
cmp -s "$CT" "$T/crontab.orig" && pass "2. ...and changes nothing" || fail "2. the dry run wrote the crontab"

out="$(inst DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c ' # csi-spl:box-cron:[a-z-]*$' "$CT")" = 5 ] && pass "3. DRY_RUN=0 adds five tagged lines" || fail "3. tagged ($out; $(cat "$CT"))"
[ "$(grep -v ' # csi-spl:box-cron:[a-z-]*$' "$CT" | grep -c "$E/" )" = 1 ] && grep -q 'dotfiles/scripts/wifi-up.sh' "$CT" \
  && pass "3. ...no engine job left but the unlisted one" || fail "3. engine lines left: $(grep "$E/" "$CT")"
cmp -s <(grep -v ' # csi-spl:box-cron:[a-z-]*$' "$CT") "$T/crontab.kept" && pass "3. ...every other line kept, in order" || fail "3. other lines changed"
grep -q "^\*/15 8-19 \* \* \* /bin/bash '$O/src/bash/features/graft/scripts/graft-cron.sh' >> '$T/state/graft/cron.log' 2>&1 # csi-spl:box-cron:graft-index-refresh$" "$CT" \
  && [ -d "$T/state/box-sessions" ] && pass "3. ...run from csi-spl, logs under the state dir" || fail "3. line shape ($(cat "$CT"))"
out="$(inst DRY_RUN=0)"
grep -q 'OK cron: nothing to change' <<<"$out" && pass "3. a second install is a no-op" || fail "3. second install ($out)"

cp "$T/crontab.orig" "$CT"; rm "$O/src/bash/features/graft/scripts/graft-cron.sh"
out="$(inst DRY_RUN=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'graft-index-refresh graft-index-final is not in' <<<"$out" && cmp -s "$CT" "$T/crontab.orig" \
  && pass "4. a row whose script is not landed is refused, nothing changed" || fail "4. missing script (rc $rc: $out)"
out="$(inst DRY_RUN=0 BOX_CRONS_ONLY=box-save-sessions,box-sessions-boot)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c ' # csi-spl:box-cron:' "$CT")" = 2 ] && [ "$(grep -c 'graft-cron.sh # graft:' "$CT")" = 2 ] \
  && pass "4. BOX_CRONS_ONLY installs the rest, the graft engine lines stay" || fail "4. only ($out; $(cat "$CT"))"

out="$(inst DRY_RUN=0 BOX_CRONS_ACTION=remove)"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$CT" <(grep -vE 'claude-(save-sessions|sessions-boot)\.sh|agent-(save-sessions|tmux-boot)' "$T/crontab.orig") \
  && pass "5. remove drops the tagged lines only" || fail "5. remove ($out; $(cat "$CT"))"

cp "$T/crontab.orig" "$CT"
printf 'bad | * * * | x.sh | x.log |\n' >"$T/bad.manifest"
out="$(inst DRY_RUN=0 BOX_CRONS_MANIFEST="$T/bad.manifest")"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'schedule must be 5 cron fields' <<<"$out" && pass "6. a malformed manifest is refused" || fail "6. bad manifest (rc $rc: $out)"
out="$(inst BOX_CRONS_ONLY=nope)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "names 'nope'" <<<"$out" && cmp -s "$CT" "$T/crontab.orig" \
  && pass "6. an unknown BOX_CRONS_ONLY name is refused" || fail "6. bad only (rc $rc: $out)"

echo "install-box-crons: ${fails} failure(s)"
[ "$fails" -eq 0 ]
