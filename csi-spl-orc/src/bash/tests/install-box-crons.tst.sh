#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_install_box_crons (specs/069 lane Y3) on a fixture crontab shaped
# like the box owner's (spec 069 section 2.2: C1..C4 inside the engine's managed
# blocks, two commented engine lines, other projects' and csi-spl's own lines).
#   1. the real manifest parses and plans C1..C4, the daily msg-unreadable
#      run (spec 117 incident report) and the nightly box state backup
#      (owner t1 d80ed72c) and the 10-min CI red note (spec 131 C2) and the
#      every-minute agent login self-heal and the 5-min topic status card
#      (SPL-2117) from this checkout
#   2. the dry run prints the diff and changes nothing
#   3. DRY_RUN=0: eight tagged lines, no engine path left, every other line kept
#      byte for byte and in order; a second install is a no-op
#   4. a row whose script is not landed is refused; BOX_CRONS_ONLY installs the
#      rest and leaves the refused row's engine lines alone
#   5. remove drops the tagged lines only
#   6. a malformed manifest and an unknown BOX_CRONS_ONLY name are refused
#   7. SPL-4558: the rows marked `desk` are the rows whose job reaches a desk,
#      measured from the code (box-crons-desk-reach.py)
#   8. with a desk user (SPOOL_DESK_USER of box.env), the desk rows move from
#      the box user's crontab to the desk user's: the box user's no longer
#      carries issue-close-landed; idempotent; remove clears both; a refused
#      desk crontab leaves the box user's untouched; a failed list (other than
#      "no crontab for") writes neither; the running user as desk
#      user keeps one crontab; a bad `as` is refused
#   9. a desk row goes to the user that holds its desk's pin: the box desk
#      pinned under the running user keeps its rows there while the rsp row
#      moves (sat 2026-11-01 15:00Z); desk:any and a row with no pin stay
#      where they are; a re-run on that state is a no-op, in any row order
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
# every script the real manifest names exists in the fixture checkout
awk -F'|' '!/^[[:space:]]*(#|$)/ {gsub(/[[:space:]]/, "", $3); print $3}' "$O/cnf/box-crons/box-crons.manifest" |
  while read -r f; do mkdir -p "$O/$(dirname "$f")"; touch "$O/$f"; done
inst() { SNIPPET="PROJ_PATH=$O; do_install_box_crons" in_orc BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_STATE_DIR="$T/state" "$@" 2>&1; }

