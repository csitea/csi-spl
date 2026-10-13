#!/usr/bin/env bash
# do_spl_wui_live_proof (spec 033 T015, SPL-12): the skip-vs-run logic of the
# live proof step in workflow 30, hermetic. A fake cnf tree and a fake proof
# (LIVE_PROOF_CMD) stand in for the deployed WUI: no network, no browser.
#
# The controls are the point:
#   - no secret -> ::notice:: naming SPL_PROBE_PW_<ENV>, rc 0, the proof never runs
#   - no cnf member -> ::notice:: naming the cnf keys, rc 0, the proof never runs
#   - secret + member -> the proof runs once with the cnf email/tenant/base,
#     the password reaches it ONLY as a 0600 PW_FILE, never in its env or argv
#     and never in the step's output; the file is gone afterwards
#   - a failing proof -> rc 1 and ::error::
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; fails=0
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

FUNC="$PROJ_ROOT/src/bash/run/spl-wui-live-proof.func.sh"
PW='s3cr3t-not-real-$(x) "q"'
mkdir -p "$T/app/csi-spl-orc" "$T/app/csi-spl-cnf/csi-spl" "$T/tmp"
cnf() { # <email> <tenant>
  printf '{"env":{"dns":{"fqdn":"dev.example.com"},"wui":{"live_proof_email":"%s","live_proof_tenant":"%s"}}}\n' \
    "$1" "$2" >"$T/app/csi-spl-cnf/csi-spl/dev.env.json"
}
# the fake proof: records what it was given, exits FAKE_RC
cat >"$T/fake-proof.sh" <<'SH'
#!/usr/bin/env bash
{
  echo "argv=$*"
  echo "base=$BASE email=$EMAIL tenant=$TENANT surfaces=$SURFACES out=$OUT"
  echo "mode=$(stat -c %a "$PW_FILE")"
  echo "pw=$(cat "$PW_FILE")"
  env | grep '^SPL_PROBE_PW' >/dev/null && echo "env-has-secret" || echo "env-clean"
  echo "pwfile=$PW_FILE"
} >"$FAKE_LOG"
exit "${FAKE_RC:-0}"
SH
chmod +x "$T/fake-proof.sh"

act() { # <env assignments...>
  rm -f "$T/fake.log"
  env -u SPL_PROBE_PW -u SPL_PROBE_PW_DEV -u LIVE_PROOF_BASE -u LIVE_PROOF_SURFACES -u LIVE_PROOF_OUT \
    TMPDIR="$T/tmp" PROJ_PATH="$T/app/csi-spl-orc" FUNC="$FUNC" ENV=dev \
    LIVE_PROOF_CMD="$T/fake-proof.sh" FAKE_LOG="$T/fake.log" LIVE_PROOF_OUT="$T/out" "$@" bash -c '
    set -euo pipefail
    do_log() { echo "$*"; }
    source "$FUNC"
    do_spl_wui_live_proof' >"$T/stdout" 2>&1 </dev/null
}

# 1. no secret -> skip
cnf probe@example.com t1
act; rc=$?
[[ $rc -eq 0 ]] && grep -q '^::notice::dev live proof skipped: the GitHub secret SPL_PROBE_PW_DEV is not set' "$T/stdout" \
  && pass "no secret: ::notice:: names SPL_PROBE_PW_DEV, rc 0" || fail "no secret: rc=$rc $(cat "$T/stdout")"
[[ ! -e "$T/fake.log" ]] && pass "no secret: the proof never runs" || fail "no secret: the proof ran"
act ENV=prd SPL_PROBE_PW=
grep -q 'FATAL no readable cnf' "$T/stdout" && pass "prd with no prd cnf: refused, not skipped silently" || fail "prd: $(cat "$T/stdout")"

# 2. secret present, cnf member missing -> skip
cnf "" t1
act SPL_PROBE_PW="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^::notice::dev live proof skipped: cnf env.wui.live_proof_email / live_proof_tenant is not set' "$T/stdout" \
  && [[ ! -e "$T/fake.log" ]] && pass "no cnf email: ::notice:: names the cnf keys, rc 0, no run" || fail "no cnf email: rc=$rc $(cat "$T/stdout")"

# 3. secret + member -> the proof runs, password only through a 0600 file
cnf probe@example.com t1
act SPL_PROBE_PW="$PW" SPL_PROBE_PW_DEV="$PW"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'every step PASS' "$T/stdout" && pass "secret + member: the proof runs, rc 0" || fail "run: rc=$rc $(cat "$T/stdout")"
grep -qx 'base=https://dev.example.com email=probe@example.com tenant=t1 surfaces=channel,lobby,home,t out='"$T/out" "$T/fake.log" \
  && pass "the proof gets the cnf base, email, tenant and the CI surfaces" || fail "proof args: $(cat "$T/fake.log")"
grep -qx 'mode=600' "$T/fake.log" && pass "PW_FILE is 0600" || fail "PW_FILE mode: $(grep mode "$T/fake.log")"
[[ "$(sed -n 's/^pw=//p' "$T/fake.log")" == "$PW" ]] && pass "PW_FILE holds the password byte for byte" || fail "PW_FILE content differs"
grep -qx 'env-clean' "$T/fake.log" && pass "the proof's env carries no SPL_PROBE_PW*" || fail "the secret leaked into the proof's env"
grep -q 'argv=.*s3cr3t' "$T/fake.log" && fail "the password is on the command line" || pass "the password is not on the command line"
grep -q 's3cr3t' "$T/stdout" && fail "the password is in the step output" || pass "the password is not in the step output"
pwf="$(sed -n 's/^pwfile=//p' "$T/fake.log")"
[[ -n "$pwf" && ! -e "$pwf" ]] && pass "PW_FILE is removed after the run" || fail "PW_FILE left behind: $pwf"

# 4. a failing proof fails the step
act SPL_PROBE_PW="$PW" FAKE_RC=1; rc=$?
[[ $rc -ne 0 ]] && grep -q '^::error::dev live proof failed (rc 1)' "$T/stdout" && pass "a failing proof: ::error::, rc != 0" || fail "failing proof: rc=$rc $(cat "$T/stdout")"
pwf="$(sed -n 's/^pwfile=//p' "$T/fake.log")"
[[ -n "$pwf" && ! -e "$pwf" ]] && pass "a failing proof still removes PW_FILE" || fail "PW_FILE left after a failure: $pwf"
[[ -z "$(ls -A "$T/tmp")" ]] && pass "no temp file left in TMPDIR" || fail "TMPDIR not empty: $(ls -A "$T/tmp")"

# 5. the workflow wires it: per-env secret, after the deploy probe
WF="$PROJ_ROOT/../.github/workflows/30_wui-build-deploy.yml"
grep -q "format('SPL_PROBE_PW_{0}'" "$WF" && grep -q 'do_spl_wui_live_proof' "$WF" \
  && pass "workflow 30 maps SPL_PROBE_PW_<ENV> and runs do_spl_wui_live_proof" || fail "workflow 30 is not wired"
grep -E 'echo .*SPL_PROBE_PW|\$\{\{ *secrets.*SPL_PROBE_PW.*\}\}.*(run|node|\./)' "$WF" | grep -v '^\s*#' >/dev/null \
  && fail "workflow 30 echoes or passes the secret on a command line" || pass "workflow 30 passes the secret only through env"

echo
[[ $fails -eq 0 ]] && echo "ALL PASS" || echo "$fails FAILED"
exit $(( fails > 0 ))
