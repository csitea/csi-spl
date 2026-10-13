#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_local_hub_install (spl-local-hub-install.func.sh), hermetic:
#   a stub sudo records every root command and runs none; temp cnf, sub[ug]id
#   files and run dir; nothing touches the box.
#   1. a missing prerequisite (rootlesskit) is FATAL and names its package;
#      nothing reaches sudo
#   2. DRY_RUN=1 (the default) for a new user: prints useradd --system with
#      nologin, the 0700 home (never recursive), a subuid/subgid range past
#      every range in use, linger and the rootless setup; sudo is never called
#   3. DRY_RUN=0, an existing user in the docker group: refused before any
#      root command
#   4. DRY_RUN=0, an existing clean user with ranges and a rootless socket:
#      no useradd and no usermod, the home made 0700, linger, the daemon
#      verified rootless under the home; exit 0
#   5. DRY_RUN=0, a daemon that answers rootful: FATAL
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ME=$(id -un); MYUID=$(id -u); MYGID=$(id -g); MYGRP=$(id -gn)

mkdir -p "$T/bin" "$T/run/$MYUID" "$T/etc"
cat >"$T/lde.env.yaml" <<EOF
env:
  lde:
    local_hub: {user: hub-x, home: /var/lib/hub-x, compose_project: p, pg_port: 1, gcs_port: 2, hub_port: 3, wui_port: 4}
EOF
printf 'a:100000:65536\nb:165536:65536\n' >"$T/etc/subuid"
printf 'a:100000:65536\nb:300000:65536\n' >"$T/etc/subgid"

# stub sudo: log the command, answer the daemon probe from $T/d.info
cat >"$T/bin/sudo" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/sudo.log"
[[ "\$*" == *" info --format "* ]] && cat "$T/d.info"
[[ "\$*" == *" info" ]] && exit 0
exit 0
EOF
cat >"$T/bin/id" <<EOF
#!/usr/bin/env bash
[[ "\$1" == -nG ]] && { cat "$T/id.groups"; exit 0; }
exec /usr/bin/id "\$@"
EOF
cat >"$T/bin/getent" <<EOF
#!/usr/bin/env bash
case "\$1" in group) echo "$MYGRP:x:$MYGID:" ;; passwd) echo "$ME:x:$MYUID:$MYGID::/h:/usr/sbin/nologin" ;; esac
EOF
for b in dockerd-rootless-setuptool.sh rootlesskit newuidmap newgidmap ss loginctl slirp4netns nft; do
  printf '#!/bin/sh\nexit 0\n' >"$T/bin/$b"
done
printf '#!/bin/sh\n[ "$*" = "compose version --short" ] && echo 2.40.0\nexit 0\n' >"$T/bin/docker"
chmod +x "$T/bin/"*

run_install() {  # extra env as args
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" LOCAL_HUB_CNF="$T/lde.env.yaml" \
    LOCAL_HUB_SUBUID_FILE="$T/etc/subuid" LOCAL_HUB_SUBGID_FILE="$T/etc/subgid" LOCAL_HUB_RUN_DIR="$T/run" \
    "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-local-hub-harden.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-local-hub-install.func.sh"
    do_spl_local_hub_install'
}

# --- 1. missing prerequisite ----------------------------------------------------
: >"$T/sudo.log"; mkdir -p "$T/min"
for b in bash env yq awk grep cat sed cut dirname basename mktemp tr; do ln -sf "$(command -v "$b")" "$T/min/$b"; done
for b in "$T/bin/"*; do [[ "${b##*/}" == rootlesskit ]] || ln -sf "$b" "$T/min/${b##*/}"; done
out=$(run_install PATH="$T/min" DRY_RUN=0 2>&1); rc=$?
if [[ $rc -ne 0 && "$out" == *FATAL*"rootlesskit (docker-ce-rootless-extras)"* && ! -s "$T/sudo.log" ]]; then
  pass "a missing prerequisite is FATAL, names its package, and nothing reaches sudo"
else fail "missing prereq: rc=$rc sudo=$(cat "$T/sudo.log") $out"; fi

