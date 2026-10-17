#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-03: public HTTPS certificate expiry check (SPL-2231).
# do_net_cert_expiry_check runs against real self-signed certificates made
# here (openssl req -days N), a stub fetch command, a stub sender and a temp
# SPOOL_ROOT / state dir. No packet leaves the box, no spool message is sent.
#   1. 63 d -> OK, 14 d -> WARNING, 3 d -> CRITICAL, rc 0; days = enddate
#   2. DRY_RUN=1 (default) plans the alerts, sends nothing, writes no stamp
#   3. DRY_RUN=0 sends one note per not-OK host to the orchestrator
#   4. Throttle: same level again -> no note; a level change -> one note;
#      a stale stamp -> one note; an OK host clears its stamp
#   5. No certificate -> ERROR, one note
#   6. Hosts from the cnf: [sub.]api.<BASE_DOMAIN> and [sub.]<BASE_DOMAIN> per env
#   7. The repo cnf gives 4 hosts under its BASE_DOMAIN
#   8. Fetches run in parallel: 4 hosts x 1 s finish in < 2 s
#   9. Usage errors -> rc 1 FATAL
#  10. ./run -a do_net_cert_expiry_check through the csi-spl-utl harness
#  11. RED CONTROL: with no CERT_EXPIRY_SEND_CMD the real-run default resolves
#      spool-send.sh under PROJ_PATH, here a sentinel that records calls; the
#      sentinel MUST see that one call, so it would see any other.
#  12. LIVE GUARD: no call reached a spool-send.sh outside this test's temp
#      dir, nor the spool binary (PATH shims record and refuse them), and the
#      temp SPOOL_ROOT received nothing.
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="${CERT_EXPIRY_TST_FUNC_SH:-$UTL_ROOT/src/bash/run/net-cert-expiry-check.func.sh}"
REPO_CNF_DIR="$UTL_ROOT/../csi-spl-cnf/csi-spl"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
BIN="$T/bin" CERTS="$T/certs" STATE="$T/state"
SENT="$T/sent.log" SENTINEL_LOG="$T/sentinel.log" LIVE_LOG="$T/live-calls.log"
mkdir -p "$BIN" "$CERTS" "$T/spool"
: >"$SENT"; : >"$SENTINEL_LOG"; : >"$LIVE_LOG"

# A self-signed certificate of <host> valid for <days>
mkcert() {
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout /dev/null -out "$CERTS/$1.pem" -days "$2" -subj "/CN=$1" >/dev/null 2>&1
}
mkcert ok.example.test 63
mkcert warn.example.test 14
mkcert crit.example.test 3

