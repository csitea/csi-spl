#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 159 row T3 (with spec 127 X1's start checks): a workspace W
#          hosted on a fleet box runs its desk as W's own OS user, and the
#          desk refuses to start on a box that fails a start check of spec 127
#          5.3 (spec 159 5.2's one exception: the fleet's agent user may be
#          root-equivalent). All of it runs on fixtures under $T: no user is
#          made, no box file is read or written, no hub is called.
#   1. (n=1) CONTROL: the desk starts as W on a fleet box (fixture), state
#      inside W's home; the fleet agent user in sudo does not stop it
#   2. (n=3) W's user in sudo or docker, or another workspace user in lxd ->
#      refused, no state written, no external call
#   3. (n=2) /proc without hidepid -> refused; a hidepid gid= exemption naming
#      W's group -> refused. CONTROL hidepid=2 passes (in 1)
#   4. (n=4) ptrace_scope 1, suid_dumpable 2, a piped core_pattern, a sudo
#      grant -> refused. CONTROL systemd-coredump pipe passes
#   5. (n=2) plain swap -> refused; a non-tmpfs runtime dir -> refused.
#      CONTROL zram and dm-crypt swap pass
#   6. (n=1) a spec 108 workspace box (no fleet-hosted marker) runs no start
#      check: the same failing fixtures do not refuse it
#   7. (n=7) do_spl_fleet_ws_host: the dry run plans useradd in its own group
#      only (no -G, usermod, gpasswd or sudoers) plus lingering and the
#      marker; DRY_RUN=0 with no OWNER_GO or a malformed one (n=3) is
#      refused rc 1 with the owner-go FATAL, before any root call and
#      without the dry-run path; a spec 108 box is refused (exit 3); the
#      fleet agent user is refused; a
#      join token of another workspace is refused and no token is printed
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
# sudo: `sudo -n -l` answers FAKE_SUDO_L (no grant by default); any other
# call is logged and refused, so a root write shows up in calls.log
cat >"$T/stub/sudo" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "-n -l" ]; then printf '%s\n' "${FAKE_SUDO_L:-Sorry, user $(id -un) may not run sudo on fixture.}"; exit 1; fi
echo "sudo $*" >>"$STUB_LOG"; exit 1
EOF
chmod +x "$T/stub/sudo"

ME=$(id -un) MYGID=$(id -g)
P=spl-t-
FB="$T/fleet" B="$T/fleet/wsa"
mkdir -p "$B/wsa"
printf 'wsa\n' >"$B/claim"; printf 'spec 159 T3\n' >"$B/fleet-hosted"

# the fixture box: every check passes
X="$T/fix"
mkdir -p "$X/sys/kernel/yama" "$X/sys/fs" "$X/sysfs/block/dm-0/dm" "$X/sysfs/block/dm-1/dm"
printf '%s:x:%s:%s::/:/bin/bash\nfleetusr:x:1500:1500::/:/bin/bash\n%swsb:x:1601:1601::/:/bin/bash\n' "$ME" "$(id -u)" "$MYGID" "$P" >"$X/passwd"
GROUP_OK="sudo:x:27:fleetusr
docker:x:999:fleetusr
lxd:x:998:
users:x:100:$ME"
printf '%s\n' "$GROUP_OK" >"$X/group"
printf 'proc /proc proc rw,nosuid,nodev,noexec,relatime,hidepid=invisible 0 0\n' >"$X/mounts"
echo 2 >"$X/sys/kernel/yama/ptrace_scope"; echo 0 >"$X/sys/fs/suid_dumpable"
echo core >"$X/sys/kernel/core_pattern"
printf 'Filename\tType\tSize\tUsed\tPriority\n' >"$X/swaps"
echo CRYPT-LUKS2-0000-swap >"$X/sysfs/block/dm-0/dm/uuid"; echo LVM-0000 >"$X/sysfs/block/dm-1/dm/uuid"
RT=""
if [[ "$(stat -f -c %T "$T")" == tmpfs ]]; then RT="$T/rt"; mkdir -m 0700 "$RT"
elif [[ "$(stat -f -c %T /dev/shm 2>/dev/null)" == tmpfs ]]; then RT=$(mktemp -d -p /dev/shm); chmod 0700 "$RT"; trap 'rm -rf "$T" "$RT"' EXIT
fi

