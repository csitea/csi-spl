#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4790, the CI disk-full prevention of wf 10, offline.
#   scripts/ci-disk-guard.sh (df is a stub that reports FAKE_AVAIL_KB free):
#     1. enough free: exit 0, an "ok - disk free" line per path
#     2. too little free: exit 1, the one line "disk full before tests:
#        <free> < <need> (<path>)" and its ::error:: annotation
#     3. an unreadable df: exit 1, never a silent pass
#     4. no CI_DISK_NEED_GB: exit 2 (usage), not a pass
#   scripts/ci-cache-save-cap.sh (a real dir measured with du):
#     5. under the cap: save=true, written to GITHUB_OUTPUT too
#     6. a planted oversize cache: save=false and the ::warning:: line
#     7. a missing dir: save=false
#   static, wf 10:
#     8. the guard runs in hub-suite, hub-pg, wui-e2e and orc-suite, and in
#        hub-pg before the cache restore
#     9. hub-pg's save step runs only on the cap's save=true, and the cap step
#        comes before it
#    10. CI_GO_CACHE_SAVE_MAX_MB sits above the normal trimmed save (2.1 G
#        uncompressed on run 41813241775, so > 2200 MB), or every run skips it
#   CONTROLS: the stub df reports what it is given; a save step without the
#             cap condition is caught by the check of 9.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
G="$PROJ_ROOT/src/bash/scripts/ci-disk-guard.sh"
C="$PROJ_ROOT/src/bash/scripts/ci-cache-save-cap.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"

cat >"$T/df" <<'STUB'
#!/usr/bin/env bash
[[ -n "${FAKE_DF_FAIL:-}" ]] && exit 1
if [[ "$1" == -Pk ]]; then
  echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
  echo "/dev/root 152043520 60000000 ${FAKE_AVAIL_KB} 40% $2"
else
  echo "Filesystem Size Used Avail Use% Mounted on (stub -h $*)"
fi
STUB
chmod +x "$T/df"
guard() { env CI_DISK_DF="$T/df" "$@" bash "$G" / /runner/tmp >"$T/out" 2>&1; }

# 1
guard CI_DISK_NEED_GB=10 FAKE_AVAIL_KB=$((88 * 1048576)); rc=$?
[[ $rc -eq 0 && $(grep -c '^ok - disk free 88.0G >= 10G' "$T/out") -eq 2 ]] \
  && pass "1. 88G free, need 10G: exit 0, one ok line per path" || fail "1. rc=$rc $(cat "$T/out")"

# 2
guard CI_DISK_NEED_GB=10 FAKE_AVAIL_KB=$((3 * 1048576)); rc=$?
[[ $rc -eq 1 ]] && grep -qx 'disk full before tests: 3.0G < 10G (/)' "$T/out" \
  && grep -qx '::error::disk full before tests: 3.0G < 10G (/runner/tmp)' "$T/out" \
  && pass "2. 3G free, need 10G: exit 1 and the one clear 'disk full before tests' line" || fail "2. rc=$rc $(cat "$T/out")"

# 3
guard CI_DISK_NEED_GB=10 FAKE_DF_FAIL=1; rc=$?
[[ $rc -eq 1 ]] && grep -q '::error::disk guard: cannot read the free space of /' "$T/out" \
  && pass "3. df fails: exit 1, not a silent pass" || fail "3. rc=$rc $(cat "$T/out")"

# 4
env -u CI_DISK_NEED_GB CI_DISK_DF="$T/df" FAKE_AVAIL_KB=1 bash "$G" / >"$T/out" 2>&1; rc=$?
[[ $rc -eq 2 ]] && pass "4. no CI_DISK_NEED_GB: usage, exit 2" || fail "4. rc=$rc $(cat "$T/out")"

# 5-7: a real directory, measured by du
mkdir -p "$T/cache"
head -c $((3 * 1048576)) /dev/zero >"$T/cache/small"
: >"$T/gho"
env CI_CACHE_SAVE_MAX_MB=10 GITHUB_OUTPUT="$T/gho" bash "$C" "$T/cache" >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'save=true' "$T/gho" && grep -qx 'mb=3' "$T/gho" \
  && pass "5. 3 MB under a 10 MB cap: save=true, mb=3 in GITHUB_OUTPUT" || fail "5. rc=$rc $(cat "$T/out" "$T/gho")"

