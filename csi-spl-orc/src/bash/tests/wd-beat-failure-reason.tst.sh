#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4017, a beat with no ack says why, in beat.log and wd.log.
#          one box 2026-10-28 06:50-07:19Z: every beat failed in ~40 ms, the box
#          was fenced and 9 lanes TERMed, and wd.log said only "no answer"
#          because spl_wd_beat dropped the call's rc and stderr. The hub is a
#          WD_BEAT_CMD stub (sandbox; no live watchdog, no network).
#   1. a stub that prints "curl: (6) Could not resolve host" to stderr and
#      exits 6 -> the BEAT line carries rc=6 and that text, wd.log's "no
#      ack" line too
#   2. a stub whose stderr carries "Authorization: Bearer abc123" and a
#      token= value -> both masked (***), abc123 nowhere in either log
#   3. Go's dial error (the spool binary) -> ip= the address it dialled
#      (IPv6 and IPv4); a stderr line past 160 bytes is cut, one line
#   4. a timeout (no stderr) -> rc=124 err=-
#   5. an ok beat logs as before: no rc=, no err=
#   RED control: the code before (`2>/dev/null`, no rc) fails 1-4
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
RUN_DIR="$PROJ_ROOT/src/bash/run"
T0=1800000000   # 2027-01-15T08:00:00Z
mkdir -p "$T/bin"
export T

# the hub: "$T/hub" holds the mode; "$T/err" the stderr line of a failing mode
cat > "$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
case "$(cat "$T/hub")" in
  ok)   echo '{"ok":true,"box":"box1","beat_at":"2027-01-15T08:00:00Z","box_down_min":2}' ;;
  fail) cat "$T/err" >&2; exit 6 ;;
  hang) sleep 5 ;;
esac
STUB
chmod +x "$T/bin/hub"

# beat MODE [ERR]: one spl_wd_beat in a fresh shell over a fresh sandbox
beat() {
  rm -rf "$T/wd" "$T/wd.log"; mkdir -p "$T/wd"
  echo "$1" > "$T/hub"; printf '%s\n' "${2:-}" "a second line" > "$T/err"
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-watchdog.func.sh
    source "$RUN_DIR/spl-watchdog.func.sh"
    export WD_DIR="$T/wd" WD_LOG="$T/wd.log" WD_BEAT_CMD="$T/bin/hub" WD_BEAT_TIMEOUT=1
    spl_wd_beat "$T0" )
}
bl() { tail -n 1 "$T/wd/beat.log" 2>/dev/null; }
nl() { grep 'no ack' "$T/wd.log" 2>/dev/null | tail -n 1; }

# ---- 1. curl rc 6 ------------------------------------------------------------
beat fail "curl: (6) Could not resolve host: api.example.net"
[[ "$(bl)" == *" ack=none ms="*" rc=6 err=curl: (6) Could not resolve host: api.example.net" ]] &&
  pass "1. beat.log: rc=6 and the stderr line" || fail "1. beat.log: $(bl)"
[[ "$(nl)" == *"rc=6 err=curl: (6) Could not resolve host"* ]] &&
  pass "1. wd.log no ack line names rc and err" || fail "1. wd.log: $(nl)"
grep -q "a second line" "$T/wd/beat.log" "$T/wd.log" &&
  fail "1. only the first stderr line is kept" || pass "1. only the first stderr line is kept"
[[ -z "$(find "$T/wd" -name 'beat.err.*')" ]] && pass "1. no stderr file left behind" || fail "1. left: $(ls "$T/wd")"

# ---- 2. a credential is masked -----------------------------------------------
beat fail 'HTTP 401: Authorization: Bearer abc123 token=abc123&x=1'
[[ "$(bl)" == *"err=HTTP 401: Authorization: *** *** token=***&x=1" ]] &&
  pass "2. Bearer and token= values masked" || fail "2. beat.log: $(bl)"
grep -q abc123 "$T/wd/beat.log" "$T/wd.log" && fail "2. abc123 leaked: $(grep -h abc123 "$T/wd/beat.log" "$T/wd.log")" ||
  pass "2. abc123 in neither log"

# ---- 3. the dialled address --------------------------------------------------
beat fail 'spool: Post "https://api.example.net/v1/lane": dial tcp [2001:db8:4802:32::15]:443: connect: network is unreachable'
[[ "$(bl)" == *" ip=2001:db8:4802:32::15" ]] && pass "3. IPv6 dial: ip= the address" || fail "3. v6: $(bl)"
beat fail 'spool: Post "https://api.example.net/v1/lane": dial tcp 192.0.2.21:443: i/o timeout'
[[ "$(bl)" == *" ip=192.0.2.21" ]] && pass "3. IPv4 dial: ip= the address" || fail "3. v4: $(bl)"
beat fail "spool: $(printf 'x%.0s' {1..300}) dial tcp 192.0.2.9:443: refused"
e="$(bl)"; e="${e#* err=}"; e="${e% ip=*}"
(( ${#e} == 160 )) && [[ "$(bl)" == *" ip=192.0.2.9" && "$(wc -l < "$T/wd/beat.log")" == 1 ]] &&
  pass "3. a long line is cut to 160 bytes, one line, ip kept" || fail "3. long: ${#e} bytes: $(bl)"

# ---- 4. a timeout ------------------------------------------------------------
beat hang
[[ "$(bl)" == *" ack=none ms="*" rc=124 err=-" ]] && pass "4. timeout: rc=124 err=-" || fail "4. timeout: $(bl)"

# ---- 5. an ok beat logs as before --------------------------------------------
beat ok
ok_re='^BEAT - tick=2027-01-15T08:00:00.000Z sent=20[^ ]*Z ack=20[^ ]*Z ms=[0-9]+$'
[[ "$(bl)" =~ $ok_re ]] && [[ ! -s "$T/wd.log" ]] &&
  pass "5. ok beat: the line as before, no rc/err, no wd.log line" || fail "5. ok: $(bl) | $(cat "$T/wd.log" 2>/dev/null)"
[[ "$(cat "$T/wd/beat.ack")" == "$T0" ]] && pass "5. the ack is kept" || fail "5. beat.ack=$(cat "$T/wd/beat.ack" 2>/dev/null)"

if (( fails )); then echo "wd-beat-failure-reason: $fails FAILED"; exit 1; fi
echo "wd-beat-failure-reason: all passed"
