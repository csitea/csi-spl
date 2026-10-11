#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_shadow_feed and do_spl_shadow_feed_install_cron on a fixture
# spool root in a mktemp dir and a fixture crontab.
#   1. the mirror: a message with attachment refs arrives with files [] and
#      files_dropped (red without the drop); a plain message and a legacy .md
#      arrive byte for byte intact (the controls); files 0444, dirs not
#      group- or world-writable; only the named agents' inbox/outbox/archive
#      message files are copied; an acked message moves in the mirror too;
#      the spool root is not changed by a byte
#   2. refusals: a feed dir inside the spool root, a bad agent id
#   3. a remote box: pulled through rsync into its own <box> dir; an
#      unreachable one is a WARN, exit 0, and keeps its last mirror
#   4. the install: the dry run prints the line and changes nothing; DRY_RUN=0
#      adds ONE tagged line carrying the remotes; a second install is a no-op;
#      remove restores the crontab byte for byte
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/spool" F="$T/feed"
msg() { # <file> <from> <to> <body> [files json]
  printf '{"v":1,"msg_id":"m-%s","task_id":"t-1","ts":"2026-10-11T10:00:00Z","from":"%s","to":"%s","kind":"note","body":"%s","files":%s}\n' \
    "$RANDOM" "$2" "$3" "$4" "${5:-[]}" >"$1"
}
mkdir -p "$R"/c-001@box-a/{inbox,outbox,archive} "$R"/c-002/{inbox,archive} "$R"/c-004/inbox "$R/dispatch/shots"
ln -s c-001@box-a "$R/c-001"
echo 'PNGDATA' >"$R/dispatch/shots/secret-shot.png"
ATT='[{"bytes":8,"kind":"file","mode":"path","name":"secret-shot.png","path":"'"$R"'/dispatch/shots/secret-shot.png","sha256":"ab"}]'
msg "$R/c-001/inbox/20261011T100000Z--c-653--with-shot.json" c-653 c-001 "see the shot" "$ATT"
msg "$R/c-001/outbox/20261011T100100Z--c-001--plain.json" c-001 c-002 "plain body, kept"
printf -- '---\nfrom: c-9\n---\nlegacy body\n' >"$R/c-002/inbox/20261011T100200Z--c-9--legacy.md"
msg "$R/c-002/inbox/20261011T100300Z--c-001--to-ack.json" c-001 c-002 "ack me"
msg "$R/c-004/inbox/20261011T100400Z--c-001--not-mirrored.json" c-001 c-004 "other agent"
echo '# handoff' >"$R/c-001/handoff.md"; echo '{}' >"$R/c-001/heartbeat.json"
mkdir -p "$R/c-001/inbox/sub"; echo x >"$R/c-001/inbox/notes.txt"
before="$(cd "$R" && find . -printf '%p %m %s %T@\n' | sort | md5sum)"

feed() { SNIPPET='do_spl_shadow_feed' in_orc SPOOL_ROOT="$R" SHADOW_FEED_DIR="$F" BOX=box-a "$@" 2>&1; }
out="$(feed)"; rc=$?
[ "$rc" = 0 ] && grep -q '^box-a OK shadow feed agents=3 copied=4 kept=0 removed=0 files_dropped=1 skipped=0$' <<<"$out" \
  && pass "1. one pass mirrors 4 messages, drops 1 attachment ref" || fail "1. first pass (rc $rc: $out)"

M="$F/box-a"
shot="$M/c-001/inbox/20261011T100000Z--c-653--with-shot.json"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["files"]==[] and d["files_dropped"]==1 and d["body"]=="see the shot" else 1)' "$shot" \
  && pass "1. the attachment refs are dropped, files_dropped=1, the body kept" || fail "1. attachment: $(cat "$shot" 2>&1)"
