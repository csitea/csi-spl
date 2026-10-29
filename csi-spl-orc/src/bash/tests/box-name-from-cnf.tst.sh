#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a box is addressed by its configured name, never its OS hostname
# (SPL-4201). The drill panel read `hostname` on the PC box as `box` (2026-10-29), so
# a sender built as <check>@$(hostname -s) named a box that does not exist.
# spl_box_name (csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh) reads the
# config; every site that names this box in an address, a note or a record
# calls it. Every case runs with a stub hostname that answers `box` and a box
# config that names `pcbox`, so a site that still reads the hostname fails.
#   1. spl_box_name: box.env SPOOL_DESK_BOX wins (CONTROL: no config at all ->
#      the stub hostname, so the stub is what a hostname read sees)
#   2. a box.env with SPOOL_BOX_TAG only (export form) -> that tag
#   3. the environment wins over box.env: SPOOL_DESK_BOX, then SPOOL_BOX_TAG
#   4. SPOOL_TEST=1 and no SPOOL_BOX_ENV -> the live box.env is not read
#   5. the call sites name pcbox: the utl box-beat note, the docker prune box,
#      the workdirs.tsv box column, the watchdog peer box, the iac secret
#      table box
#   6. ratchet: no new $(hostname ...) in the shell of orc, utl, iac and api
#      outside the allow-list below (CONTROL: a planted file is reported)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
LIB="$PROJ_ROOT/lib/bash/funcs/spl-desk-box.func.sh"
UTL="$APP_ROOT/csi-spl-utl"
IAC="$APP_ROOT/csi-spl-iac"
unset SPOOL_DESK_BOX SPOOL_BOX_TAG LEASE_MACHINE ROTATE_BOX DEV_BOX SECRET_UNUSED_BOX

mkdir -p "$T/bin" "$T/live" "$T/root"
printf '#!/usr/bin/env bash\necho box\n' >"$T/bin/hostname"; chmod +x "$T/bin/hostname"
export PATH="$T/bin:$PATH"
printf 'SPOOL_BOX_TAG=pcbox\nSPOOL_DESK_BOX=pcbox\n' >"$T/box.env"
printf 'export SPOOL_BOX_TAG="sat"\n' >"$T/tag.env"
printf 'SPOOL_DESK_BOX=live\n' >"$T/live/box.env"
bn() { bash -c '. "$1"; spl_box_name' _ "$LIB"; }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1: want '$2', got '$3'"; }

# 1
eq "1. box.env names the box: pcbox, not the hostname" pcbox "$(SPOOL_BOX_ENV="$T/box.env" bn)"
eq "1. CONTROL: no config -> the stub hostname" box "$(SPOOL_BOX_ENV="$T/none.env" bn)"
# 2
eq "2. box.env with SPOOL_BOX_TAG only -> the tag" sat "$(SPOOL_BOX_ENV="$T/tag.env" bn)"
# 3
eq "3. env SPOOL_DESK_BOX wins over box.env" envbox "$(SPOOL_DESK_BOX=envbox SPOOL_BOX_ENV="$T/box.env" bn)"
eq "3. env SPOOL_BOX_TAG wins over box.env" envtag "$(SPOOL_BOX_TAG=envtag SPOOL_BOX_ENV="$T/box.env" bn)"
# 4
eq "4. SPOOL_TEST=1 skips the live box.env" box "$(SPOOL_TEST=1 SPOOL_BOX_ENV="" SPOOL_LIVE_ROOT="$T/live" bn)"
eq "4. CONTROL: outside a test the live box.env is read" live "$(SPOOL_TEST=0 SPOOL_BOX_ENV="" SPOOL_LIVE_ROOT="$T/live" bn)"