out="$(SNIPPET='do_install_box_crons' in_orc BOX_CRONS_CRONTAB="$T/fake-crontab" BOX_CRONS_ALLOW_WORKTREE=1 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^  +.* # csi-spl:box-cron:[a-z0-9-]*$' <<<"$out")" = 41 ] \
  && grep -q "^  +@reboot i=0; until .* BOOT start csi-spl:box-cron:box-sessions-boot .*/bin/bash '$PROJ_ROOT/src/bash/features/box-sessions/scripts/sessions-boot.sh' >> '/var/csi/csi-spl/box-sessions/boot.log' 2>&1 # csi-spl:box-cron:box-sessions-boot$" <<<"$out" \
  && grep -q "^  +17 7 \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/msg-unreadable/msg-unreadable.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/msg-unreadable-cron.sh' >> '/var/csi/csi-spl/msg-unreadable/cron.log' 2>&1 # csi-spl:box-cron:msg-unreadable$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/msg-unreadable-cron.sh" ] \
  && grep -q "^  +41 2 \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/box-state/box-state-backup.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/box-state-backup-cron.sh' >> '/var/csi/csi-spl/box-state/backup.log' 2>&1 # csi-spl:box-cron:box-state-backup$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/box-state-backup-cron.sh" ] \
  && grep -q "^  +\*/10 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/ci-red-note/ci-red-note.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/ci-red-note-cron.sh' >> '/var/csi/csi-spl/ci-red-note/cron.log' 2>&1 # csi-spl:box-cron:ci-red-note$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/ci-red-note-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/agent-login-check/agent-login-check.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/agent-login-check-cron.sh' >> '/var/csi/csi-spl/agent-login-check/cron.log' 2>&1 # csi-spl:box-cron:agent-login-check$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/agent-login-check-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/lane-rotate/lane-rotate.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/lane-rotate-cron.sh' >> '/var/csi/csi-spl/lane-rotate/cron.log' 2>&1 # csi-spl:box-cron:lane-rotate$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/lane-rotate-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/uplink-probe/uplink-probe.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/uplink-probe-cron.sh' >> '/var/csi/csi-spl/uplink-probe/cron.log' 2>&1 # csi-spl:box-cron:uplink-probe$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/uplink-probe-cron.sh" ] \
  && grep -q "^  +23 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/qas-ci-accept/qas-ci-accept.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/qas-ci-accept-cron.sh' >> '/var/csi/csi-spl/qas-ci-accept/cron.log' 2>&1 # csi-spl:box-cron:qas-ci-accept$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/qas-ci-accept-cron.sh" ] \
  && grep -q "^  +7 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/owner-digest/owner-digest.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/owner-digest-cron.sh' >> '/var/csi/csi-spl/owner-digest/cron.log' 2>&1 # csi-spl:box-cron:owner-digest$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/owner-digest-cron.sh" ] \
  && grep -q "^  +\*/5 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/issue-close-landed/issue-close-landed.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/issue-close-landed-cron.sh' >> '/var/csi/csi-spl/issue-close-landed/cron.log' 2>&1 # csi-spl:box-cron:issue-close-landed$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/issue-close-landed-cron.sh" ] \
  && grep -q "^  +53 6 \* \* 1 $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/issue-key-rate/issue-key-rate.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/issue-key-rate-cron.sh' >> '/var/csi/csi-spl/issue-key-rate/cron.log' 2>&1 # csi-spl:box-cron:issue-key-rate$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/issue-key-rate-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/gc/gc.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/gc-cron.sh' >> '/var/csi/csi-spl/gc/cron.log' 2>&1 # csi-spl:box-cron:gc$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/gc-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/reverse-tunnel/reverse-tunnel.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/reverse-tunnel-cron.sh' >> '/var/csi/csi-spl/reverse-tunnel/cron.log' 2>&1 # csi-spl:box-cron:reverse-tunnel$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/reverse-tunnel-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/token-burn/token-burn.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/token-burn-collect-cron.sh' >> '/var/csi/csi-spl/token-burn/cron.log' 2>&1 # csi-spl:box-cron:token-burn$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/token-burn-collect-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/file-streams/file-streams.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/file-stream-follow-cron.sh' >> '/var/csi/csi-spl/file-streams/cron.log' 2>&1 # csi-spl:box-cron:file-streams$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/file-stream-follow-cron.sh" ] \
  && grep -q "^  +\*/5 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/topic-status-card/topic-status-card.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/topic-status-card-cron.sh' >> '/var/csi/csi-spl/topic-status-card/cron.log' 2>&1 # csi-spl:box-cron:topic-status-card$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/topic-status-card-cron.sh" ] \
  && grep -q "^  +37 16 \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/fx-rates-fetch/fx-rates-fetch.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/fx-rates-fetch-cron.sh' >> '/var/csi/csi-spl/fx-rates-fetch/cron.log' 2>&1 # csi-spl:box-cron:fx-rates-fetch$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/fx-rates-fetch-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/push-orphan-check/push-orphan-check.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/push-orphan-check-cron.sh' >> '/var/csi/csi-spl/push-orphan-check/cron.log' 2>&1 # csi-spl:box-cron:push-orphan-check$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/push-orphan-check-cron.sh" ] \
  && grep -q "^  +7,37 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/restore-drill-red-note/restore-drill-red-note.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/restore-drill-red-note-cron.sh' >> '/var/csi/csi-spl/restore-drill-red-note/cron.log' 2>&1 # csi-spl:box-cron:restore-drill-red-note$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/restore-drill-red-note-cron.sh" ] \
  && grep -q "^  +\*/5 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/login2-sync/login2-sync.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/login2-sync-cron.sh' >> '/var/csi/csi-spl/login2-sync/cron.log' 2>&1 # csi-spl:box-cron:login2-sync$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/login2-sync-cron.sh" ] \
  && grep -q "^  +\*/5 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/weekly-limit-alert/weekly-limit-alert.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh' >> '/var/csi/csi-spl/weekly-limit-alert/cron.log' 2>&1 # csi-spl:box-cron:weekly-limit-alert$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/weekly-limit-alert-cron.sh" ] \
  && grep -q "^  +\*/5 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/archived-seats-free/archived-seats-free.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/archived-seats-free-cron.sh' >> '/var/csi/csi-spl/archived-seats-free/cron.log' 2>&1 # csi-spl:box-cron:archived-seats-free$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/archived-seats-free-cron.sh" ] \
  && grep -q "^  +17 4 1 \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/vendor-terms-check/vendor-terms-check.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/vendor-terms-check-cron.sh' >> '/var/csi/csi-spl/vendor-terms-check/cron.log' 2>&1 # csi-spl:box-cron:vendor-terms-check$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/vendor-terms-check-cron.sh" ] \
  && grep -q "^  +\*/15 \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/zombie-topics/zombie-topics.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/zombie-topics-cron.sh' >> '/var/csi/csi-spl/zombie-topics/cron.log' 2>&1 # csi-spl:box-cron:zombie-topics$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/zombie-topics-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/agent-steps-log/agent-steps-log.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/agent-steps-log-cron.sh' >> '/var/csi/csi-spl/agent-steps-log/cron.log' 2>&1 # csi-spl:box-cron:agent-steps-log$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/agent-steps-log-cron.sh" ] \
  && grep -q "^  +\* \* \* \* \* $PROJ_ROOT/src/bash/scripts/cron-no-stack.sh /var/csi/csi-spl/box-link-watch/box-link-watch.cron.lock /bin/bash '$PROJ_ROOT/src/bash/scripts/box-link-watch-cron.sh' >> '/var/csi/csi-spl/box-link-watch/cron.log' 2>&1 # csi-spl:box-cron:box-link-watch$" <<<"$out" \
  && [ -x "$PROJ_ROOT/src/bash/scripts/box-link-watch-cron.sh" ] \
  && pass "1. the real manifest plans C1..C4, the daily msg-unreadable run, the nightly box state backup, the CI red note, the login self-heal, the every-agent rotation, the uplink probe, the hourly qas CI accept, the hourly owner digest, the hourly landed-fix close, the weekly issue key rate, the GC agent start, the reverse tunnel, the token burn collector, the 5-min topic status card, the daily exchange rates fetch and the every-minute push orphan check, the half-hourly restore drill red note and the 5-min second login sync and the every-minute box file follower (spec 160 B1) and the 5-min weekly limit alert (SPL-3849) and the 5-min archived-discussion seat free (SPL-3983) and the 15-min night zombie-topic sweep (spec 166 B6) and the every-minute agent steps log (SPL-4693) and the every-minute box link 7-min watcher (SPL-4816) from this checkout (the reliability round rows: reliability-checks-cron.tst.sh)" || fail "1. real manifest (rc $rc: $out)"

