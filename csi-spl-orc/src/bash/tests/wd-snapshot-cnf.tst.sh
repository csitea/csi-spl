#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a watchdog code snapshot (spl_wd_upd_snapshot, spec 102 WD3) carries
#          what the code run from it reads beside the orc tree. Drill 5
#          (2026-10-09, sat): the snapshot held only csi-spl-orc, so every
#          Mistral boot restore refused "no cost cap ... got ''" (the cnf
#          max_price read next to spawn-mistral.sh found nothing) and
#          lane-map died "FATAL missing .../csi-spl-iac/lib/bash/funcs/
#          spl-merged-cnf.func.sh". A scratch desk-cron repo holds this
#          tree's orc code, iac lib and cnf, plus wui/api/doc stand-ins.
#   1. the snapshot has csi-spl-cnf/csi-spl and csi-spl-iac/lib/bash
#   2. _sp_cnf_max_price, read out of the snapshot's spawn-mistral.sh the way
#      restore-mistral.sh does, returns the cnf's max_price (5.00 today)
#   3. do_spl_cloud_cnf (lane-map's cnf source) run from the snapshot
#      resolves: rc 0, the merged dev cnf carries the same max_price
#   4. stays small: no wui, api, doc, nor iac outside lib/bash
#   5. control: a sha without cnf/iac (an orc-only repo) still snapshots,
#      and there _sp_cnf_max_price returns '' (the drill 5 refusal)
#   6. a change only in csi-spl-iac/lib/bash is a code change (restart
#      path), a cnf-only change is not
#   7. drill 6 (sat): do_spl_lane_put -> spl_lane_init -> spl_host_spool run
#      from the snapshot keeps the installed spool binary instead of running
#      the api's build.sh the snapshot does not carry; 7b. no binary -> rc 1
#      with a FATAL that says why (CONTROL: the old verdict ran build.sh)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in git tar yq; do command -v "$b" >/dev/null || { echo "FAIL: $b is required"; exit 1; }; done

do_log() { echo "$*"; }
# shellcheck source=../run/spl-wd-self-update.func.sh
source "$PROJ_ROOT/src/bash/run/spl-wd-self-update.func.sh"
PROJ_PATH="$PROJ_ROOT"

# the max_price restore-mistral.sh reads: its eval of spawn-mistral.sh's function
max_price_in() {  # <orc dir of a snapshot>
  (
    SPAWN_ADAPTER="$1/src/bash/features/spawn-agents/scripts/spawn-mistral.sh"
    eval "$(sed -n -e '/^_sp_cnf_max_price() {$/,/^}$/p' "$SPAWN_ADAPTER")"
    _sp_cnf_max_price
  )
}
want="$(max_price_in "$PROJ_ROOT")"
[[ "$want" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "FAIL: this tree's cnf has no max_price (got '$want')"; exit 1; }

# ---- the desk-cron checkout --------------------------------------------------
DC="$T/desk-cron"
mkdir -p "$DC/csi-spl-orc/src/bash/features" "$DC/csi-spl-iac/lib" "$DC/csi-spl-iac/src" "$DC/csi-spl-cnf"
cp -r "$PROJ_ROOT/run" "$PROJ_ROOT/lib" "$DC/csi-spl-orc/"
cp -r "$PROJ_ROOT/src/bash/run" "$DC/csi-spl-orc/src/bash/"
cp -r "$PROJ_ROOT/src/bash/features/spawn-agents" "$DC/csi-spl-orc/src/bash/features/"
cp -r "$APP_ROOT/csi-spl-iac/lib/bash" "$DC/csi-spl-iac/lib/"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$DC/csi-spl-cnf/"
for d in csi-spl-wui csi-spl-api csi-spl-doc csi-spl-iac/src csi-spl-cnf/src; do
  mkdir -p "$DC/$d"; echo x > "$DC/$d/stand-in.txt"
done
dc() { git -C "$DC" -c user.name=t -c user.email=t@example.com "$@"; }
git init -q "$DC"; dc add -A; dc commit -qm A
SHA_A="$(dc rev-parse HEAD)"

WD_DIR="$T/wd"; mkdir -p "$WD_DIR/code"
spl_wd_upd_snapshot "$DC" "$SHA_A"; rc=$?
SNAP="$WD_DIR/code/$SHA_A"

# 1
[[ $rc -eq 0 && -x "$SNAP/csi-spl-orc/run" && -f "$SNAP/csi-spl-cnf/csi-spl/all.env.yaml" &&
   -f "$SNAP/csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh" ]] &&
  pass "1. the snapshot carries csi-spl-cnf/csi-spl and csi-spl-iac/lib/bash" ||
  fail "1. snapshot rc=$rc: $(cd "$SNAP" 2>/dev/null && ls -d -- */ */*/ 2>/dev/null | tr '\n' ' ')"

# 2
got="$(max_price_in "$SNAP/csi-spl-orc")"
[[ "$got" == "$want" ]] &&
  pass "2. _sp_cnf_max_price from the snapshot = $got" ||
  fail "2. _sp_cnf_max_price from the snapshot = '$got', want '$want'"

# 3
out="$(
  APP_PATH="$SNAP" PROJ_PATH="$SNAP/csi-spl-orc" ENV=dev SPL_STATE_DIR="$T/state" HOME="$T"
  export APP_PATH PROJ_PATH ENV SPL_STATE_DIR HOME
  # shellcheck disable=SC1091
  source "$SNAP/csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh" || exit 1
  do_spl_cloud_cnf >/dev/null || { echo "rc=$?"; exit 1; }
  yq -r '.env.box.mistral_vibe.max_price' "$SPL_CNF"
)"; rc=$?
[[ $rc -eq 0 && "$out" == "$want" ]] &&
  pass "3. do_spl_cloud_cnf (lane-map's cnf source) resolves from the snapshot" ||
  fail "3. do_spl_cloud_cnf from the snapshot rc=$rc out=$out"