# 5. the call sites, each with hostname=box and box.env=pcbox
export SPOOL_BOX_ENV="$T/box.env"
out="$(bash -c 'do_log(){ :; }; . "$1"; box_beat_body NEAR 60 90 0 0 45 120' _ "$UTL/src/bash/run/box-beat-telemetry.func.sh" 2>&1)"
[[ "$out" == *"RECONNECT on pcbox "* ]] && pass "5. box-beat note names pcbox" || fail "5. box-beat note: $out"
eq "5. docker prune names pcbox" pcbox "$(bash -c 'do_log(){ :; }; . "$1"; _dtcp_box' _ "$UTL/src/bash/run/docker-test-container-prune.func.sh" 2>&1)"
eq "5. watchdog peer box is pcbox" pcbox "$(bash -c 'do_log(){ :; }; . "$1"; spl_wd_peer_box' _ "$PROJ_ROOT/src/bash/run/spl-wd-peers.func.sh" 2>&1)"
eq "5. iac secret table box is pcbox" pcbox "$(bash -c 'do_log(){ :; }; . "$1"; spl_secret_unused_box' _ "$IAC/src/bash/run/spl-secret-unused-list.func.sh" 2>&1)"
WORKDIR_TABLE="$T/root/workdirs.tsv" SPOOL_ROOT="$T/root" \
  bash "$PROJ_ROOT/src/bash/features/spawn-agents/scripts/workdir-register.sh" add --kind scratch --agent c-901 "$T/root/wd" >/dev/null 2>&1
eq "5. workdirs.tsv box column is pcbox" pcbox "$(awk -F'\t' '!/^#/ { print $4 }' "$T/root/workdirs.tsv" 2>/dev/null)"

# 6. ratchet. A $(hostname ...) left in the shell is allowed only here, each
# for its reason; a new one names the box from the hostname again.
allowed='csi-spl-orc/lib/bash/funcs/spl-desk-box.func.sh
csi-spl-orc/lib/bash/funcs/define-all-run-vars.func.sh
csi-spl-orc/src/bash/run/run.sh
csi-spl-utl/src/bash/run/run.sh
csi-spl-iac/src/bash/run/run.sh
csi-spl-iac/src/bash/run/satellite-verify.func.sh
csi-spl-orc/src/bash/run/gh-runner-add.func.sh
csi-spl-orc/src/bash/run/check-gh-runner.func.sh
csi-spl-orc/src/bash/run/report-box-sar.func.sh
csi-spl-orc/src/bash/run/spl-self-host-up.func.sh
csi-spl-orc/src/bash/features/spool-install/install.sh
csi-spl-api/src/bash/build.sh
csi-spl-orc/src/bash/scripts/check-disk-headroom.sh
csi-spl-orc/src/bash/run/spl-review-line-check.func.sh
csi-spl-orc/src/bash/run/spl-lane-issue.func.sh
csi-spl-orc/src/bash/run/spl-box-state-backup.func.sh'
# spl-desk-box: the last resort of spl_box_name itself; run.sh and
# define-all-run-vars: HOST_NAME, the harness's own log field; satellite-
# verify: checks the OS hostname against the box name on purpose;
# gh-runner-add / check-gh-runner: GitHub runner names, and the check's text;
# report-box-sar: a report header; spl-self-host-up: hostname -I, addresses;
# install.sh: the first install, before any box config exists; build.sh:
# BOX_TAG first, in an error text; the last four read the config first and
# fall back to the hostname only on a box with none.
scan() {  # <root> -> each file under <root>'s shell trees with $(hostname
  local r="$1"
  (cd "$r" && grep -rlE '\$\(hostname|`hostname' --include='*.sh' \
    csi-spl-orc/src csi-spl-orc/lib csi-spl-utl/src csi-spl-utl/lib csi-spl-iac/src csi-spl-iac/lib csi-spl-api/src/bash 2>/dev/null |
    grep -v '/tests/' | sort)
}
new="$(comm -23 <(scan "$APP_ROOT") <(sort <<<"$allowed"))"
eq "6. no shell outside the allow-list reads the hostname" "" "$new"
mkdir -p "$T/plant/csi-spl-utl/src/bash/run"
printf 'x() { box="$(hostname -s)"; }\n' >"$T/plant/csi-spl-utl/src/bash/run/planted.func.sh"
eq "6. CONTROL: a planted hostname read is reported" csi-spl-utl/src/bash/run/planted.func.sh \
  "$(comm -23 <(scan "$T/plant") <(sort <<<"$allowed"))"

((fails == 0)) && echo "ALL PASS" || echo "FAILED: $fails"
exit $((fails > 0))
