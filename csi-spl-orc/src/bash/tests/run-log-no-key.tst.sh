#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a private key an action prints once on stdout never lands in the
# ./run log files (SPL-3614). run.sh tees stdout and stderr into
# ~/var/log/<proj>/<unit>.<ts>.{out,err}.log (mode 664); do_spl_tenant_create
# prints the tenant root private key once on stdout ("not stored"), so before
# the fix a DRY_RUN=0 create left the key in the out log.
#   1. orc, iac and utl run.sh (byte-identical): a probe action prints a fake
#      key as a JSON field, a KEY= line and a PEM block, on stdout and stderr.
#      stdout still carries it; neither log holds it; the logs say <redacted>.
#      Two more shapes, each with its own fake key: a camelCase privateKey
#      field, and a value holding an escaped quote (the key sits after it).
#   2. the real orc tree: ENV=lde DRY_RUN=0 ./run -a do_spl_tenant_create with
#      a stub spool CLI (no hub, no DB): stdout JSON holds the root private
#      key, no run log does.
# The keys are random bytes made here, never a real key.
# Control: the same probe with the masking filter replaced by cat must leak
# (the check is not blind).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)

fake_key() { printf 'FAKETESTKEY%s' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')"; }

# probe_tree <module> [name] -- a throwaway <ns>-orc tree running <module>'s run.sh
probe_tree() {
  local d="$T/${2:-$1}/csi-x/csi-x-orc"
  mkdir -p "$d/src/bash/run" "$d/lib/bash"
  cp "$APP_ROOT/$1/src/bash/run/run.sh" "$d/src/bash/run/run.sh"
  cp -r "$PROJ_ROOT/lib/bash/funcs" "$d/lib/bash/funcs"
  ln -s src/bash/run/run.sh "$d/run"
  cat >"$d/src/bash/run/key-probe.func.sh" <<'PROBE'
do_key_probe() {
  printf '{"tenant":"acme","root_private_key":"%s","billing_status":"manual"}\n' "$PROBE_KEY"
  printf 'ROOT_PRIVATE_KEY=%s\n' "$PROBE_KEY"
  local pk="PRIVATE KEY"
  printf -- '-----BEGIN %s-----\n%s\n-----END %s-----\n' "$pk" "$PROBE_KEY" "$pk"
  printf '{"ssh_private_key": "%s"}\n' "$PROBE_KEY" >&2
  printf '{"tenant":"acme","privateKey":"%s"}\n' "$PROBE_KEY_CAMEL"
  printf '{"root_private_key":"ab\\"%s\\\\cd"}\n' "$PROBE_KEY_ESC"
  echo "PROBE ran"
}
PROBE
  echo "$d"
}

# logs_hold <home> <key> -- exit 0 when any run log under <home> holds <key>
logs_hold() { grep -rqsF -- "$2" "$1/var/log"; }

for m in csi-spl-orc csi-spl-iac csi-spl-utl; do
  d="$(probe_tree "$m")"
  key="$(fake_key)" kcamel="$(fake_key)" kesc="$(fake_key)"
  h="$T/home-$m"
  mkdir -p "$h"
  (cd "$d" && HOME="$h" VAR_DIR="$T/var-$m" PROBE_KEY="$key" PROBE_KEY_CAMEL="$kcamel" \
    PROBE_KEY_ESC="$kesc" ./run -a do_key_probe </dev/null >"$T/out" 2>"$T/err")
  rc=$?
  [[ $rc == 0 ]] && grep -qF "\"root_private_key\":\"$key\"" "$T/out" && grep -q 'PROBE ran' "$T/out" &&
    pass "$m: stdout still carries the key once (the action's contract)" ||
    fail "$m: stdout lost the key or the run failed: rc=$rc"
  n_logs="$(find "$h/var/log" -name '*.log' 2>/dev/null | wc -l)"
  [[ $n_logs -ge 2 ]] && pass "$m: the run wrote its out and err logs ($n_logs)" || fail "$m: no run logs ($n_logs)"
  logs_hold "$h" "$key" && fail "$m: a run log holds the private key ($(grep -rlF -- "$key" "$h/var/log" | wc -l) file(s))" ||
    pass "$m: no run log holds the private key"
  grep -qF "\"privateKey\":\"$kcamel\"" "$T/out" && ! logs_hold "$h" "$kcamel" &&
    pass "$m: a camelCase privateKey value is masked in the log, kept on stdout" ||
    fail "$m: camelCase privateKey: a run log holds it or stdout lost it"
  grep -qF "$kesc" "$T/out" && ! logs_hold "$h" "$kesc" &&
    pass "$m: a value with an escaped quote is masked whole in the log, kept on stdout" ||
    fail "$m: escaped-quote value: a run log holds the part after the quote or stdout lost it"
  grep -rqs '<redacted' "$h/var/log" && grep -rqs 'PROBE ran' "$h/var/log" &&
    pass "$m: the logs keep the other lines and mark <redacted>" ||
    fail "$m: the logs lost lines or carry no <redacted> mark"
done

# --- control: the same orc probe, the mask replaced by cat, leaks ------------
d="$(probe_tree csi-spl-orc control)"
sed -i 's/^do_mask_private_keys() {$/do_mask_private_keys() { cat; return; }\n_unused_mask() {/' "$d/src/bash/run/run.sh"
key="$(fake_key)"; h="$T/home-control"; mkdir -p "$h"
(cd "$d" && HOME="$h" VAR_DIR="$T/var-control" PROBE_KEY="$key" ./run -a do_key_probe </dev/null >/dev/null 2>&1)
logs_hold "$h" "$key" && pass "CONTROL an unmasked tee leaks the key into the log" ||
  fail "CONTROL an unmasked tee did not leak: the check is blind"

# --- 2. the real do_spl_tenant_create through the real orc ./run ------------
stub="$T/stub-spool"
cat >"$stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  root-keygen) [[ "$2" == --out ]] && printf '%s\n' "$STUB_KEY" >"$3" && echo "FAKEPUB$RANDOM" ;;
  hub-tenant) exit 0 ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$stub"
key="$(fake_key)"; h="$T/home-tc"; mkdir -p "$h"
(cd "$PROJ_ROOT" && HOME="$h" VAR_DIR="$T/var-tc" LDE_STATE_DIR="$T/state" ENV=lde DRY_RUN=0 TENANT_ID=acme \
  SPOOL_HUB_DB_DSN='postgres://stub@127.0.0.1:1/stub' SPOOL_BIN="$stub" STUB_KEY="$key" \
  ./run -a do_spl_tenant_create --json </dev/null >"$T/tc.out" 2>"$T/tc.err")
rc=$?
[[ $rc == 0 ]] && grep -qF "\"root_private_key\":\"$key\"" "$T/tc.out" &&
  pass "tenant create: stdout JSON holds the root private key once" ||
  fail "tenant create: rc=$rc, stdout JSON has no key ($(grep -h FATAL "$T/tc.out" "$T/tc.err" | sed -n 1p))"
[[ "$(find "$h/var/log" -name "*.log" 2>/dev/null | wc -l)" -gt 0 ]] && pass "tenant create: the run wrote its logs" ||
  fail "tenant create: no run logs under the test HOME"
logs_hold "$h" "$key" && fail "tenant create: a run log holds the root private key ($(grep -rlF -- "$key" "$h/var/log" | wc -l) file(s))" ||
  pass "tenant create: no run log holds the root private key"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
