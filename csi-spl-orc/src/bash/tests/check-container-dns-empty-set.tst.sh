#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_container_dns treats a NON-EMPTY host resolver set with an
#          EMPTY container set (a tf-runner resolv.conf with no nameserver
#          line, e.g. "NO EXTERNAL NAMESERVERS DEFINED") as a mismatch and
#          takes the restart path; an EMPTY host set and an unreadable
#          container resolv.conf stay a skip. DRY_RUN=1 and a docker stub:
#          nothing real is restarted.
#------------------------------------------------------------------------------
set -uo pipefail
# The expected set strings below are in C collation order (sort -u in the
# resolver helpers follows the locale): pin it so en_US hosts agree.
export LC_ALL=C
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# stub docker: info ok; inspect -f -> running; inspect <name> ok for the
# tf-runner only; exec ... cat /etc/resolv.conf -> $CON_RESOLV_FILE; restart
# is recorded in $DOCKER_RESTARTS.
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  inspect)
    [[ "$2" == "-f" ]] && { echo true; exit 0; }
    [[ "$2" == "con-test-tf-runner" ]] ;;
  exec) cat "$CON_RESOLV_FILE" 2>/dev/null; exit 0 ;;
  restart) shift; echo "$*" >>"$DOCKER_RESTARTS"; exit 0 ;;
  *) exit 1 ;;
esac
STUB
# stub resolvectl: no upstreams, so the box's own resolver never leaks in
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/resolvectl"
chmod +x "$work/bin/docker" "$work/bin/resolvectl"

# $1 = host resolv.conf text, $2 = container resolv.conf text; prints rc,
# the log goes to $work/log
run_check() {
  rm -f "$work/log" "$work/restarts"
  printf '%s' "$1" >"$work/host.conf"
  printf '%s' "$2" >"$work/con.conf"
  (
    PATH="$work/bin:$PATH"
    CON_RESOLV_FILE="$work/con.conf" DOCKER_RESTARTS="$work/restarts"
    export CON_RESOLV_FILE DOCKER_RESTARTS
    export CON_TF_RUNNER=con-test-tf-runner HOST_RESOLV_CONF="$work/host.conf"
    export DRY_RUN=1 DNS_CHECK_FORCE_HOST=1 SKIP_CONTAINER_DNS_CHECK=0
    do_log() { echo "$*" >>"$work/log"; }
    # shellcheck disable=SC1091
    source "$PROJ_ROOT/lib/bash/funcs/dns-resolver-sets.func.sh"
    # shellcheck disable=SC1091
    source "$PROJ_ROOT/src/bash/run/check-container-dns.func.sh"
    do_check_container_dns
    echo "$?"
  )
}

host='nameserver 10.0.0.1
nameserver 1.1.1.1
'
no_ext='# NO EXTERNAL NAMESERVERS DEFINED
search example.com
options ndots:0
'

rc=$(run_check "$host" "$no_ext")
[[ "$rc" == 0 ]] && pass "empty container set: rc 0 (DRY_RUN)" || fail "empty container set: rc $rc"
grep -q '^INFO DRY_RUN: would docker restart con-test-tf-runner$' "$work/log" 2>/dev/null \
  && pass "empty container set + host set: would docker restart" \
  || fail "empty container set + host set: no 'would docker restart' line; log: $(cat "$work/log" 2>/dev/null)"
grep -q 'skipping' "$work/log" 2>/dev/null \
  && fail "empty container set: logged a skip" || pass "empty container set: no skip logged"
[[ ! -s "$work/restarts" ]] && pass "DRY_RUN=1: docker restart never called" \
  || fail "DRY_RUN=1: docker restart called: $(cat "$work/restarts")"

rc=$(run_check '' 'nameserver 1.1.1.1
')
[[ "$rc" == 0 ]] && pass "empty host set: rc 0" || fail "empty host set: rc $rc"
grep -q "^WARN host resolver set empty (container '1.1.1.1') — skipping container DNS check$" "$work/log" 2>/dev/null \
  && pass "empty host set: skipped" || fail "empty host set: no skip line; log: $(cat "$work/log" 2>/dev/null)"
grep -q 'would docker restart' "$work/log" 2>/dev/null \
  && fail "empty host set: took the restart path" || pass "empty host set: no restart path"

run_check "$host" '' >/dev/null
grep -q '^WARN could not read con-test-tf-runner /etc/resolv.conf — skipping container DNS check$' "$work/log" 2>/dev/null \
  && pass "unreadable container resolv.conf: skipped" \
  || fail "unreadable container resolv.conf: no skip line; log: $(cat "$work/log" 2>/dev/null)"

run_check "$host" 'nameserver 1.1.1.1
nameserver 10.0.0.1
' >/dev/null
grep -q '^OK container DNS matches host (1.1.1.1 10.0.0.1)$' "$work/log" 2>/dev/null \
  && pass "equal sets: OK, no restart" || fail "equal sets: log: $(cat "$work/log" 2>/dev/null)"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