# --- 2. dry run for a new user ----------------------------------------------------
: >"$T/sudo.log"; echo "" >"$T/id.groups"
NEWU="slh-tst-nouser-$$"
out=$(run_install LOCAL_HUB_USER="$NEWU" 2>&1); rc=$?
chk() { if grep -qF -- "$2" <<<"$out"; then pass "dry run: $1"; else fail "dry run: $1 -- no '$2' in: $out"; fi; }
[[ $rc -eq 0 ]] && pass "dry run exits 0" || fail "dry run rc=$rc: $out"
chk "a system user, own group, no login shell" "DRY-RUN: sudo useradd --system --user-group --home-dir /var/lib/hub-x --no-create-home --shell /usr/sbin/nologin"
chk "the home 0700, owned by the user" "DRY-RUN: sudo install -d -m 0700 -o $NEWU -g $NEWU /var/lib/hub-x"
chk "a subid range past every range in use" "DRY-RUN: sudo usermod --add-subuids 365536-431071 --add-subgids 365536-431071 $NEWU"
chk "linger" "DRY-RUN: sudo loginctl enable-linger $NEWU"
chk "the rootless dockerd, as the user" "DRY-RUN: sudo -u $NEWU -H env HOME=/var/lib/hub-x"
chk "the rootless setup tool" "dockerd-rootless-setuptool.sh install"
grep -qE 'chown -R|chmod -R' <<<"$out" && fail "dry run: a recursive chown/chmod" || pass "dry run: nothing recursive on the home"
[[ ! -s "$T/sudo.log" ]] && pass "dry run: sudo is never called" || fail "dry run called sudo: $(cat "$T/sudo.log")"

# --- 3. existing user in the docker group ------------------------------------------
: >"$T/sudo.log"; echo "$MYGRP docker" >"$T/id.groups"
out=$(run_install LOCAL_HUB_USER="$ME" LOCAL_HUB_HOME="$T/home" DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *"privileged group"*docker* && ! -s "$T/sudo.log" ]] \
  && pass "an existing user in the docker group is refused before any root command" || fail "docker-group user: rc=$rc $(cat "$T/sudo.log") $out"

# --- 4. apply on a clean existing user -----------------------------------------------
: >"$T/sudo.log"; echo "$MYGRP" >"$T/id.groups"
printf '%s:500000:65536\n' "$ME" >>"$T/etc/subuid"; printf '%s:500000:65536\n' "$ME" >>"$T/etc/subgid"
python3 -c "import socket,sys; [socket.socket(socket.AF_UNIX).bind(p) for p in sys.argv[1:]]" "$T/run/$MYUID/bus" "$T/run/$MYUID/docker.sock"
echo "[\"name=seccomp\",\"name=rootless\"] $T/home/.local/share/docker" >"$T/d.info"
out=$(run_install LOCAL_HUB_USER="$ME" LOCAL_HUB_HOME="$T/home" DRY_RUN=0 2>&1); rc=$?
log=$(cat "$T/sudo.log")
[[ $rc -eq 0 ]] && pass "apply: exit 0 on a clean user" || fail "apply rc=$rc: $out"
[[ "$log" != *useradd* && "$log" != *usermod* ]] && pass "apply: an existing user and its ranges are kept" || fail "apply re-made the user/ranges: $log"
grep -qx -- "-n install -d -m 0700 -o $ME -g $ME $T/home" <<<"$log" && pass "apply: the home made 0700 via sudo -n" || fail "apply home: $log"
grep -qx -- "-n loginctl enable-linger $ME" <<<"$log" && pass "apply: linger" || fail "apply linger: $log"
[[ "$out" == *"rootless dockerd already up"* && "$out" == *"OK local hub install: rootless dockerd for $ME"* ]] \
  && pass "apply: a running rootless daemon is kept and verified" || fail "apply daemon: $out"

# --- 5. a rootful answer ---------------------------------------------------------------
echo "[\"name=seccomp\"] /var/lib/docker" >"$T/d.info"
out=$(run_install LOCAL_HUB_USER="$ME" LOCAL_HUB_HOME="$T/home" DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *FATAL*"not a rootless daemon"* ]] && pass "apply: a rootful daemon is FATAL" || fail "rootful: rc=$rc $out"

echo "--- spl-local-hub-install: $fails failure(s)"
[[ $fails -eq 0 ]]