out="$(inst)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c '^  +' <<<"$out")" = 42 ] && [ "$(grep -c "^  -.*$E" <<<"$out")" = 6 ] \
  && pass "2. the dry run prints the diff: +41 tagged, -6 engine lines" || fail "2. dry-run diff (rc $rc: $out)"
cmp -s "$CT" "$T/crontab.orig" && pass "2. ...and changes nothing" || fail "2. the dry run wrote the crontab"

out="$(inst DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c ' # csi-spl:box-cron:[a-z0-9-]*$' "$CT")" = 41 ] && pass "3. DRY_RUN=0 adds forty-one tagged lines" || fail "3. tagged ($out; $(cat "$CT"))"
[ "$(grep -v ' # csi-spl:box-cron:[a-z0-9-]*$' "$CT" | grep -c "$E/" )" = 1 ] && grep -q 'dotfiles/scripts/wifi-up.sh' "$CT" \
  && pass "3. ...no engine job left but the unlisted one" || fail "3. engine lines left: $(grep "$E/" "$CT")"
cmp -s <(grep -v ' # csi-spl:box-cron:[a-z0-9-]*$' "$CT") "$T/crontab.kept" && pass "3. ...every other line kept, in order" || fail "3. other lines changed"
grep -q "^\*/15 8-19 \* \* \* $O/src/bash/scripts/cron-no-stack.sh $T/state/graft/graft-index-refresh.cron.lock /bin/bash '$O/src/bash/features/graft/scripts/graft-cron.sh' >> '$T/state/graft/cron.log' 2>&1 # csi-spl:box-cron:graft-index-refresh$" "$CT" \
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

