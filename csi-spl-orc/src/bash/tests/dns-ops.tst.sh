#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: DNS ops actions (007 T014) exist, are syntactically valid, read
#          names from cnf, dry-run without touching cloud or the host
#          resolver, and a stubbed real export writes JSON per project/zone.
#   1. bash -n on wait-for-cert / export-all-dns-settings / flush-dns
#   2. no baked product domain, no key-file, no gcloud config set
#   3. do_export_all_dns_settings DRY_RUN (default) makes no gcloud call
#   4. DRY_RUN=0 with stubbed gcloud writes zones + records JSON, --account
#      on every call, never config set
#   5. do_flush_dns DRY_RUN (default) makes no sudo call
#   6. ENV=dev export dry-run names the cnf project in its log
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

RUN="$PROJ_ROOT/src/bash/run"
for f in wait-for-cert export-all-dns-settings flush-dns; do
  p="$RUN/${f}.func.sh"
  [[ -f "$p" ]] || { fail "missing $p"; continue; }
  bash -n "$p" && pass "bash -n $f.func.sh" || fail "bash -n $f.func.sh"
done

CNF_ALL="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
dom=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$CNF_ALL")
[[ -n "$dom" && "$dom" != null && "$dom" == *.* ]] || { echo "FAIL: missing env.dns.BASE_DOMAIN in $CNF_ALL"; exit 1; }
for banned in 'gcloud config set' 'activate-service-account' 'key-file' "$dom"; do
  if grep -nF "$banned" "$RUN/wait-for-cert.func.sh" "$RUN/export-all-dns-settings.func.sh" "$RUN/flush-dns.func.sh"; then
    fail "banned token in DNS ops funcs: $banned"
  else
    pass "no banned token in DNS ops funcs (product domain from cnf)"
  fi
done

mkdir -p "$T/stub"
STUB_LOG="$T/calls.log"
: >"$STUB_LOG"
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case " $* " in
  *" auth print-access-token "*) printf 'dummy-token-0123456789abcdef\n'; exit 0 ;;
  *" dns managed-zones list "*"--format=json"*) printf '[{"name":"zone-a"}]\n'; exit 0 ;;
  *" dns managed-zones list "*) printf 'zone-a\n'; exit 0 ;;
  *" dns record-sets list "*) printf '[{"name":"example.test.","type":"A"}]\n'; exit 0 ;;
  *" certificate-manager certificates describe "*) printf 'ACTIVE\n'; exit 0 ;;
esac
echo "gcloud unexpected: $*" >&2
exit 1
STUB
printf '#!/bin/sh\necho "sudo $*" >>"$STUB_LOG"\nexit 0\n' >"$T/stub/sudo"
chmod +x "$T/stub/"*

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/${ENV:-dev}" \
    STUB_LOG="$STUB_LOG" PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

: >"$STUB_LOG"
out=$(SNIPPET='do_export_all_dns_settings' in_orc ENV=dev 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then fail "export dry run exited $rc: $(tail -3 <<<"$out" | tr '\n' ' ')"
elif [[ -s "$STUB_LOG" ]]; then fail "export dry run made calls: $(tr '\n' ';' <"$STUB_LOG")"
elif grep -q 'csi-spl-dev' <<<"$out"; then pass "export dry run: exit 0, names cnf project, no gcloud"
else fail "export dry run did not name csi-spl-dev: $(tail -5 <<<"$out" | tr '\n' ' ')"; fi

: >"$STUB_LOG"
out=$(SNIPPET='do_flush_dns' in_orc TEST_DOMAIN=example.test 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then fail "flush dry run exited $rc: $(tail -3 <<<"$out" | tr '\n' ' ')"
elif grep -q '^sudo ' "$STUB_LOG"; then fail "flush dry run invoked sudo: $(tr '\n' ';' <"$STUB_LOG")"
else pass "flush dry run: exit 0, no sudo"; fi

: >"$STUB_LOG"
out=$(SNIPPET='do_flush_dns' in_orc 2>&1); rc=$?
[[ $rc -ne 0 ]] && pass "flush without TEST_DOMAIN/ENV is refused (rc $rc)" || fail "flush without TEST_DOMAIN exited 0"

: >"$STUB_LOG"
export_dir="$T/dns-out"
out=$(SNIPPET='do_export_all_dns_settings' in_orc ENV=dev DRY_RUN=0 GCP_ACCOUNT=op@example.com DNS_EXPORT_DIR="$export_dir" 2>&1); rc=$?
if [[ $rc -ne 0 ]]; then
  fail "export real-run (stub) exited $rc: $(tail -5 <<<"$out" | tr '\n' ' ')"
else
  [[ -f "$export_dir/csi-spl-dev_dns_zones.json" ]] && pass "export wrote csi-spl-dev_dns_zones.json" \
    || fail "missing zones json: $(ls -A "$export_dir" 2>/dev/null | tr '\n' ' ')"
  [[ -f "$export_dir/csi-spl-dev_zone-a_dns_records.json" ]] && pass "export wrote per-zone records json" \
    || fail "missing records json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$export_dir/csi-spl-dev_dns_zones.json" \
    && pass "zones json is parseable" || fail "zones json is not parseable"
fi
if grep -q 'config set' "$STUB_LOG" || grep -q 'activate-service-account' "$STUB_LOG"; then
  fail "export wrote shared gcloud config: $(tr '\n' ';' <"$STUB_LOG")"
else
  pass "export does not config set / activate-service-account"
fi
n_acct=$(grep -c -- '--account=op@example.com' "$STUB_LOG" || true)
n_gcloud=$(grep -c '^gcloud ' "$STUB_LOG" || true)
# print-access-token + zones list + record-sets list = 3, all with --account
if [[ "$n_acct" -ge 2 && "$n_acct" -eq "$n_gcloud" ]]; then
  pass "every gcloud call carries --account ($n_gcloud calls)"
else
  fail "--account on $n_acct of $n_gcloud gcloud calls: $(tr '\n' ';' <"$STUB_LOG")"
fi

# ENV=dev wait-for-cert against the stub (cnf fills DOMAIN/PROJECT/CERT_NAME)
: >"$STUB_LOG"
out=$(SNIPPET='do_wait_for_cert' in_orc ENV=dev GCP_ACCOUNT=op@example.com TIMEOUT_SECONDS=5 POLL_SECONDS=1 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q 'certificate-manager certificates describe' "$STUB_LOG"; then
  pass "ENV=dev wait-for-cert describes the Certificate Manager cert"
else
  fail "ENV=dev wait-for-cert rc=$rc: $(tail -3 <<<"$out" | tr '\n' ' ') log=$(tr '\n' ';' <"$STUB_LOG")"
fi
if grep -q 'domain-mappings' "$STUB_LOG"; then
  fail "wait-for-cert still polls Cloud Run domain-mappings"
else
  pass "wait-for-cert does not poll domain-mappings"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
