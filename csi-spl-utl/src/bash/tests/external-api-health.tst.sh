#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-04: outbound model & external API reachability probe
# (SPL-2232). do_net_external_api_check runs against stub getent / TCP / TLS
# commands and a temp dir; no packet leaves the box.
#   1. Three reachable endpoints -> rc 0, 3 TSV rows of 10 fields, down=0
#   2. DNS failure -> dns_ok=0, tcp/tls `-`, WARN DOWN, still rc 0
#   3. Blackhole route (TCP hangs) -> tcp_ok=0 within 10 s at the 5 s timeout
#   4. TLS handshake refused (cert intercept) -> tls_ok=0, WARN DOWN
#   5. Endpoints and timeout_s read from a cnf yaml
#   6. The repo cnf lists anthropic, gemini and github endpoints
#   7. No endpoints -> rc 1 FATAL;  8. a malformed endpoint -> rc 1 FATAL
#   9. Probes run in parallel: 3 endpoints x 2 s TCP finish in < 4 s
#  10. Samples older than 7 days are trimmed
#  11. Report-only: an unwritable dir still exits 0 with a WARN
#  12. ./run -a do_net_external_api_check through the csi-spl-utl harness
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/external-api-health.func.sh"
REPO_CNF="$UTL_ROOT/../csi-spl-cnf/csi-spl/all.env.yaml"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"; DIR="$T/probe"
mkdir -p "$BIN"

# getent hosts <host>: fails for a host named nodns*
cat >"$BIN/getent" <<'EOF'
#!/bin/bash
[[ "$2" == nodns* ]] && exit 2
echo "192.0.2.1 $2"
EOF
# tcp <host> <port>: hangs for blackhole*, sleeps 2 s for slow*
cat >"$BIN/tcp" <<'EOF'
#!/bin/bash
[[ "$1" == blackhole* ]] && exec sleep 30
[[ "$1" == slow* ]] && exec sleep 2
exit 0
EOF
# tls <host> <port>: refused for badtls*
cat >"$BIN/tls" <<'EOF'
#!/bin/bash
[[ "$1" == badtls* ]] && exit 1
exit 0
EOF
chmod +x "$BIN/getent" "$BIN/tcp" "$BIN/tls"

export EXTERNAL_API_GETENT_CMD="$BIN/getent" EXTERNAL_API_TCP_CMD="$BIN/tcp" EXTERNAL_API_TLS_CMD="$BIN/tls"
export EXTERNAL_API_DIR="$DIR" EXTERNAL_API_BOX="PC" EXTERNAL_API_CNF="$T/none.yaml"
unset EXTERNAL_API_ENDPOINTS EXTERNAL_API_TIMEOUT EXTERNAL_API_NOW
TSV="$DIR/PC.external-api.tsv"

# shellcheck source=/dev/null
run_check() { ( source "$FUNC_SH"; do_net_external_api_check ) 2>&1; }

# 1 -------------------------------------------------------------------------
rm -rf "$DIR"
out=$(EXTERNAL_API_ENDPOINTS="anthropic=a.example.com:443 gemini=g.example.com:443 github=h.example.com:443" run_check); rc=$?
rows=$(wc -l <"$TSV" 2>/dev/null || echo 0)
nf=$(awk -F'\t' '{print NF}' "$TSV" 2>/dev/null | sort -u)
if [[ $rc -eq 0 && $rows -eq 3 && "$nf" == 10 ]] && grep -q "down=0" <<<"$out" \
   && awk -F'\t' '$5!=1||$7!=1||$9!=1{bad=1} END{exit bad}' "$TSV" \
   && grep -qP '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\tanthropic\ta\.example\.com\t443\t1\t\d+\t1\t\d+\t1\t\d+$' "$TSV"; then
  pass "1. three reachable endpoints: rc 0, 3 rows of 10 fields, down=0"
else
  fail "1. reachable endpoints (rc=$rc rows=$rows nf=$nf out=$out)"
fi

# 2 -------------------------------------------------------------------------
rm -rf "$DIR"
out=$(EXTERNAL_API_ENDPOINTS="gemini=nodns.example.com:443" run_check); rc=$?
if [[ $rc -eq 0 ]] && grep -q "WARN external-api .* gemini nodns.example.com:443 DOWN dns_ok=0 tcp_ok=- tls_ok=-" <<<"$out" \
   && awk -F'\t' '$5=="0"&&$7=="-"&&$9=="-"{ok=1} END{exit !ok}' "$TSV" && grep -q "down=1" <<<"$out"; then
  pass "2. DNS failure: dns_ok=0, tcp/tls skipped as -, WARN DOWN, rc 0"
else
  fail "2. DNS failure (rc=$rc out=$out)"
fi

# 3 -------------------------------------------------------------------------
rm -rf "$DIR"
s=$EPOCHREALTIME
out=$(EXTERNAL_API_TIMEOUT=5 EXTERNAL_API_ENDPOINTS="anthropic=blackhole.example.com:443 github=h.example.com:443" run_check); rc=$?
e=$EPOCHREALTIME
ms=$(( (${e/[.,]/} - ${s/[.,]/}) / 1000 ))
if [[ $rc -eq 0 && $ms -lt 10000 ]] && grep -q "anthropic blackhole.example.com:443 DOWN dns_ok=1 tcp_ok=0 tls_ok=-" <<<"$out" \
   && grep -q "github h.example.com:443 ok" <<<"$out" \
   && awk -F'\t' '$2=="anthropic"&&$7=="0"&&$8>=4900{ok=1} END{exit !ok}' "$TSV"; then
  pass "3. blackhole route detected in ${ms} ms (< 10000), tcp_ok=0 at the 5 s timeout, the other endpoint ok"