# --- 7. the desk marks are measured from the code (SPL-4558) ------------------
MAN="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
marked="$(awk -F'|' '!/^[[:space:]]*(#|$)/ { n=$1; a=$6; gsub(/[[:space:]]/, "", n); gsub(/[[:space:]]/, "", a); if (a ~ /^desk(:rsp|:any)?$/) print n }' "$MAN" | sort)"
reach="$(python3 "$TEST_DIR/box-crons-desk-reach.py" "$PROJ_ROOT" "$MAN")"; rc=$?
measured="$(cut -d' ' -f1 <<<"$reach" | sort)"
[ "$rc" -eq 0 ] && [ -n "$measured" ] && [ "$marked" = "$measured" ] && grep -qx issue-close-landed <<<"$marked" \
  && pass "7. the $(wc -l <<<"$marked") rows marked desk are the rows whose job reaches a desk" \
  || fail "7. desk marks != code (rc $rc); marked only: $(comm -23 <(echo "$marked") <(echo "$measured") | tr '\n' ' ')measured only: $(comm -13 <(echo "$marked") <(echo "$measured") | tr '\n' ' ')($reach)"
grep -q '^issue-close-landed do_spl_issue_close_landed > .* > spl_desk_dir$' <<<"$reach" \
  && pass "7. ...each with the call path that reaches it" || fail "7. no call path for issue-close-landed ($reach)"

# --- 8. the desk rows run as the desk user (SPL-4558) ----------------------------
me="$(id -un)"; DU=""
for u in nobody daemon root; do [ "$u" != "$me" ] && getent passwd "$u" >/dev/null && { DU="$u"; break; }; done
touch "$O/src/bash/features/graft/scripts/graft-cron.sh"   # case 4 removed it
DCT="$T/desk-crontab"; : >"$DCT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$DCT" "$DCT" >"$T/fake-desk-crontab"; chmod +x "$T/fake-desk-crontab"
printf 'SPOOL_DESK_USER=%s\nSPOOL_FLEET_TENANT=t1\nSPOOL_FLEET_ENV=prd\nSPOOL_DESK_BOX=boxa\nSPOOL_RSP_BOX=boxa-rsp\n' "$DU" >"$T/box.env"
# the pins: under the desk user, every desk row's desk; a fake sudo runs the lookup as us
mkdir -p "$T/roots/du/desk/t1/boxa" "$T/roots/du/desk/t1/boxa-rsp" "$T/roots/me"
touch "$T/roots/du/desk/t1/boxa/pinned" "$T/roots/du/desk/t1/boxa-rsp/pinned"
printf '#!/bin/sh\nshift 2; exec "$@"\n' >"$T/fake-sudo"; chmod +x "$T/fake-sudo"
export BOX_CRONS_SUDO="$T/fake-sudo" BOX_CRONS_DESK_ROOTS="$me=$T/roots/me $DU=$T/roots/du"
ndesk="$(grep -cE '\| desk(:rsp)?$' "$O/cnf/box-crons/box-crons.manifest")"; nall="$(grep -cvE '^[[:space:]]*(#|$)' "$O/cnf/box-crons/box-crons.manifest")"
cp "$T/crontab.orig" "$CT"; inst DRY_RUN=0 >/dev/null   # today: every row in the box user's crontab
grep -q ' # csi-spl:box-cron:issue-close-landed$' "$CT" && pass "8. before: the box user's crontab carries issue-close-landed" || fail "8. setup ($(cat "$CT"))"
dinst() { inst SPOOL_BOX_ENV="$T/box.env" BOX_CRONS_DESK_CRONTAB="$T/fake-desk-crontab" "$@"; }
out="$(dinst)"; rc=$?
[ "$rc" -eq 0 ] && grep -q "^PLAN cron ($DU): " <<<"$out" && grep -q "^PLAN cron ($me): " <<<"$out" && [ ! -s "$DCT" ] \
  && pass "8. the dry run plans both crontabs and writes neither" || fail "8. dry run (rc $rc: $out)"