# fetch <host>: the PEM of <host>; none for nocert*, 1 s late for slow*
cat >"$BIN/fetch" <<EOF
#!/bin/bash
[[ "\$1" == slow* ]] && { sleep 1; cat "$CERTS/ok.example.test.pem"; exit 0; }
[[ -f "$CERTS/\$1.pem" ]] || exit 1
cat "$CERTS/\$1.pem"
EOF
# send: the stub sender, one line per call
cat >"$BIN/send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$SENT"
EOF
# The sentinel "real" spool-send.sh the default resolves to under PROJ_PATH
mkdir -p "$T/repo/csi-spl-utl" "$T/repo/csi-spl-orc/src/bash/features/spawn-agents/scripts"
cat >"$T/repo/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >>"$SENTINEL_LOG"
EOF
# LIVE GUARD shims: bash running a spool-send.sh outside \$T, and the spool
# binary, are recorded and refused (never executed)
cat >"$BIN/bash" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == */spool-send.sh && "\$a" != "$T"/* ]]; then
    printf 'bash %s\n' "\$*" >>"$LIVE_LOG"; exit 97
  fi
done
exec /bin/bash "\$@"
EOF
cat >"$BIN/spool" <<EOF
#!/bin/bash
printf 'spool %s\n' "\$*" >>"$LIVE_LOG"; exit 97
EOF
cat >"$BIN/spool-send.sh" <<EOF
#!/bin/bash
printf 'spool-send.sh %s\n' "\$*" >>"$LIVE_LOG"; exit 97
EOF
chmod +x "$BIN"/* "$T/repo/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"

export PATH="$BIN:$PATH" SPOOL_ROOT="$T/spool" SPOOL_TEST=1
export PROJ_PATH="$T/repo/csi-spl-utl" CERT_EXPIRY_STATE_DIR="$STATE"
export CERT_EXPIRY_FETCH_CMD="$BIN/fetch" CERT_EXPIRY_SEND_CMD="$BIN/send"
export CERT_EXPIRY_ALERT_FROM="cert-expiry-check@test"
unset DRY_RUN CERT_EXPIRY_HOSTS CERT_EXPIRY_ENVS CERT_EXPIRY_CNF_DIR CERT_EXPIRY_THROTTLE_S SPOOL_AGENT_ID

# shellcheck source=/dev/null
run_check() { ( source "$FUNC_SH"; do_net_cert_expiry_check ) 2>&1; }
sent_n() { wc -l <"$SENT"; }

# The days the check must print, measured independently from -enddate
want_days() {
  local end; end=$(openssl x509 -noout -enddate -in "$CERTS/$1.pem"); end=${end#notAfter=}
  echo $(( ($(date -u -d "$end" +%s) - $(date +%s)) / 86400 ))
}

# 1 -------------------------------------------------------------------------
# the printed days of <host> <level>, and whether it lies between the
# -enddate days measured after (lo) and before (hi) the run
got_days() { sed -n "s/.*cert-expiry $1 $2 days=\([0-9-]*\) .*/\1/p" <<<"$3"; }
in_range() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= $2 && $1 <= $3 )); }
H3="ok.example.test warn.example.test crit.example.test"
b_ok=$(want_days ok.example.test) b_w=$(want_days warn.example.test) b_c=$(want_days crit.example.test)
out=$(CERT_EXPIRY_HOSTS="$H3" run_check); rc=$?
a_ok=$(want_days ok.example.test) a_w=$(want_days warn.example.test) a_c=$(want_days crit.example.test)
d_ok=$(got_days ok.example.test OK "$out") d_w=$(got_days warn.example.test WARNING "$out") d_c=$(got_days crit.example.test CRITICAL "$out")
if [[ $rc -eq 0 ]] && in_range "$d_ok" "$a_ok" "$b_ok" && in_range "$d_w" "$a_w" "$b_w" && in_range "$d_c" "$a_c" "$b_c" \
   && grep -q "hosts=3 not_ok=2 " <<<"$out" && (( a_ok >= 62 && b_ok <= 63 && a_w >= 13 && b_w <= 14 && a_c >= 2 && b_c <= 3 )); then
  pass "1. 63 d OK ($d_ok), 14 d WARNING ($d_w), 3 d CRITICAL ($d_c): days = openssl -enddate"
else
  fail "1. thresholds (rc=$rc ok=$d_ok/$a_ok..$b_ok w=$d_w/$a_w..$b_w c=$d_c/$a_c..$b_c out=$out)"
fi

# 2 -------------------------------------------------------------------------
if [[ $(sent_n) -eq 0 && ! -d "$STATE" ]] && [[ $(grep -c "INFO PLAN note to orchestrator on task cert-expiry" <<<"$out") -eq 2 ]]; then
  pass "2. DRY_RUN=1 (default): 2 alerts planned, 0 sent, no stamp"
else
  fail "2. dry run (sent=$(sent_n) out=$out)"
fi

# 3 -------------------------------------------------------------------------
out=$(DRY_RUN=0 CERT_EXPIRY_HOSTS="$H3" run_check); rc=$?
if [[ $rc -eq 0 && $(sent_n) -eq 2 ]] \
   && grep -q -- "--from cert-expiry-check@test --to orchestrator --kind note --task cert-expiry --body cert-expiry WARNING: the TLS certificate of warn.example.test expires in [0-9]* day(s)" "$SENT" \
   && grep -q -- "--body cert-expiry CRITICAL: the TLS certificate of crit.example.test expires in [0-9]* day(s)" "$SENT" \
   && [[ -f "$STATE/warn.example.test.stamp" && -f "$STATE/crit.example.test.stamp" && ! -f "$STATE/ok.example.test.stamp" ]]; then
  pass "3. DRY_RUN=0: 2 notes to the orchestrator through the stub sender, 2 stamps"