head -c $((12 * 1048576)) /dev/zero >"$T/cache/planted-oversize"
: >"$T/gho"
env CI_CACHE_SAVE_MAX_MB=10 GITHUB_OUTPUT="$T/gho" bash "$C" "$T/cache" >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'save=false' "$T/gho" && ! grep -q 'save=true' "$T/gho" \
  && grep -q '::warning::cache save skipped: .* is 1[56] MB > cap 10 MB' "$T/out" \
  && pass "6. a planted 15 MB cache over a 10 MB cap: save=false, the warning line" || fail "6. rc=$rc $(cat "$T/out" "$T/gho")"

: >"$T/gho"
env CI_CACHE_SAVE_MAX_MB=10 GITHUB_OUTPUT="$T/gho" bash "$C" "$T/no-such-dir" >"$T/out" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'save=false' "$T/gho" && pass "7. a missing dir: save=false" || fail "7. rc=$rc $(cat "$T/out" "$T/gho")"

# 8: the guard's step, per job (a job runs from its `  <job>:` line to the next)
job_body() { awk -v j="  $2:" '$0 == j {on = 1; next} on && /^  [a-z0-9-]+:$/ {exit} on' "$1"; }
GUARD_RUN='csi-spl-orc/src/bash/scripts/ci-disk-guard.sh'
missing=""
for j in hub-suite hub-pg wui-e2e orc-suite; do
  # into a variable first: grep -q ends early and, under pipefail, the
  # writer's SIGPIPE would read as "missing"
  body=$(job_body "$WF" "$j" | grep -vE '^\s*#')
  grep -qF "$GUARD_RUN" <<<"$body" || missing+=" $j"
done
pg=$(job_body "$WF" hub-pg | grep -vE '^\s*#')
g_at=$(grep -nF "$GUARD_RUN" <<<"$pg" | sed -n '1s/:.*//p')
r_at=$(grep -nF 'actions/cache/restore@' <<<"$pg" | sed -n '1s/:.*//p')
[[ -z "$missing" && -n "$g_at" && -n "$r_at" && $g_at -lt $r_at ]] \
  && pass "8. the disk guard runs in hub-suite, hub-pg, wui-e2e, orc-suite; in hub-pg before the cache restore" \
  || fail "8. guard missing in:${missing:- none}; hub-pg guard line ${g_at:-none}, restore line ${r_at:-none}"

# 9: the save step's `if:` holds the cap's output, and the cap step comes first
save_gated() {  # <job body> -> 0 when the cache save step is gated on the cap
  awk '/^      - name:/ {if (blk ~ /actions\/cache\/save@/) print blk; blk = ""} {blk = blk "\n" $0}
       END {if (blk ~ /actions\/cache\/save@/) print blk}' <<<"$1" | grep -F "steps.gocache-cap.outputs.save == 'true'" >/dev/null
}
c_at=$(grep -nF 'csi-spl-orc/src/bash/scripts/ci-cache-save-cap.sh' <<<"$pg" | sed -n '1s/:.*//p')
s_at=$(grep -nF 'actions/cache/save@' <<<"$pg" | sed -n '1s/:.*//p')
save_gated "$pg" && [[ -n "$c_at" && -n "$s_at" && $c_at -lt $s_at ]] \
  && pass "9. hub-pg saves the Go cache only on the cap's save=true, cap step first" \
  || fail "9. hub-pg save not gated on the cap (cap line ${c_at:-none}, save line ${s_at:-none})"
ctl=$(printf '      - name: Save\n        if: ${{ !cancelled() }}\n        uses: actions/cache/save@x\n')
save_gated "$ctl" && fail "CONTROL: an ungated save step passed check 9" || pass "CONTROL: an ungated save step is caught by check 9"

# 10
cap=$(sed -nE 's/^  CI_GO_CACHE_SAVE_MAX_MB: *"?([0-9]+)"?.*/\1/p' "$WF")
need=$(sed -nE 's/^  CI_DISK_NEED_GB: *"?([0-9]+)"?.*/\1/p' "$WF")
[[ "$cap" =~ ^[0-9]+$ && $cap -gt 2200 && "$need" =~ ^[0-9]+$ ]] \
  && pass "10. wf 10 env: CI_GO_CACHE_SAVE_MAX_MB=$cap (> 2200, the normal save), CI_DISK_NEED_GB=$need" \
  || fail "10. wf 10 env: CI_GO_CACHE_SAVE_MAX_MB='$cap' CI_DISK_NEED_GB='$need'"

# CONTROL
env FAKE_AVAIL_KB=4242 "$T/df" -Pk / | grep ' 4242 ' >/dev/null && pass "CONTROL: the df stub reports what it is given" \
  || fail "CONTROL: the df stub ignores FAKE_AVAIL_KB"

echo "=== $([[ $fails -eq 0 ]] && echo 'all ci-disk-guard.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