out="$(dinst DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$DU" ] && ! grep -q 'csi-spl:box-cron:issue-close-landed$' "$CT" \
  && grep -q "^\*/5 \* \* \* \* .*issue-close-landed-cron.sh' >> '$T/state/issue-close-landed/cron.log' 2>&1 # csi-spl:box-cron:issue-close-landed$" "$DCT" \
  && pass "8. DRY_RUN=0: issue-close-landed left the box user's crontab for the desk user's ($DU)" || fail "8. move (rc $rc: $out; box: $(grep -c box-cron "$CT"); desk: $(cat "$DCT"))"
[ "$(grep -c ' # csi-spl:box-cron:' "$DCT")" = "$ndesk" ] && [ "$(grep -c ' # csi-spl:box-cron:' "$CT")" = $((nall - ndesk)) ] \
  && [ "$(grep -vc ' # csi-spl:box-cron:' "$DCT")" = 0 ] && grep -q "installed ($nall row(s), $ndesk as $DU)" <<<"$out" \
  && pass "8. ...the $ndesk desk rows in the desk user's, the other $((nall - ndesk)) in the box user's" || fail "8. split ($out)"
cmp -s <(grep -v ' # csi-spl:box-cron:' "$CT") "$T/crontab.kept" && pass "8. ...every other line kept" || fail "8. other lines changed"
out="$(dinst DRY_RUN=0)"
[ "$(grep -c 'nothing to change' <<<"$out")" = 2 ] && pass "8. a second install is a no-op on both" || fail "8. second ($out)"
out="$(dinst DRY_RUN=0 BOX_CRONS_ONLY=issue-close-landed)"
grep -q "^OK cron ($me): nothing to change" <<<"$out" && [ "$(grep -c ' # csi-spl:box-cron:' "$DCT")" = "$ndesk" ] \
  && grep -q ' # csi-spl:box-cron:issue-close-landed$' "$DCT" && ! grep -q 'csi-spl:box-cron:issue-close-landed$' "$CT" \
  && pass "8. BOX_CRONS_ONLY of a desk row reinstalls it in the desk user's crontab only" || fail "8. only ($out)"
cp "$T/crontab.orig" "$CT"; inst DRY_RUN=0 >/dev/null; : >"$DCT"; cp "$CT" "$T/ct.all"
printf '#!/bin/sh\n[ "$1" = -l ] && exit 0; exit 1\n' >"$T/no-crontab"; chmod +x "$T/no-crontab"
out="$(inst SPOOL_BOX_ENV="$T/box.env" BOX_CRONS_DESK_CRONTAB="$T/no-crontab" DRY_RUN=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FATAL crontab ($DU) refused the new file" <<<"$out" && cmp -s "$CT" "$T/ct.all" \
  && pass "8. a refused desk crontab leaves the box user's untouched" || fail "8. refused (rc $rc: $out)"