else
  fail "3. real run (rc=$rc sent=$(cat "$SENT") out=$out)"
fi

# 4 -------------------------------------------------------------------------
out=$(DRY_RUN=0 CERT_EXPIRY_HOSTS="$H3" run_check)
n1=$(sent_n)
mkcert warn.example.test 5
out2=$(DRY_RUN=0 CERT_EXPIRY_HOSTS="warn.example.test" run_check)
n2=$(sent_n)
out3=$(DRY_RUN=0 CERT_EXPIRY_THROTTLE_S=0 CERT_EXPIRY_HOSTS="crit.example.test" run_check)
n3=$(sent_n)
mkcert crit.example.test 63
out4=$(DRY_RUN=0 CERT_EXPIRY_HOSTS="crit.example.test" run_check)
if [[ $n1 -eq 2 && $(grep -c "alert throttled" <<<"$out") -eq 2 ]] \
   && [[ $n2 -eq 3 ]] && [[ $(grep -c "CRITICAL: the TLS certificate of warn.example.test" "$SENT") -eq 1 ]] \
   && [[ $n3 -eq 4 ]] && grep -q "crit.example.test OK" <<<"$out4" && [[ ! -f "$STATE/crit.example.test.stamp" ]]; then
  pass "4. throttle: same level 0 notes, level change 1, stale stamp 1; OK clears the stamp"
else
  fail "4. throttle (n1=$n1 n2=$n2 n3=$n3 out=$out out2=$out2 out3=$out3 out4=$out4)"
fi

# 5 -------------------------------------------------------------------------
: >"$SENT"
out=$(DRY_RUN=0 CERT_EXPIRY_HOSTS="nocert.example.test" run_check); rc=$?
if [[ $rc -eq 0 && $(sent_n) -eq 1 ]] && grep -q "WARN cert-expiry nocert.example.test ERROR days=- notAfter=no-certificate" <<<"$out" \
   && grep -q "cert-expiry ERROR: no certificate could be read from nocert.example.test:443" "$SENT"; then
  pass "5. no certificate: ERROR, one note, rc 0"
else
  fail "5. no certificate (rc=$rc out=$out)"
fi

# 6 -------------------------------------------------------------------------
mkdir -p "$T/cnf"
printf 'env:\n  dns:\n    BASE_DOMAIN: example.test\n' >"$T/cnf/all.env.yaml"
printf 'env:\n  dns:\n    env_subdomain: "dev"\n' >"$T/cnf/dev.env.yaml"
printf 'env:\n  dns:\n    env_subdomain: ""\n' >"$T/cnf/prd.env.yaml"
# shellcheck source=/dev/null
hosts=$( (source "$FUNC_SH"; CERT_EXPIRY_CNF_DIR="$T/cnf" cert_expiry_cnf_hosts) 2>&1)
if [[ "$(echo $hosts)" == "dev.api.example.test dev.example.test api.example.test example.test" ]]; then
  pass "6. cnf hosts: dev.api, dev, api and the apex of BASE_DOMAIN"
else
  fail "6. cnf hosts ($hosts)"
fi