! grep -qE 'secret-shot|dispatch/shots' "$shot" && pass "1. ...no attachment name or path is left" || fail "1. a ref survived: $(cat "$shot")"
[ -z "$(find "$F" -name '*.png')" ] && pass "1. ...and the attachment file is never copied" || fail "1. a png in the feed"
python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))==json.load(open(sys.argv[2])) else 1)' \
  "$R/c-001/outbox/20261011T100100Z--c-001--plain.json" "$M/c-001/outbox/20261011T100100Z--c-001--plain.json" \
  && pass "1. control: a plain message arrives intact" || fail "1. plain message changed"
cmp -s "$R/c-002/inbox/20261011T100200Z--c-9--legacy.md" "$M/c-002/inbox/20261011T100200Z--c-9--legacy.md" \
  && pass "1. control: a legacy .md arrives byte for byte" || fail "1. legacy .md"
[ ! -e "$M/c-004" ] && [ ! -e "$M/c-001/handoff.md" ] && [ ! -e "$M/c-001/heartbeat.json" ] \
  && [ ! -e "$M/c-001/inbox/sub" ] && [ ! -e "$M/c-001/inbox/notes.txt" ] \
  && pass "1. only the named agents' message files are mirrored" || fail "1. extra files: $(cd "$F" && find . | sort)"
[ -z "$(find "$F" -type f ! -perm 0444)" ] && [ -z "$(find "$F" -type d -perm /0022)" ] \
  && pass "1. files are 0444, no dir is group- or world-writable" || fail "1. modes: $(find "$F" -printf '%m %p\n')"
[ "$(cd "$R" && find . -printf '%p %m %s %T@\n' | sort | md5sum)" = "$before" ] \
  && pass "1. the spool root is not changed by a byte" || fail "1. the spool root changed"

mv "$R/c-002/inbox/20261011T100300Z--c-001--to-ack.json" "$R/c-002/archive/"
out="$(feed)"; rc=$?
[ "$rc" = 0 ] && grep -q 'copied=1 kept=3 removed=1 ' <<<"$out" && [ ! -e "$M/c-002/inbox/20261011T100300Z--c-001--to-ack.json" ] \
  && [ -f "$M/c-002/archive/20261011T100300Z--c-001--to-ack.json" ] \
  && pass "1. an acked message moves to archive/ in the mirror too" || fail "1. ack (rc $rc: $out)"
grep -q '^20[0-9-]*T[0-9:]*Z box-a agents=3 copied=1' "$F/LAST_RUN" && pass "1. LAST_RUN carries the time and counts" || fail "1. LAST_RUN: $(cat "$F/LAST_RUN" 2>&1)"

out="$(feed SHADOW_FEED_DIR="$R/feed")"; rc=$?
[ "$rc" = 2 ] && grep -q 'is inside the spool root' <<<"$out" && [ ! -e "$R/feed" ] \
  && pass "2. a feed dir inside the spool root is refused" || fail "2. feed in root (rc $rc: $out)"
out="$(feed SHADOW_FEED_AGENTS='c-001 ../x')"; rc=$?
[ "$rc" = 2 ] && grep -q "'../x' is not an agent id" <<<"$out" && pass "2. a bad agent id is refused" || fail "2. bad id (rc $rc: $out)"

# 3. a remote box: rsync is stubbed to read <host>:<path> as a local path.
RR="$T/remote-spool"
mkdir -p "$RR"/c-002/{inbox,outbox,archive}
msg "$RR/c-002/outbox/20261011T110000Z--c-002--remote.json" c-002 c-001 "from the other box" "$ATT"
mkdir -p "$T/stub"
printf '#!/bin/bash\na=(); for x in "$@"; do case "$x" in up:*) a+=("${x#up:}");; down:*) exit 255;; *) a+=("$x");; esac; done\nexec %q "${a[@]}"\n' \
  "$(command -v rsync)" >"$T/stub/rsync"; chmod +x "$T/stub/rsync"