echo '7 7 * * * keep-me' >"$DCT"
printf '#!/bin/sh\nif [ "$1" = -l ]; then echo "crontab: permission denied" >&2; exit 1; fi\ncp "$1" %q\n' "$DCT" >"$T/no-list-crontab"; chmod +x "$T/no-list-crontab"
out="$(inst SPOOL_BOX_ENV="$T/box.env" BOX_CRONS_DESK_CRONTAB="$T/no-list-crontab" DRY_RUN=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "FATAL crontab ($DU) refused to list (crontab: permission denied)" <<<"$out" \
  && [ "$(cat "$DCT")" = '7 7 * * * keep-me' ] && cmp -s "$CT" "$T/ct.all" \
  && pass "8. a failed list of the desk crontab writes neither crontab (no write from an empty before)" || fail "8. no list (rc $rc: $out; desk: $(cat "$DCT"))"
printf '#!/bin/sh\nif [ "$1" = -l ]; then [ -s %q ] && cat %q && exit 0; echo "no crontab for x" >&2; exit 1; fi\ncp "$1" %q\n' "$DCT" "$DCT" "$DCT" >"$T/empty-crontab"; chmod +x "$T/empty-crontab"
: >"$DCT"; out="$(inst SPOOL_BOX_ENV="$T/box.env" BOX_CRONS_DESK_CRONTAB="$T/empty-crontab" DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c ' # csi-spl:box-cron:' "$DCT")" = "$ndesk" ] \
  && pass "8. an empty desk crontab (no crontab for) installs the desk rows" || fail "8. empty (rc $rc: $out)"
dinst DRY_RUN=0 >/dev/null
out="$(dinst DRY_RUN=0 BOX_CRONS_ACTION=remove)"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q ' # csi-spl:box-cron:' "$CT" "$DCT" && pass "8. remove clears both crontabs" || fail "8. remove ($out)"
printf 'SPOOL_DESK_USER=%s\n' "$me" >"$T/box-me.env"
out="$(inst SPOOL_BOX_ENV="$T/box-me.env" BOX_CRONS_DESK_CRONTAB="$T/no-crontab" DRY_RUN=0)"; rc=$?
[ "$rc" -eq 0 ] && grep -q ' # csi-spl:box-cron:issue-close-landed$' "$CT" && [ "$(grep -c ' # csi-spl:box-cron:' "$CT")" = "$nall" ] \
  && pass "8. the running user as desk user: one crontab, every row" || fail "8. self (rc $rc: $out)"
out="$(inst BOX_CRONS_DESK_USER=no-such-user-4558 DRY_RUN=0)"; rc=$?
[ "$rc" -ne 0 ] && grep -q "desk user 'no-such-user-4558' has no passwd entry" <<<"$out" && pass "8. an unknown desk user is refused" || fail "8. unknown (rc $rc: $out)"
printf 'x | * * * * * | x.sh | x.log | | root\n' >"$T/bad-as.manifest"
out="$(inst BOX_CRONS_MANIFEST="$T/bad-as.manifest")"; rc=$?
[ "$rc" -ne 0 ] && grep -q "as must be empty, desk, desk:rsp or desk:any, got 'root'" <<<"$out" && pass "8. a bad as is refused" || fail "8. bad as (rc $rc: $out)"

