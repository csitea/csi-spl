#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a bare source of check-container-dns.func.sh (no ./run, so
#          lib/bash/funcs is not loaded) still finds the resolver-set helpers:
#          _dns_ensure_helpers loads lib/bash/funcs/dns-resolver-sets.func.sh,
#          and do_check_container_dns runs its mismatch path end to end.
#          DRY_RUN=1 and a docker stub: nothing real is restarted.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
func="$PROJ_ROOT/src/bash/run/check-container-dns.func.sh"

# 1. clean shell: helpers not defined before, defined after _dns_ensure_helpers
# shellcheck disable=SC2016
out=$(env -i PATH="$PATH" HOME="$work" bash --noprofile --norc -c '
  declare -f _dns_normalize_set >/dev/null 2>&1 && { echo PRE-DEFINED; exit 2; }
  source "$1" || exit 3
  _dns_ensure_helpers 2>&1 || exit 4
  for f in _dns_normalize_set _dns_host_nameservers_from_file \
    _dns_container_nameservers_from_resolv; do
    declare -f "$f" >/dev/null 2>&1 || { echo "MISSING $f"; exit 5; }
  done
  echo OK' _ "$func" 2>&1)
rc=$?
if [[ $rc -eq 0 && "$out" == *OK ]]; then
  pass "bare source: _dns_ensure_helpers defines the resolver helpers"
else
  fail "bare source: rc $rc, out: $out"
fi

# 2. bare source, mismatch path end to end (docker + resolvectl stubbed)
mkdir -p "$work/bin"
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
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/bin/resolvectl"
chmod +x "$work/bin/docker" "$work/bin/resolvectl"
printf 'nameserver 10.0.0.1\n' >"$work/host.conf"
printf 'nameserver 1.1.1.1\n' >"$work/con.conf"
# shellcheck disable=SC2016
env -i PATH="$work/bin:$PATH" HOME="$work" \
  CON_RESOLV_FILE="$work/con.conf" DOCKER_RESTARTS="$work/restarts" \
  CON_TF_RUNNER=con-test-tf-runner HOST_RESOLV_CONF="$work/host.conf" \
  DRY_RUN=1 DNS_CHECK_FORCE_HOST=1 SKIP_CONTAINER_DNS_CHECK=0 LOG="$work/log" \
  bash --noprofile --norc -c '
  do_log() { echo "$*" >>"$LOG"; }
  source "$1"
  do_check_container_dns' _ "$func" >"$work/out" 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
  pass "bare source: do_check_container_dns rc 0"
else
  fail "bare source: do_check_container_dns rc $rc: $(cat "$work/out")"
fi
if grep -q '^INFO DRY_RUN: would docker restart con-test-tf-runner$' "$work/log" 2>/dev/null; then
  pass "bare source: mismatch takes the restart path"
else
  fail "bare source: no restart line; log: $(cat "$work/log" 2>/dev/null) out: $(cat "$work/out")"
fi
if [[ ! -s "$work/restarts" ]]; then
  pass "DRY_RUN=1: docker restart never called"
else
  fail "DRY_RUN=1: docker restart called: $(cat "$work/restarts")"
fi

if [[ $fails -eq 0 ]]; then
  echo "PASS: all check-container-dns-helpers-source.tst.sh assertions"
else
  echo "FAIL: $fails check-container-dns-helpers-source.tst.sh assertion(s)"
  exit 1
fi