# 7 -------------------------------------------------------------------------
base=$(yq -r '.env.dns.BASE_DOMAIN' "$REPO_CNF_DIR/all.env.yaml" 2>/dev/null)
# shellcheck source=/dev/null
hosts=$( (source "$FUNC_SH"; CERT_EXPIRY_CNF_DIR="$REPO_CNF_DIR" cert_expiry_cnf_hosts) 2>&1)
read -ra hl <<<"$hosts"
nb=0; for h in "${hl[@]}"; do [[ "$h" == *"$base" ]] && nb=$((nb + 1)); done
if [[ -n "$base" && ${#hl[@]} -eq 4 && $nb -eq 4 ]] && [[ " $hosts " == *" api.$base "* && " $hosts " == *" $base "* ]]; then
  pass "7. repo cnf: 4 hosts under its BASE_DOMAIN, incl. api.<B> and <B>"
else
  fail "7. repo cnf (base=$base hosts=$hosts)"
fi

# 8 -------------------------------------------------------------------------
s=$EPOCHREALTIME
out=$(CERT_EXPIRY_HOSTS="slow1.example.test slow2.example.test slow3.example.test slow4.example.test" run_check); rc=$?
e=$EPOCHREALTIME
ms=$(( (${e/[.,]/} - ${s/[.,]/}) / 1000 ))
if [[ $rc -eq 0 && $ms -lt 2000 ]] && [[ $(grep -c " OK days=" <<<"$out") -eq 4 ]]; then
  pass "8. 4 hosts x 1 s fetched in parallel: ${ms} ms (< 2000)"
else
  fail "8. parallel fetch (rc=$rc ms=$ms out=$out)"
fi

# 9 -------------------------------------------------------------------------
out=$(CERT_EXPIRY_HOSTS='bad;host' run_check); rc=$?
out2=$(CERT_EXPIRY_TIMEOUT=0 CERT_EXPIRY_HOSTS=ok.example.test run_check); rc2=$?
out3=$(CERT_EXPIRY_CNF_DIR="$T/none" run_check); rc3=$?
if [[ $rc -eq 1 && $rc2 -eq 1 && $rc3 -eq 1 ]] && grep -q "is not a DNS name" <<<"$out" \
   && grep -q "FATAL CERT_EXPIRY_TIMEOUT" <<<"$out2" && grep -q "FATAL no cnf at" <<<"$out3"; then
  pass "9. bad host, bad timeout, missing cnf: rc 1, FATAL"
else
  fail "9. usage errors (rc=$rc/$rc2/$rc3 out=$out $out2 $out3)"
fi

# 10 ------------------------------------------------------------------------
: >"$SENT"
out=$(cd "$UTL_ROOT" && CERT_EXPIRY_HOSTS="ok.example.test warn.example.test" DRY_RUN=0 CERT_EXPIRY_THROTTLE_S=0 \
  ./run -a do_net_cert_expiry_check 2>&1); rc=$?
if [[ $rc -eq 0 && $(sent_n) -eq 1 ]] && grep -q "cert-expiry ok.example.test OK" <<<"$out" && grep -q "hosts=2 not_ok=1" <<<"$out"; then
  pass "10. ./run -a do_net_cert_expiry_check through the csi-spl-utl harness"
else
  fail "10. ./run harness (rc=$rc sent=$(sent_n) out=$out)"
fi

# 11 ------------------------------------------------------------------------
: >"$SENT"
out=$(unset CERT_EXPIRY_SEND_CMD; DRY_RUN=0 CERT_EXPIRY_THROTTLE_S=0 CERT_EXPIRY_HOSTS="crit.example.test warn.example.test" run_check)
if [[ $(wc -l <"$SENTINEL_LOG") -eq 1 && $(sent_n) -eq 0 ]] && grep -q -- "--to orchestrator --kind note" "$SENTINEL_LOG"; then
  pass "11. RED CONTROL: the default sender is seen by the sentinel (1 call), so the guard below would see any real call"
else
  fail "11. RED CONTROL (sentinel=$(cat "$SENTINEL_LOG") out=$out)"
fi

# 12 ------------------------------------------------------------------------
spooled=$(find "$T/spool" -type f | wc -l)
if [[ ! -s "$LIVE_LOG" && "$spooled" -eq 0 ]]; then
  pass "12. LIVE GUARD: 0 calls reached a real spool-send.sh or the spool binary; temp SPOOL_ROOT empty"
else
  fail "12. LIVE GUARD: a test call reached the real spool path (spooled=$spooled): $(cat "$LIVE_LOG")"
fi

echo "=========================================="
echo "tls-cert-expiry: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