# --- 9. a desk row follows its desk's pin, not the desk user alone ------------
# sat on 2026-11-01: t1/sat pinned under the box user, t1/sat-rsp under the
# desk user; 14:55Z a BOX_CRONS_DESK_USER install moved the t1/sat rows too and
# weekly-limit-alert, archived-seats-free, topic-status-card went rc=1
rm -f "$T/roots/du/desk/t1/boxa/pinned"; mkdir -p "$T/roots/me/desk/t1/boxa"; touch "$T/roots/me/desk/t1/boxa/pinned"
cp "$T/crontab.orig" "$CT"; inst DRY_RUN=0 >/dev/null; : >"$DCT"
out="$(dinst DRY_RUN=0 BOX_CRONS_DESK_USER="$DU")"; rc=$?
[ "$rc" -eq 0 ] && grep -q ' # csi-spl:box-cron:weekly-limit-alert$' "$CT" && ! grep -q 'csi-spl:box-cron:weekly-limit-alert$' "$DCT" \
  && grep -q ' # csi-spl:box-cron:issue-close-landed$' "$DCT" && ! grep -q 'csi-spl:box-cron:issue-close-landed$' "$CT" \
  && [ "$(grep -c ' # csi-spl:box-cron:' "$DCT")" = 1 ] \
  && pass "9. the box desk pinned under the running user: its rows stay there; the rsp row moves to the desk user's" || fail "9. pin (rc $rc: $out; desk: $(cat "$DCT"))"
grep -q ' # csi-spl:box-cron:file-streams$' "$CT" && grep -q "WARN file-streams (desk:any): reaches no one desk: kept in $me's crontab" <<<"$out" \
  && pass "9. a desk:any row stays where it is, with a WARN" || fail "9. any ($out)"
out="$(dinst BOX_CRONS_DESK_USER="$DU")"
[ "$(grep -c 'nothing to change' <<<"$out")" = 2 ] && pass "9. a re-run on that state plans nothing" || fail "9. re-run ($out)"
# sat after the 15:02Z revert: the rows put back from a backup, out of manifest order
{ grep -v ' # csi-spl:box-cron:' "$CT"; grep ' # csi-spl:box-cron:' "$CT" | tac; } >"$T/ct.tmp"; cp "$T/ct.tmp" "$CT"
out="$(dinst BOX_CRONS_DESK_USER="$DU")"
[ "$(grep -c 'nothing to change' <<<"$out")" = 2 ] && pass "9. ...and on the same rows in another order: an unchanged line keeps its place" || fail "9. order ($out)"
# today's sat after the 15:02Z revert: token-burn (box desk) and file-streams in the desk user's
grep -E ' # csi-spl:box-cron:(token-burn|file-streams)$' "$CT" >>"$DCT"; grep -vE ' # csi-spl:box-cron:(token-burn|file-streams)$' "$CT" >"$T/ct.tmp"; cp "$T/ct.tmp" "$CT"
out="$(dinst DRY_RUN=0 BOX_CRONS_DESK_USER="$DU")"; rc=$?
[ "$rc" -eq 0 ] && grep -q ' # csi-spl:box-cron:token-burn$' "$CT" && ! grep -q 'csi-spl:box-cron:token-burn$' "$DCT" \
  && grep -q ' # csi-spl:box-cron:file-streams$' "$DCT" && ! grep -q 'csi-spl:box-cron:file-streams$' "$CT" \
  && pass "9. a box-desk row in the desk user's crontab goes back to the pin's user; desk:any stays in the desk user's" || fail "9. back (rc $rc: $out)"
rm -f "$T/roots/me/desk/t1/boxa/pinned" "$T/roots/du/desk/t1/boxa-rsp/pinned"
out="$(dinst DRY_RUN=0 BOX_CRONS_DESK_USER="$DU")"; rc=$?
[ "$rc" -eq 0 ] && grep -q ' # csi-spl:box-cron:issue-close-landed$' "$DCT" && grep -q ' # csi-spl:box-cron:weekly-limit-alert$' "$CT" \
  && grep -q "WARN weekly-limit-alert (desk): no pin of prd/t1/boxa under $me or $DU: kept in $me's crontab" <<<"$out" \
  && [ "$(grep -c 'nothing to change' <<<"$out")" = 2 ] \
  && pass "9. no pin under either user: every desk row stays where it is" || fail "9. no pin (rc $rc: $out)"
unset BOX_CRONS_SUDO BOX_CRONS_DESK_ROOTS

echo "install-box-crons: ${fails} failure(s)"
[ "$fails" -eq 0 ]
