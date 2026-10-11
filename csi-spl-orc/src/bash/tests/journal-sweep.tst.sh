#!/usr/bin/env bash
# journal-sweep.tst.sh - the journal step vacuums only when DRY_RUN=0.
#   0. box-disk-sweep accepts step journal and dry-runs it (on origin/master
#      the same command exits 2: unknown step 'journal' — the red)
#   1. dry run (the default) plans the vacuum and does not call sudo
#   2. DRY_RUN=0 calls sudo -n journalctl --vacuum-size and prints bytes after
#   3. a PATH with no journalctl fails the live run and removes nothing

set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

JS="$PROJ_ROOT/src/bash/scripts/journal-sweep.sh"
SW="$PROJ_ROOT/src/bash/scripts/box-disk-sweep.sh"

out="$(DRY_RUN=1 BOX_SWEEP_STEPS=journal BOX_SWEEP_LOCK="$T/j.lock" BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 bash "$SW" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q 'PLAN journalctl --vacuum-size=500M' <<<"$out" \
  && ! grep -q 'DONE journalctl' <<<"$out" \
  && pass "0. the sweep dry-runs step journal (red on origin/master: unknown step)" \
  || fail "0. sweep journal (rc $rc: $out)"

F="$T/fake"
mkdir -p "$F/bin" "$F/dateonly"
ln -s /usr/bin/date "$F/dateonly/date"
cat >"$F/bin/journalctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$JCTL_LOG"
case "$*" in
  *--disk-usage*) printf '%s\n' "Archived and active journals take up 300B in the file system." ;;
  *--vacuum-size=200M*) printf '%s\n' "Vacuuming done" ;;
  *) printf 'FAIL: journalctl %s\n' "$*" >&2; exit 1 ;;
esac
EOF
cat >"$F/bin/sudo" <<'EOF'
#!/bin/bash
if [[ "${1:-}" == -n ]]; then shift; fi
printf '%s\n' "$*" >>"$SUDO_LOG"
exec "$@"
EOF
chmod +x "$F/bin/journalctl" "$F/bin/sudo"
export JCTL_LOG="$T/jctl.log" SUDO_LOG="$T/sudo.log"

: >"$JCTL_LOG"; : >"$SUDO_LOG"
out="$(PATH="$F/bin:$PATH" BOX_SWEEP_JOURNAL_MAX=200M bash "$JS" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q 'PLAN journalctl --vacuum-size=200M' <<<"$out" \
  && grep -q 'before=300' <<<"$out" && [ ! -s "$SUDO_LOG" ] \
  && ! grep -q -- '--vacuum-size' "$JCTL_LOG" \
  && pass "1. dry run (default) plans the vacuum and does not call sudo" \
  || fail "1. dry run (rc $rc: $out / sudo=$(cat "$SUDO_LOG") jctl=$(cat "$JCTL_LOG"))"

: >"$JCTL_LOG"; : >"$SUDO_LOG"
out="$(PATH="$F/bin:$PATH" DRY_RUN=0 BOX_SWEEP_JOURNAL_MAX=200M bash "$JS" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q 'DONE journalctl --vacuum-size=200M rc=0 after=300' <<<"$out" \
  && [ "$(cat "$SUDO_LOG")" = "journalctl --vacuum-size=200M" ] \
  && pass "2. live run vacuums to the max size through sudo -n" \
  || fail "2. live run (rc $rc: $out / sudo=$(cat "$SUDO_LOG"))"

out="$(PATH="$F/dateonly" DRY_RUN=0 BOX_SWEEP_JOURNAL_MAX=200M /usr/bin/bash "$JS" 2>&1)"
rc=$?
[ "$rc" = 1 ] && grep -q 'FAIL journalctl not found' <<<"$out" \
  && pass "3. journalctl not found" || fail "3. journalctl not found (rc $rc: $out)"

echo "journal-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]
