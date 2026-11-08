#!/usr/bin/env bash
# journal-sweep.tst.sh - the journal step vacuums only when DRY_RUN=0.
#   0. box-disk-sweep accepts step journal and dry-runs it (on origin/master
#      the same command exits 2: unknown step 'journal' — the red)
#   1. dry run (the default) plans the vacuum and does not call sudo
#   2. DRY_RUN=0 calls sudo -n journalctl --vacuum-size and prints bytes after
#   3. a PATH with no journalctl fails the live run and removes nothing
#   4. a journald cap above the max is the vacuum size, last assignment wins
#   5. CONTROL: no raised cap (none, equal, lower, commented, reset) = as before
#   6. an unreadable or unparsable SystemMaxUse keeps the max and never fails

set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

JS="$PROJ_ROOT/src/bash/scripts/journal-sweep.sh"
SW="$PROJ_ROOT/src/bash/scripts/box-disk-sweep.sh"

# the journald config as systemd-analyze prints it, never this box's own
mkdir -p "$T/fake"
printf '#!/bin/bash\nprintf "%%b\\n" "${JD_OUT:-}"\nexit "${JD_RC:-0}"\n' >"$T/fake/jd-cat"
chmod +x "$T/fake/jd-cat"
export BOX_SWEEP_JOURNALD_CAT="$T/fake/jd-cat"

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
  *--vacuum-size=*) printf '%s\n' "Vacuuming done" ;;
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

# plan <JD_OUT> [env...] - the size a dry run plans, with that journald config
plan() {
  local jd="$1"; shift
  env JD_OUT="$jd" PATH="$F/bin:$PATH" "$@" bash "$JS" 2>&1 | sed -n 's/.*PLAN journalctl --vacuum-size=//p'
}
same() { [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

same "4. a raised cap (2G) is the vacuum size over the default 500M" "$(plan 'SystemMaxUse=2G')" 2G
same "4. the last assignment wins, as in journald" "$(plan 'SystemMaxUse=4G\nSystemMaxUse=1G')" 1G
: >"$JCTL_LOG"; : >"$SUDO_LOG"
out="$(JD_OUT='[Journal]\nSystemMaxUse=2G' PATH="$F/bin:$PATH" DRY_RUN=0 BOX_SWEEP_JOURNAL_MAX=200M bash "$JS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$SUDO_LOG")" = "journalctl --vacuum-size=2G" ] \
  && pass "4. a live run never vacuums below the cap, an explicit lower max included" \
  || fail "4. live cap (rc $rc: $out / sudo=$(cat "$SUDO_LOG"))"

same "5. CONTROL: no SystemMaxUse keeps 500M" "$(plan '[Journal]')" 500M
same "5. CONTROL: a cap equal to the max keeps 500M" "$(plan 'SystemMaxUse=500M')" 500M
same "5. CONTROL: a lower cap keeps 500M" "$(plan 'SystemMaxUse=200M')" 500M
same "5. CONTROL: a commented cap is no cap" "$(plan '#SystemMaxUse=2G')" 500M
same "5. CONTROL: an empty assignment resets the cap" "$(plan 'SystemMaxUse=2G\nSystemMaxUse=')" 500M
same "5. CONTROL: another key is no cap" "$(plan 'RuntimeMaxUse=2G')" 500M
same "5. CONTROL: an explicit max above the cap stays" "$(plan 'SystemMaxUse=1G' BOX_SWEEP_JOURNAL_MAX=3G)" 3G

for bad in lots 2Q -1G '2G; rm' '1.2.3G'; do
  : >"$JCTL_LOG"; : >"$SUDO_LOG"
  out="$(JD_OUT="SystemMaxUse=$bad" PATH="$F/bin:$PATH" DRY_RUN=0 BOX_SWEEP_JOURNAL_MAX=200M bash "$JS" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [ "$(cat "$SUDO_LOG")" = "journalctl --vacuum-size=200M" ] && grep -q 'WARN' <<<"$out" \
    && pass "6. unparsable SystemMaxUse=$bad keeps the max and the sweep runs" \
    || fail "6. unparsable $bad (rc $rc: $out / sudo=$(cat "$SUDO_LOG"))"
done
: >"$SUDO_LOG"
out="$(JD_OUT='SystemMaxUse=9G' JD_RC=1 PATH="$F/bin:$PATH" DRY_RUN=0 BOX_SWEEP_JOURNAL_MAX=200M bash "$JS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$SUDO_LOG")" = "journalctl --vacuum-size=200M" ] \
  && pass "6. a failed config read keeps the max and the sweep runs" || fail "6. failed read (rc $rc: $out / sudo=$(cat "$SUDO_LOG"))"
same "6. a missing reader keeps the max" "$(plan 'SystemMaxUse=9G' BOX_SWEEP_JOURNALD_CAT="$T/fake/no-such")" 500M
mkdir -p "$F/noawk"; ln -s /usr/bin/date "$F/noawk/date"; ln -s "$F/bin/journalctl" "$F/noawk/journalctl"; ln -s /usr/bin/sed "$F/noawk/sed"
out="$(JD_OUT='SystemMaxUse=9G' PATH="$F/noawk" /usr/bin/bash "$JS" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'PLAN journalctl --vacuum-size=500M' <<<"$out" \
  && pass "6. a box with no awk keeps the max" || fail "6. no awk (rc $rc: $out)"

echo "journal-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]