# desk <fixture overrides as VAR=value>...: desk-up dry run as W on the fixture
desk() {
  : >"$T/calls.log"
  SNIPPET=do_spl_desk_up in_orc SPL_WS_BASE="$B" SPL_STATE_DIR= SPL_WS_USER_PREFIX="$P" TENANT_ID=wsa DESK_AGENT=c-101 \
    SPL_DSC_GROUP="$X/group" SPL_DSC_PASSWD="$X/passwd" SPL_DSC_MOUNTS="$X/mounts" SPL_DSC_SYSCTL="$X/sys" \
    SPL_DSC_SWAPS="$X/swaps" SPL_DSC_SYS="$X/sysfs" SPL_DSC_RUNTIME="${RT:-$T/no-tmpfs}" "$@" >"$T/o" 2>&1
}
refused() { # refused <check> <label> <overrides>...
  local c="$1" l="$2"; shift 2
  desk "$@"; local rc=$?
  [[ $rc -ne 0 ]] && grep -q "REFUSED $c:" "$T/o" && ! grep -q 'OK desk start checks pass' "$T/o" &&
    pass "$l -> the desk refuses ($c)" || fail "$l rc=$rc: $(cat "$T/o")"
}
with_file() { printf '%s\n' "$2" >"$T/$1"; printf '%s' "$T/$1"; }
sys_with() { rm -rf "$T/sys2"; cp -r "$X/sys" "$T/sys2"; printf '%s\n' "$2" >"$T/sys2/$1"; printf '%s' "$T/sys2"; }

if [[ -z "$RT" ]]; then
  skip "no tmpfs for the runtime dir fixture (\$T and /dev/shm are not tmpfs)"
  echo "=== $( ((fails)) && echo "$fails FAILED" || echo "all passed") ==="; exit $((fails > 0))
fi

# --- 1. CONTROL: the desk starts as W on the fleet box -----------------------------
desk; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK desk start checks pass' "$T/o" && grep -q "state $B/wsa/state/dev" "$T/o" &&
  pass "CONTROL the desk starts as W on a fleet box, state inside $B/wsa, the fleet agent user in sudo + docker exempt" ||
  fail "control desk rc=$rc: $(cat "$T/o")"

# --- 2. root-equivalent groups ---------------------------------------------------------
rm -rf "$B/wsa/state"
refused groups "W's user in sudo" SPL_DSC_GROUP="$(with_file g1 "$GROUP_OK
sudo2:x:1:
wheel:x:10:
sudo:x:27:fleetusr,$ME")"
[[ ! -e "$B/wsa/state" && ! -s "$T/calls.log" ]] && pass "the refusal wrote no state and made no external call" ||
  fail "refusal side effects: $(ls "$B/wsa"; cat "$T/calls.log")"
refused groups "W's user in docker" SPL_DSC_GROUP="$(with_file g2 "${GROUP_OK/docker:x:999:fleetusr/docker:x:999:fleetusr,$ME}")"
refused groups "another workspace's user in lxd" SPL_DSC_GROUP="$(with_file g3 "${GROUP_OK/lxd:x:998:/lxd:x:998:${P}wsb}")"

# --- 3. /proc hidepid ------------------------------------------------------------------
refused hidepid "/proc without hidepid" SPL_DSC_MOUNTS="$(with_file m1 'proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0')"
refused hidepid "/proc hidepid=2 with gid= of W's group" SPL_DSC_MOUNTS="$(with_file m2 "proc /proc proc rw,hidepid=2,gid=$MYGID 0 0")"

# --- 4. ptrace, dumpable, core_pattern, sudoers ------------------------------------
refused ptrace "ptrace_scope 1" SPL_DSC_SYSCTL="$(sys_with kernel/yama/ptrace_scope 1)"
refused dumpable "suid_dumpable 2" SPL_DSC_SYSCTL="$(sys_with fs/suid_dumpable 2)"
refused dumpable "a piped core_pattern" SPL_DSC_SYSCTL="$(sys_with kernel/core_pattern '|/usr/bin/collector %p')"
desk SPL_DSC_SYSCTL="$(sys_with kernel/core_pattern '|/lib/systemd/systemd-coredump %P %u')"; rc=$?
[[ $rc -eq 0 ]] && pass "CONTROL a systemd-coredump core_pattern passes" || fail "systemd-coredump rc=$rc: $(cat "$T/o")"
refused sudoers "a sudo grant (password)" FAKE_SUDO_L="sudo: a password is required"
refused sudoers "a sudo grant (commands)" FAKE_SUDO_L="User $ME may run the following commands on fixture:"

