#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a bare source of check-container-dns.func.sh (no ./run, so
#          lib/bash/funcs is not loaded) still finds the resolver-set helpers:
#          _dns_ensure_helpers loads lib/bash/funcs/dns-resolver-sets.func.sh,
#          and do_check_container_dns runs its mismatch path end to end, also
#          through a symlinked copy; with the lib file absent it fails fast
#          (rc 1, ERROR) instead of skipping. Under ./run the lib helpers are
#          lazy stubs, so a syntax-broken lib must still fail (rc 1, ERROR),
#          never skip. DRY_RUN=1 and a docker stub: nothing real is restarted.
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

# $1 = the action file to source bare; prints rc; log in $work/log,
# stdout+stderr in $work/out, docker restarts in $work/restarts
run_action() {
  rm -f "$work/log" "$work/out" "$work/restarts"
  # shellcheck disable=SC2016
  env -i PATH="$work/bin:$PATH" HOME="$work" \
    CON_RESOLV_FILE="$work/con.conf" DOCKER_RESTARTS="$work/restarts" \
    CON_TF_RUNNER=con-test-tf-runner HOST_RESOLV_CONF="$work/host.conf" \
    DRY_RUN=1 DNS_CHECK_FORCE_HOST=1 SKIP_CONTAINER_DNS_CHECK=0 LOG="$work/log" \
    bash --noprofile --norc -c '
    do_log() { echo "$*" >>"$LOG"; }
    source "$1"
    do_check_container_dns' _ "$1" >"$work/out" 2>&1
  echo "$?"
}
restart_line='^INFO DRY_RUN: would docker restart con-test-tf-runner$'

rc=$(run_action "$func")
if [[ $rc -eq 0 ]]; then
  pass "bare source: do_check_container_dns rc 0"
else
  fail "bare source: do_check_container_dns rc $rc: $(cat "$work/out")"
fi
if grep -q "$restart_line" "$work/log" 2>/dev/null; then
  pass "bare source: mismatch takes the restart path"
else
  fail "bare source: no restart line; log: $(cat "$work/log" 2>/dev/null) out: $(cat "$work/out")"
fi
if [[ ! -s "$work/restarts" ]]; then
  pass "DRY_RUN=1: docker restart never called"
else
  fail "DRY_RUN=1: docker restart called: $(cat "$work/restarts")"
fi

# 3. symlinked action file: the helpers still come from the real tree's lib
mkdir -p "$work/elsewhere"
ln -s "$func" "$work/elsewhere/check-container-dns.func.sh"
rc=$(run_action "$work/elsewhere/check-container-dns.func.sh")
if [[ $rc -eq 0 ]] && grep -q "$restart_line" "$work/log" 2>/dev/null; then
  pass "symlinked source: helpers load, mismatch takes the restart path"
else
  fail "symlinked source: rc $rc; log: $(cat "$work/log" 2>/dev/null) out: $(cat "$work/out")"
fi

# 4. lib file absent: fail fast (rc 1, ERROR logged), never a silent skip
mkdir -p "$work/tree/src/bash/run" "$work/tree/lib/bash/funcs"
cp "$func" "$work/tree/src/bash/run/"
rc=$(run_action "$work/tree/src/bash/run/check-container-dns.func.sh")
if [[ $rc -ne 0 ]]; then
  pass "lib absent: do_check_container_dns fails (rc $rc)"
else
  fail "lib absent: rc 0; log: $(cat "$work/log" 2>/dev/null)"
fi
if grep -q '^ERROR resolver-set helpers not loaded from ' "$work/log" 2>/dev/null; then
  pass "lib absent: ERROR names the lib file"
else
  fail "lib absent: no ERROR line; log: $(cat "$work/log" 2>/dev/null) out: $(cat "$work/out")"
fi
if grep -q 'skipping' "$work/log" 2>/dev/null; then
  fail "lib absent: logged a silent skip: $(cat "$work/log")"
else
  pass "lib absent: no skip logged"
fi

# 5. through ./run (a minimal tree: run.sh, this action, lib/bash/funcs):
# the lib helpers are lazy stubs there, so `declare -f` alone is no proof.
# Lib intact: the mismatch path runs. Lib syntax-broken: rc 1 + ERROR.
tree="$work/runtree"
mkdir -p "$tree/src/bash/run" "$tree/lib/bash"
cp "$PROJ_ROOT/src/bash/run/run.sh" "$func" "$tree/src/bash/run/"
cp -r "$PROJ_ROOT/lib/bash/funcs" "$tree/lib/bash/"
ln -s src/bash/run/run.sh "$tree/run"
# prints rc; stdout+stderr in $work/out, docker restarts in $work/restarts
run_via_run() {
  rm -f "$work/out" "$work/restarts"
  (cd "$tree" && env -i PATH="$work/bin:$PATH" HOME="$work" \
    CON_RESOLV_FILE="$work/con.conf" DOCKER_RESTARTS="$work/restarts" \
    CON_TF_RUNNER=con-test-tf-runner HOST_RESOLV_CONF="$work/host.conf" \
    DRY_RUN=1 DNS_CHECK_FORCE_HOST=1 SKIP_CONTAINER_DNS_CHECK=0 \
    ./run -a do_check_container_dns) >"$work/out" 2>&1
  echo "$?"
}
rc=$(run_via_run)
if [[ $rc -eq 0 ]] && grep -q 'DRY_RUN: would docker restart con-test-tf-runner' "$work/out"; then
  pass "./run, lib intact: mismatch takes the restart path"
else
  fail "./run, lib intact: rc $rc; out: $(cat "$work/out")"
fi
sed -i '/^_dns_normalize_set() {/a if true; then' \
  "$tree/lib/bash/funcs/dns-resolver-sets.func.sh"
rc=$(run_via_run)
if [[ $rc -ne 0 ]] && grep -q 'ERROR resolver-set helpers not loaded from ' "$work/out"; then
  pass "./run, lib syntax-broken: fails (rc $rc) with ERROR"
else
  fail "./run, lib syntax-broken: rc $rc; out: $(cat "$work/out")"
fi
if grep -q 'skipping' "$work/out"; then
  fail "./run, lib syntax-broken: logged a silent skip: $(cat "$work/out")"
else
  pass "./run, lib syntax-broken: no skip logged"
fi
if [[ ! -s "$work/restarts" ]]; then
  pass "./run: docker restart never called"
else
  fail "./run: docker restart called: $(cat "$work/restarts")"
fi

if [[ $fails -eq 0 ]]; then
  echo "PASS: all check-container-dns-helpers-source.tst.sh assertions"
else
  echo "FAIL: $fails check-container-dns-helpers-source.tst.sh assertion(s)"
  exit 1
fi