out="$(feed SHADOW_FEED_REMOTES="box-b=up:$RR" SHADOW_FEED_STAGE="$T/stage")"; rc=$?
rem="$F/box-b/c-002/outbox/20261011T110000Z--c-002--remote.json"
[ "$rc" = 0 ] && grep -q '^box-b OK shadow feed .*copied=1 .*files_dropped=1' <<<"$out" && grep -q '"files": \[\]' "$rem" \
  && pass "3. a reachable remote is mirrored under its own box, refs dropped" || fail "3. remote (rc $rc: $out)"
[ "$(stat -c %a "$T/stage")" = 700 ] && pass "3. ...through a stage only this user reads" || fail "3. stage mode $(stat -c %a "$T/stage")"
out="$(feed SHADOW_FEED_REMOTES="box-b=down:$RR" SHADOW_FEED_STAGE="$T/stage")"; rc=$?
[ "$rc" = 0 ] && grep -q 'WARN box-b (down) is unreachable' <<<"$out" && [ -f "$rem" ] \
  && pass "3. an unreachable remote is a WARN and keeps its last mirror" || fail "3. unreachable (rc $rc: $out)"
out="$(feed SHADOW_FEED_REMOTES="box-b")"; rc=$?
[ "$rc" = 2 ] && grep -q "is not <box>=<ssh host>" <<<"$out" && pass "3. a malformed remote is refused" || fail "3. bad remote (rc $rc: $out)"

# 4. the cron line
CT="$T/crontab"
printf '%s\n' '*/5 * * * * bash /x/a.sh # csi-spl:shadow-feed-other' '@reboot /usr/bin/true' >"$CT"
cp "$CT" "$T/crontab.orig"
printf '#!/bin/sh\nif [ "$1" = -l ]; then cat %q; else cp "$1" %q; fi\n' "$CT" "$CT" >"$T/fake-crontab"; chmod +x "$T/fake-crontab"
inst() { SNIPPET='do_spl_shadow_feed_install_cron' in_orc SHADOW_FEED_CRONTAB="$T/fake-crontab" SHADOW_FEED_LOG_DIR="$T/log" SHADOW_FEED_ALLOW_WORKTREE=1 "$@" 2>&1; }
out="$(inst SHADOW_FEED_REMOTES="box-b=box-b.example.net")"
grep -q "^  +\*/5 \* \* \* \* cd .* flock -n $T/log/shadow-feed.lock env SHADOW_FEED_REMOTES='box-b=box-b.example.net' ./run -a do_spl_shadow_feed >> $T/log/shadow-feed.log 2>&1 # csi-spl:shadow-feed\$" <<<"$out" \
  && pass "4. the dry run prints the line" || fail "4. dry-run diff ($out)"
cmp -s "$CT" "$T/crontab.orig" && pass "4. ...and changes nothing" || fail "4. the dry run wrote the crontab"
inst DRY_RUN=0 SHADOW_FEED_REMOTES="box-b=box-b.example.net" >/dev/null
[ "$(grep -c ' # csi-spl:shadow-feed$' "$CT")" = 1 ] && pass "4. DRY_RUN=0 adds one tagged line" || fail "4. tagged lines: $(cat "$CT")"
out="$(inst DRY_RUN=0 SHADOW_FEED_REMOTES="box-b=box-b.example.net")"
grep -q 'OK cron: nothing to change' <<<"$out" && pass "4. a second install is a no-op" || fail "4. second install ($out)"
out="$(inst SHADOW_FEED_REMOTES='box-b=$(id)')"; rc=$?
[ "$rc" = 1 ] && grep -q 'cannot hold' <<<"$out" && pass "4. a value a cron line cannot hold is refused" || fail "4. unsafe value (rc $rc: $out)"
inst DRY_RUN=0 SHADOW_FEED_CRON_ACTION=remove >/dev/null
cmp -s "$CT" "$T/crontab.orig" && pass "4. remove restores the crontab byte for byte" || fail "4. remove ($(cat "$CT"))"

echo "spl-shadow-feed: ${fails} failure(s)"
[ "$fails" -eq 0 ]