else
  fail "3. blackhole route (rc=$rc ms=$ms out=$out)"
fi

# 4 -------------------------------------------------------------------------
rm -rf "$DIR"
out=$(EXTERNAL_API_ENDPOINTS="anthropic=badtls.example.com:443" run_check); rc=$?
if [[ $rc -eq 0 ]] && grep -q "DOWN dns_ok=1 tcp_ok=1 tls_ok=0" <<<"$out"; then
  pass "4. TLS handshake refused: tls_ok=0, WARN DOWN"
else
  fail "4. TLS refused (rc=$rc out=$out)"
fi

# 5 -------------------------------------------------------------------------
rm -rf "$DIR"
cat >"$T/cnf.yaml" <<'EOF'
env:
  box:
    external_api_check:
      timeout_s: 3
      endpoints:
        - name: one
          host: one.example.com
          port: 443
        - name: two
          host: two.example.com
          port: 8443
EOF
out=$(EXTERNAL_API_CNF="$T/cnf.yaml" run_check); rc=$?
if [[ $rc -eq 0 ]] && grep -q "one one.example.com:443 ok" <<<"$out" && grep -q "two two.example.com:8443 ok" <<<"$out" \
   && grep -q "endpoints=2 down=0" <<<"$out"; then
  pass "5. endpoints read from the cnf yaml"
else
  fail "5. cnf endpoints (rc=$rc out=$out)"
fi
out=$(EXTERNAL_API_CNF="$T/cnf.yaml" EXTERNAL_API_ENDPOINTS="x=blackhole.example.com:443" run_check)
if grep -q "tcp_ok=0 .*tcp=3[0-9][0-9][0-9]ms" <<<"$out"; then
  pass "5b. cnf timeout_s=3 applies (blackhole cut at ~3 s)"
else
  fail "5b. cnf timeout_s (out=$out)"
fi

# 6 -------------------------------------------------------------------------
names=$(yq -r '.env.box.external_api_check.endpoints[].name' "$REPO_CNF" 2>/dev/null | sort | tr '\n' ' ')
tmo=$(yq -r '.env.box.external_api_check.timeout_s' "$REPO_CNF" 2>/dev/null)
if [[ "$names" == "anthropic gemini github " && "$tmo" == 5 ]]; then
  pass "6. repo cnf lists anthropic, gemini, github at timeout_s 5"
else
  fail "6. repo cnf (names='$names' timeout_s='$tmo')"
fi

# 7 -------------------------------------------------------------------------
out=$(run_check); rc=$?
if [[ $rc -eq 1 ]] && grep -q "FATAL no endpoints" <<<"$out"; then
  pass "7. no endpoints: rc 1, FATAL"
else
  fail "7. no endpoints (rc=$rc out=$out)"
fi

# 8 -------------------------------------------------------------------------
out=$(EXTERNAL_API_ENDPOINTS="bad=host;rm -rf:443" run_check); rc=$?
if [[ $rc -eq 1 ]] && grep -q "is not name=host:port" <<<"$out"; then
  pass "8. malformed endpoint: rc 1, FATAL"
else
  fail "8. malformed endpoint (rc=$rc out=$out)"
fi

# 9 -------------------------------------------------------------------------
rm -rf "$DIR"
s=$EPOCHREALTIME
out=$(EXTERNAL_API_ENDPOINTS="a=slow1.example.com:443 b=slow2.example.com:443 c=slow3.example.com:443" run_check); rc=$?
e=$EPOCHREALTIME
ms=$(( (${e/[.,]/} - ${s/[.,]/}) / 1000 ))
if [[ $rc -eq 0 && $ms -lt 4000 ]] && grep -q "endpoints=3 down=0" <<<"$out"; then
  pass "9. 3 endpoints x 2 s TCP ran in parallel: ${ms} ms (< 4000)"
else
  fail "9. parallel probes (rc=$rc ms=$ms out=$out)"
fi

# 10 ------------------------------------------------------------------------
rm -rf "$DIR"; mkdir -p "$DIR"
now=2000000000
printf '2033-05-01T00:00:00Z\told\th\t443\t1\t1\t1\t1\t1\t1\n' >"$TSV"
out=$(EXTERNAL_API_NOW=$now EXTERNAL_API_ENDPOINTS="new=h.example.com:443" run_check); rc=$?
if [[ $rc -eq 0 ]] && ! grep -q $'\told\t' "$TSV" && grep -q $'\tnew\t' "$TSV" && grep -q '^2033-05-18T03:33:20Z' "$TSV"; then
  pass "10. samples older than 7 days trimmed"
else
  fail "10. trim (rc=$rc file=$(cat "$TSV"))"
fi

# 11 ------------------------------------------------------------------------
touch "$T/afile"
out=$(EXTERNAL_API_DIR="$T/afile/sub" EXTERNAL_API_ENDPOINTS="a=h.example.com:443" run_check); rc=$?
if [[ $rc -eq 0 ]] && grep -q "WARN cannot create" <<<"$out" && grep -q "a h.example.com:443 ok" <<<"$out"; then
  pass "11. unwritable dir: report still printed, WARN, rc 0"
else
  fail "11. unwritable dir (rc=$rc out=$out)"
fi

# 12 ------------------------------------------------------------------------
rm -rf "$DIR"
out=$(cd "$UTL_ROOT" && EXTERNAL_API_ENDPOINTS="github=h.example.com:443" ./run -a do_net_external_api_check 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q "github h.example.com:443 ok" <<<"$out" && [[ -s "$TSV" ]]; then
  pass "12. ./run -a do_net_external_api_check through the csi-spl-utl harness"
else
  fail "12. ./run harness (rc=$rc out=$out)"
fi

echo "=========================================="
echo "external-api-health: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