# --- 5. swap and the runtime dir ---------------------------------------------------
refused swap "plain swap" SPL_DSC_SWAPS="$(with_file s1 "Filename Type Size Used Priority
/swap.img file 1024 0 -2")"
refused swap "a dm swap that is not dm-crypt" SPL_DSC_SWAPS="$(with_file s2 "Filename Type Size Used Priority
/dev/dm-1 partition 1024 0 -2")"
desk SPL_DSC_SWAPS="$(with_file s3 "Filename Type Size Used Priority
/dev/zram0 partition 1024 0 100
/dev/dm-0 partition 1024 0 -2")"; rc=$?
[[ $rc -eq 0 ]] && pass "CONTROL zram and dm-crypt swap pass" || fail "zram/crypt swap rc=$rc: $(cat "$T/o")"
refused runtime "a non-tmpfs runtime dir" SPL_DSC_RUNTIME="$PROJ_ROOT"

# --- 6. a spec 108 workspace box runs no start check --------------------------------
B108="$T/ws108"; mkdir -p "$B108/wsa"; printf 'wsa\n' >"$B108/claim"
desk SPL_WS_BASE="$B108" SPL_DSC_MOUNTS="$T/m1"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'REFUSED' "$T/o" &&
  pass "a spec 108 box (no fleet-hosted marker) runs no start check, as before" || fail "108 box rc=$rc: $(cat "$T/o")"

# --- 7. the named action -----------------------------------------------------------
host() {
  : >"$T/calls.log"
  SNIPPET=do_spl_fleet_ws_host in_orc SPL_FLEET_WS_BASE="$FB" SPL_WS_USER_PREFIX="$P" TENANT_ID=wsa DESK_BOX=wsa-fleet1 \
    DESK_AGENT=c-101 SPOOL_AGENT_USER=fleetusr "$@" >"$T/o" 2>&1
}
printf 'spj1.wsa.sk-test-0000secret\n' >"$T/tok-ok"; printf 'spj1.wsb.sk-test-0000secret\n' >"$T/tok-other"
host SPOOL_JOIN_TOKEN_FILE="$T/tok-ok"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "useradd --system --user-group --home-dir '$B/wsa' .* '${P}wsa'" "$T/o" &&
   grep -q "loginctl enable-linger '${P}wsa'" "$T/o" && grep -q "$B/fleet-hosted" "$T/o" &&
   ! grep -qE -- ' -G |usermod|gpasswd|sudoers' "$T/o" && ! grep -q 'sk-test-0000' "$T/o" && [[ ! -s "$T/calls.log" ]]; then
  pass "the dry run plans W's user in its own group only, lingering and the marker; no token printed, no call"
else
  fail "dry run rc=$rc: $(cat "$T/o"; cat "$T/calls.log")"
fi
# the owner gate: rc 1 and its own FATAL (an unbound-variable crash is rc 127,
# not the gate), no root call, nothing under the fleet base touched
no_go() { # no_go <label> <overrides>...
  local l="$1"; shift; local before; before=$(find "$FB" -printf '%p %m %s\n' | sort)
  host DRY_RUN=0 "$@"; local rc=$?
  [[ $rc -eq 1 ]] && grep -q 'FATAL DRY_RUN=0 writes root files on this box: set OWNER_GO=' "$T/o" &&
    ! grep -q "DRY_RUN would\|OK DRY_RUN" "$T/o" && [[ ! -s "$T/calls.log" && "$(find "$FB" -printf '%p %m %s\n' | sort)" == "$before" ]] &&
    pass "DRY_RUN=0 $l is refused (rc 1, the owner-go FATAL), no root call, nothing touched" ||
    fail "$l rc=$rc: $(cat "$T/o"; cat "$T/calls.log")"
}
no_go "without OWNER_GO"
no_go "with OWNER_GO not a msg id" OWNER_GO=not-a-msg-id
no_go "with OWNER_GO of 7 hex" OWNER_GO=2e9d03b
host SPL_WS_BASE="$B108"; rc=$?
[[ $rc -eq 3 ]] && pass "a spec 108 workspace box is not a fleet box (exit 3)" || fail "108 box rc=$rc: $(cat "$T/o")"
host SPL_WS_USER=fleetusr; rc=$?
[[ $rc -ne 0 ]] && grep -q "fleet's agent user" "$T/o" && pass "the fleet agent user is never W's user" || fail "fleet user rc=$rc: $(cat "$T/o")"
host SPOOL_JOIN_TOKEN_FILE="$T/tok-other"; rc=$?
[[ $rc -ne 0 ]] && grep -q "join token of workspace 'wsa'" "$T/o" && ! grep -q 'sk-test-0000' "$T/o" &&
  pass "a join token of another workspace is refused, the token not printed" || fail "other token rc=$rc: $(cat "$T/o")"

echo "=== $( ((fails)) && echo "$fails FAILED" || echo "all passed") ==="
exit $((fails > 0))