# 4
stray="$(cd "$SNAP" && find . -name stand-in.txt | sort | tr '\n' ' ')"
[[ -z "$stray" && ! -e "$SNAP/csi-spl-wui" && ! -e "$SNAP/csi-spl-api" && ! -e "$SNAP/csi-spl-doc" ]] &&
  pass "4. no wui, api, doc, nor iac outside lib/bash in the snapshot" ||
  fail "4. stray in the snapshot: $stray"

# 5 control: an orc-only sha (no cnf/iac in it) still snapshots, max_price ''
DC2="$T/orc-only"
mkdir -p "$DC2/csi-spl-orc/src/bash/features"
cp -r "$PROJ_ROOT/run" "$DC2/csi-spl-orc/"
cp -r "$PROJ_ROOT/src/bash/run" "$DC2/csi-spl-orc/src/bash/"
cp -r "$PROJ_ROOT/src/bash/features/spawn-agents" "$DC2/csi-spl-orc/src/bash/features/"
git init -q "$DC2"
git -C "$DC2" add -A; git -C "$DC2" -c user.name=t -c user.email=t@example.com commit -qm O
SHA_O="$(git -C "$DC2" rev-parse HEAD)"
spl_wd_upd_snapshot "$DC2" "$SHA_O"; rc=$?
got="$(max_price_in "$WD_DIR/code/$SHA_O/csi-spl-orc")"
[[ $rc -eq 0 && -x "$WD_DIR/code/$SHA_O/csi-spl-orc/run" && -z "$got" ]] &&
  pass "5. control: an orc-only snapshot works, and its max_price is '' (the drill 5 refusal)" ||
  fail "5. control: orc-only rc=$rc max_price='$got'"

# 6 an iac lib change is a code change; a cnf-only change is not
echo "# touched" >> "$DC/csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh"
dc add -A; dc commit -qm B; SHA_B="$(dc rev-parse HEAD)"
echo "# touched" >> "$DC/csi-spl-cnf/csi-spl/all.env.yaml"
dc add -A; dc commit -qm C; SHA_C="$(dc rev-parse HEAD)"
# shellcheck disable=SC2046
if ! spl_wd_upd_git "$DC" diff --quiet "$SHA_A" "$SHA_B" -- $(spl_wd_upd_code_paths) &&
   spl_wd_upd_git "$DC" diff --quiet "$SHA_B" "$SHA_C" -- $(spl_wd_upd_code_paths); then
  pass "6. an iac lib change is a code change (restart), a cnf-only change is not"
else
  fail "6. code paths: $(spl_wd_upd_code_paths)"
fi

# 7 lane-put from the snapshot (drill 6, sat: m-617's do_spl_lane_put died on
# "csi-spl-api/src/bash/build.sh: No such file"). spl_lane_init calls
# spl_host_spool, whose verdict for a non-git tree was "build": from a
# snapshot it must keep the installed spool binary, and with no binary say why.
host_spool_in_snap() {  # <state dir>
  APP_PATH="$SNAP" PROJ_PATH="$SNAP/csi-spl-orc" SPL_ORG_APP=csi-spl SPL_STATE_DIR="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh" || exit 9
    spl_host_spool; rc=$?
    echo "SPL_SPOOL=$SPL_SPOOL"
    exit "$rc"' 2>&1
}
mkdir -p "$T/st7/bin"
printf '#!/bin/sh\necho stub\n' >"$T/st7/bin/spool"; chmod +x "$T/st7/bin/spool"
out="$(host_spool_in_snap "$T/st7")"; rc=$?
[[ $rc -eq 0 && "$out" == *"SPL_SPOOL=$T/st7/bin/spool"* && "$out" != *build.sh* && "$(cat "$T/st7/bin/spool")" == *stub* ]] &&
  pass "7. from the snapshot spl_host_spool keeps the installed spool (no build.sh run)" ||
  fail "7. spl_host_spool from the snapshot rc=$rc: $out"
out="$(host_spool_in_snap "$T/st7b")"; rc=$?
[[ $rc -eq 1 && "$out" == *"no spool binary to keep"* && "$out" == *"no api tree"* ]] &&
  pass "7b. from the snapshot with no spool binary: rc 1, the FATAL says there is no api tree" ||
  fail "7b. no binary rc=$rc: $out"
echo "=== fails=$fails"
[[ "$fails" -eq 0 ]]
