#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the private local hub's L1 actions (do_spl_local_hub_up / _down /
# _status / _update) and their shared lib (spl-local-hub.func.sh), hermetic:
# temp dirs, stubbed docker / sudo / ss, no daemon, no real database.
#   1. cnf: LOCAL_HUB_* come from env.lde.local_hub; the caller's env wins
#   2. the private config: missing, group/world-readable, an unknown key, a
#      bad slug and the smoke tenant are refused; a good one exports the tenant
#   3. the docker host: the system daemon is refused (control: allowed only
#      for an ^e2e- tenant with LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1); a missing
#      socket is refused
#   4. a caller who is not the hub user re-executes through sudo -u <user> in
#      the long-lived tree; the private config never travels in the env
#   5. _up: a failing hardening check starts nothing; the green order is
#      harden -> build -> setup -> workspace -> WUI -> backup
#   6. the workspace is created once (stamp); another name on the same state
#      dir is refused
#   7. the loopback gate: 0.0.0.0, a public address or no listener FAIL;
#      127.0.0.1 / [::1] PASS
#   8. _down keeps the volumes; LOCAL_HUB_PURGE=1 removes them only with DRY_RUN=0
#   9. hub.env with the local hub overlay: view door session, no debug
#      tokens, no redirect URIs, APP_URL on the local WUI port; control: the
#      plain lde render keeps the open door
#  10. lde_compose appends LDE_COMPOSE_EXTRA_FILES and the project override
#  11. _update fast-forwards then runs the tree's own up; a diverged tree is
#      refused and left as it was
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v yq >/dev/null || { skip "no yq"; exit 0; }

ME=$(id -un)
H="$T/home"; mkdir -p "$H/.config/csi-spl"; chmod 700 "$H"
CNF="$H/.config/csi-spl/local-hub.env"
write_cnf() { (umask 077; printf '%s\n' "$@" >"$CNF"); }
write_cnf 'LOCAL_HUB_TENANT=e2e-abc123'

# in_orc <VAR=val...> -- source every orc function, then eval $SNIPPET
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' 2>&1
}

# --- 1. cnf --------------------------------------------------------------------
out=$(SNIPPET='spl_local_hub_cnf && echo "$LOCAL_HUB_USER|$LOCAL_HUB_HOME|$LOCAL_HUB_PROJECT|$LOCAL_HUB_HUB_PORT|$LOCAL_HUB_WUI_PORT|$LOCAL_HUB_TREE"' in_orc)
[[ "$out" == *"spl-hub|/var/lib/spl-hub|spl-local-hub|58180|3180|/var/lib/spl-hub/csi-spl" ]] \
  && pass "cnf: user, home, project, ports and tree from env.lde.local_hub" || fail "cnf: $out"
out=$(SNIPPET='spl_local_hub_cnf && echo "$LOCAL_HUB_USER|$LOCAL_HUB_HUB_PORT|$LOCAL_HUB_CONFIG"' in_orc LOCAL_HUB_USER=x LOCAL_HUB_HUB_PORT=1 LOCAL_HUB_HOME="$H")
[[ "$out" == *"x|1|$CNF" ]] && pass "cnf: the caller's env wins" || fail "cnf override: $out"

# --- 2. the private config ----------------------------------------------------------
pcnf() { SNIPPET='spl_local_hub_cnf && spl_local_hub_private_cnf && echo "TENANT=$LOCAL_HUB_TENANT"' in_orc LOCAL_HUB_HOME="$H"; }
out=$(pcnf); [[ "$out" == *"TENANT=e2e-abc123" ]] && pass "private config: the tenant is read" || fail "private config: $out"
chmod 644 "$CNF"; out=$(pcnf); [[ "$out" == *"mode 644"* && "$out" != *TENANT=* ]] && pass "private config: mode 644 refused" || fail "mode: $out"
chmod 600 "$CNF"
write_cnf 'LOCAL_HUB_TENANT=e2e-abc123' 'LOCAL_HUB_TENANT_NAME=x'
out=$(pcnf); [[ "$out" == *"unknown key 'LOCAL_HUB_TENANT_NAME'"* ]] && pass "private config: an unknown key is refused" || fail "unknown key: $out"
write_cnf 'LOCAL_HUB_TENANT=Bad_Name'
out=$(pcnf); [[ "$out" == *FATAL*LOCAL_HUB_TENANT* && "$out" != *TENANT=Bad* ]] && pass "private config: a bad slug is refused" || fail "slug: $out"
write_cnf 'LOCAL_HUB_TENANT=smoke'
out=$(pcnf); [[ "$out" == *"must not be the smoke tenant"* ]] && pass "private config: the smoke tenant is refused" || fail "smoke: $out"
out=$(SNIPPET='spl_local_hub_cnf && spl_local_hub_private_cnf' in_orc LOCAL_HUB_HOME="$T/none")
[[ "$out" == *"no private config"* ]] && pass "private config: a missing file is refused" || fail "missing: $out"
write_cnf '# a comment' '' 'LOCAL_HUB_TENANT="e2e-abc123"' 'LOCAL_HUB_OWNER_EMAIL=owner@example.com'
out=$(pcnf); [[ "$out" == *"TENANT=e2e-abc123" && "$out" != *owner@example.com* ]] \
  && pass "private config: comments and quotes; the values are never logged" || fail "quoted: $out"

# --- 3. the docker host ---------------------------------------------------------------
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$T/rootless.sock"
dh() { SNIPPET='spl_local_hub_cnf && spl_local_hub_private_cnf && spl_local_hub_docker_host && echo "DH=$DOCKER_HOST"' in_orc LOCAL_HUB_HOME="$H" "$@"; }
out=$(dh LOCAL_HUB_DOCKER_HOST=unix:///var/run/docker.sock)
[[ "$out" == *"system docker daemon"* && "$out" != *DH=* ]] && pass "docker host: the system daemon is refused" || fail "system: $out"
out=$(dh LOCAL_HUB_DOCKER_HOST="unix://$T/rootless.sock")
[[ "$out" == *"DH=unix://$T/rootless.sock" ]] && pass "docker host: a rootless socket is used" || fail "rootless: $out"
out=$(dh LOCAL_HUB_DOCKER_HOST="unix://$T/absent.sock")
[[ "$out" == *"no docker socket"* ]] && pass "docker host: a missing socket is refused" || fail "absent: $out"
out=$(dh LOCAL_HUB_DOCKER_HOST=unix:///var/run/docker.sock LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1 XDG_RUNTIME_DIR="$T")
[[ "$out" == *"system docker daemon"* || "$out" == *"DH=unix:///var/run/docker.sock" ]] || fail "control e2e: $out"
[[ -S /var/run/docker.sock ]] && { [[ "$out" == *"DH=unix:///var/run/docker.sock" ]] \
  && pass "control: the system daemon is allowed for an ^e2e- tenant with LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1" || fail "control e2e: $out"; }
write_cnf 'LOCAL_HUB_TENANT=real-ws'
out=$(dh LOCAL_HUB_DOCKER_HOST=unix:///var/run/docker.sock LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1)
[[ "$out" == *"system docker daemon"* ]] && pass "docker host: the e2e escape never applies to a real workspace" || fail "escape: $out"
write_cnf 'LOCAL_HUB_TENANT=e2e-abc123'

# --- 4. re-exec as the hub user ----------------------------------------------------------
printf '#!/bin/sh\necho "SUDO $*" >>"%s/sudo.args"\n' "$T" >"$T/sudo"; chmod +x "$T/sudo"
out=$(SNIPPET='do_spl_local_hub_up' in_orc LOCAL_HUB_USER=root LOCAL_HUB_SUDO="$T/sudo" LOCAL_HUB_TREE=/srv/tree LOCAL_HUB_TENANT=leak)
grep -q "^SUDO -n -u root -H env LOCAL_HUB_USER=root .*LOCAL_HUB_TREE=/srv/tree .*LOCAL_HUB_HUB_PORT=58180 .*LOCAL_HUB_PURGE=0 bash -c .* _ /srv/tree/csi-spl-orc do_spl_local_hub_up$" "$T/sudo.args" \
  && pass "re-exec: sudo -u <hub user> runs the action in the long-lived tree, the instance's knobs carried" || fail "re-exec args: $(cat "$T/sudo.args" 2>&1) / $out"
[[ "$out" != *"compose"* && "$out" != *"harden"* ]] && pass "re-exec: nothing runs in the caller's process" || fail "in-process: $out"
grep -q 'leak' "$T/sudo.args" && fail "re-exec: the command line carried LOCAL_HUB_TENANT" || pass "re-exec: no private value crosses on the command line (sudo resets the env)"

# --- 5. _up order ---------------------------------------------------------------------------
STUBS='spl_local_hub_env() { echo ENV; LDE_WUI_PORT=1 LDE_COMPOSE_PROJECT=p; }; do_require_bin() { :; }
  do_gen_docker_env() { echo GEN; }; do_setup_app_inf() { echo SETUP; }; _slh_tenant() { echo TENANT; }
  _slh_wui() { echo WUI; }; lde_compose() { case "$1" in build) echo BUILD ;; config) echo backup ;; up) echo "UP $*" >&2 ;; esac; }'
out=$(SNIPPET="$STUBS"'; do_spl_local_hub_harden_check() { echo HARDEN-FAIL; return 1; }; do_spl_local_hub_up' in_orc LOCAL_HUB_USER="$ME")
[[ "$out" == *HARDEN-FAIL* && "$out" != *BUILD* && "$out" != *SETUP* ]] && pass "_up: a failed hardening check starts nothing" || fail "harden: $out"
out=$(SNIPPET="$STUBS"'; do_spl_local_hub_harden_check() { echo HARDEN; }; do_spl_local_hub_up; echo "rc=$?"' in_orc LOCAL_HUB_USER="$ME")
order=$(grep -oE '^(ENV|GEN|HARDEN|BUILD|SETUP|TENANT|WUI|UP up -d backup)$' <<<"$out" | tr '\n' ' ')
[[ "$order" == "ENV GEN HARDEN BUILD SETUP TENANT WUI UP up -d backup " && "$out" == *rc=0* ]] \
  && pass "_up: env -> harden -> build -> setup -> workspace -> WUI -> backup" || fail "_up order: $order / $out"
out=$(SNIPPET="$STUBS"'; do_spl_local_hub_harden_check() { echo HARDEN-RAN; return 1; }; LOCAL_HUB_TENANT=e2e-abc123; do_spl_local_hub_up; echo "rc=$?"' in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1)
[[ "$out" != *HARDEN-RAN* && "$out" == *"NOT run"* && "$out" == *rc=0* ]] && pass "_up: the e2e escape skips the hardening check, loudly" || fail "e2e harden skip: $out"
out=$(SNIPPET="$STUBS"'; do_spl_local_hub_harden_check() { echo HARDEN-RAN; return 1; }; LOCAL_HUB_TENANT=real-ws; do_spl_local_hub_up; echo "rc=$?"' in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_ALLOW_SYSTEM_DOCKER=1)
[[ "$out" == *HARDEN-RAN* && "$out" == *rc=1* ]] && pass "control: a real workspace with the flag still runs the check" || fail "real harden: $out"
out=$(SNIPPET="$STUBS"'; do_spl_local_hub_harden_check() { :; }; do_setup_app_inf() { return 3; }; do_spl_local_hub_up; echo "rc=$?"' in_orc LOCAL_HUB_USER="$ME")
[[ "$out" == *rc=1* && "$out" != *TENANT* ]] && pass "_up: a not-green smoke (exit 3) stops it" || fail "smoke 3: $out"

# --- 6. the workspace, once --------------------------------------------------------------------
S6="$T/s6"; mkdir -p "$S6"
TEN='LDE_PG_USER=u LDE_PG_PASSWORD=p LDE_PG_DB=d; _slh_spool() { echo "SPOOL $*" >>"$LDE_STATE_DIR/spool.calls"; [[ "$1" == root-keygen ]] && echo PUBKEY; return 0; }; _slh_tenant; echo "rc=$?"'
out=$(SNIPPET="$TEN" in_orc LDE_STATE_DIR="$S6" LOCAL_HUB_TENANT=e2e-abc123)
grep -q -- '^SPOOL hub-tenant --tenant e2e-abc123 --root-pubkey PUBKEY --db postgres://u:p@pg:5432/d' "$S6/spool.calls" && [[ "$out" == *rc=0* ]] \
  && pass "workspace: created with a fresh root key" || fail "create: $(cat "$S6/spool.calls" 2>&1) / $out"
[[ "$(stat -c %a "$S6/tenant")" == 700 && "$(stat -c %a "$S6/tenant/created")" == 600 ]] && pass "workspace: its dir 0700, files 0600" || fail "modes: $(ls -la "$S6/tenant")"
: >"$S6/spool.calls"
out=$(SNIPPET="$TEN" in_orc LDE_STATE_DIR="$S6" LOCAL_HUB_TENANT=e2e-abc123)
[[ ! -s "$S6/spool.calls" && "$out" == *rc=0* ]] && pass "workspace: a re-run creates nothing" || fail "rerun: $(cat "$S6/spool.calls") / $out"
out=$(SNIPPET="$TEN" in_orc LDE_STATE_DIR="$S6" LOCAL_HUB_TENANT=e2e-other1)
[[ "$out" == *rc=1* && "$out" == *"another workspace"* ]] && pass "workspace: another name on the same state dir is refused" || fail "other: $out"

# --- 7. the loopback gate ----------------------------------------------------------------------------
ssout() { printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$1" >"$T/ss"; chmod +x "$T/ss"; }
lb() { SNIPPET='spl_local_hub_loopback_only 58180; echo "rc=$?"' in_orc LOCAL_HUB_SS="$T/ss"; }
ssout "'LISTEN 0 4096 127.0.0.1:58180 0.0.0.0:*' 'LISTEN 0 4096 [::1]:58180 [::]:*'"
[[ "$(lb)" == *rc=0* ]] && pass "loopback: 127.0.0.1 and [::1] pass" || fail "loopback ok: $(lb)"
ssout "'LISTEN 0 4096 0.0.0.0:58180 0.0.0.0:*'"
[[ "$(lb)" == *rc=1* && "$(lb)" == *"beyond loopback"* ]] && pass "loopback: 0.0.0.0 fails" || fail "wildcard: $(lb)"
ssout "'LISTEN 0 4096 192.0.2.7:58180 0.0.0.0:*' 'LISTEN 0 4096 127.0.0.1:58180 0.0.0.0:*'"
[[ "$(lb)" == *rc=1* ]] && pass "loopback: a public address beside loopback fails" || fail "public: $(lb)"
printf '#!/bin/sh\nexit 0\n' >"$T/ss"
[[ "$(lb)" == *rc=1* && "$(lb)" == *"nothing listens"* ]] && pass "loopback: no listener fails" || fail "none: $(lb)"

# --- 8. _down ---------------------------------------------------------------------------------------------
DN='spl_local_hub_env() { :; }; do_gen_docker_env() { :; }; LDE_COMPOSE_PROJECT=p; lde_compose() { echo "COMPOSE $*"; }; do_spl_local_hub_down'
out=$(SNIPPET="$DN" in_orc LOCAL_HUB_USER="$ME")
[[ "$out" == *"COMPOSE down --remove-orphans"* && "$out" != *" -v"* ]] && pass "_down keeps the volumes" || fail "down: $out"
out=$(SNIPPET="$DN" in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_PURGE=1)
[[ "$out" != *COMPOSE* && "$out" == *DRY_RUN* ]] && pass "_down: purge without DRY_RUN=0 removes nothing" || fail "purge dry: $out"
mkdir -p "$T/s8/tenant"; touch "$T/s8/tenant/created"
out=$(SNIPPET="$DN" in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_PURGE=1 LDE_STATE_DIR="$T/s8")
[[ -e "$T/s8/tenant/created" ]] && pass "_down: a dry purge keeps the workspace stamp" || fail "dry purge removed the stamp"
out=$(SNIPPET="$DN" in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_PURGE=1 DRY_RUN=0 LDE_STATE_DIR="$T/s8")
[[ "$out" == *"COMPOSE down --remove-orphans -v"* && ! -e "$T/s8/tenant" ]] \
  && pass "_down: LOCAL_HUB_PURGE=1 DRY_RUN=0 removes the volumes and the workspace stamp" || fail "purge: $out"

# --- 9. hub.env with the overlay ----------------------------------------------------------------------------
GEN='do_gen_docker_env >/dev/null && cat "$LDE_HUB_ENV_FILE"'
if [[ -f "$APP_ROOT/csi-spl-iac/lib/bash/funcs/spl-merged-cnf.func.sh" ]]; then
  out=$(SNIPPET="$GEN" in_orc LDE_STATE_DIR="$T/s9" LDE_WUI_PORT=3180 LDE_AUTH_NATIVE=1 LDE_HUB_ENV_OVERLAY=.env.lde.local_hub.hub.env)
  grep -qx 'SPOOL_HUB_VIEW_DOOR=session' <<<"$out" && grep -qx 'SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=false' <<<"$out" \
    && grep -qx 'SPOOL_HUB_MAIL_TRANSPORT=none' <<<"$out" && grep -qx 'SPOOL_HUB_AUTH_NATIVE_ENABLED=true' <<<"$out" \
    && pass "overlay: session door, no debug tokens, no mail, native on" || fail "overlay values: $out"
  grep -qx 'SPOOL_HUB_AUTH_APP_URL=http://localhost:3180' <<<"$out" && pass "overlay: APP_URL on the local WUI port" || fail "app url: $(grep APP_URL <<<"$out")"
  grep -q 'REDIRECT_URI' <<<"$out" && fail "overlay: a redirect URI is left: $(grep REDIRECT <<<"$out")" || pass "overlay: an empty value removes the redirect URIs"
  hosts=$(grep -oE 'https?://[^/:"]+' <<<"$out" | sed -E 's#https?://##' | grep -vE '^(localhost|[a-z0-9-]+\.localhost|127\.[0-9.]+|[a-z0-9-]+)$' | sort -u | tr '\n' ' ')
  [[ -z "$hosts" ]] && pass "overlay: hub.env names no outside host" || fail "overlay: outside hosts in hub.env: $hosts"
  out=$(SNIPPET="$GEN" in_orc LDE_STATE_DIR="$T/s9b" LDE_AUTH_NATIVE=1)
  grep -qx 'SPOOL_HUB_VIEW_DOOR=off' <<<"$out" && grep -q 'GOOGLE_REDIRECT_URI' <<<"$out" \
    && pass "control: the plain lde render keeps the open door and the redirect URIs" || fail "control: $out"
  out=$(SNIPPET='do_gen_docker_env; echo "rc=$?"' in_orc LDE_STATE_DIR="$T/s9c" LDE_HUB_ENV_OVERLAY=.env.lde.nope)
  [[ "$out" == *"is not a map"* && "$out" == *rc=1* ]] && pass "overlay: an absent cnf path is refused" || fail "bad overlay: $out"
else
  skip "no csi-spl-iac merge function in this tree"
fi

# --- 10. lde_compose overlays --------------------------------------------------------------------------------------------
out=$(SNIPPET='docker() { echo "DOCKER $*"; }; LDE_COMPOSE_PROJECT=p LDE_COMPOSE_ENV=e LDE_DOCKER_DIR=/d; lde_compose ps' in_orc LDE_COMPOSE_EXTRA_FILES="/x/a.yaml /x/b.yaml")
[[ "$out" == *"compose -p p --env-file e -f /d/docker-compose-infra.yaml -f /d/docker-compose-rdb.yaml -f /d/docker-compose-api.yaml -f /d/docker-compose-wui.yaml -f /x/a.yaml -f /x/b.yaml ps" ]] \
  && pass "lde_compose: the four lde files, then the overlays" || fail "compose args: $out"

# --- 11. _update ------------------------------------------------------------------------------------------------------------
G="$T/git"; mkdir -p "$G"
git init -q --bare -b master "$G/origin.git"
git clone -q "$G/origin.git" "$G/seed" 2>/dev/null
mkdir -p "$G/seed/csi-spl-orc"
printf '#!/bin/sh\necho "UP-FROM $(git rev-parse --short HEAD) $*"\n' >"$G/seed/csi-spl-orc/run"; chmod +x "$G/seed/csi-spl-orc/run"
gc() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
gc "$G/seed" add -A && gc "$G/seed" commit -qm one && gc "$G/seed" push -q origin HEAD:master
git clone -q "$G/origin.git" "$G/tree"
echo two >"$G/seed/f" && gc "$G/seed" add f && gc "$G/seed" commit -qm two && gc "$G/seed" push -q origin HEAD:master
new=$(git -C "$G/seed" rev-parse --short HEAD)
out=$(SNIPPET='do_spl_local_hub_update; echo "rc=$?"' in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_TREE="$G/tree")
[[ "$out" == *"UP-FROM $new -a do_spl_local_hub_up"* && "$out" == *rc=0* ]] \
  && pass "_update: fast-forward, then the tree's own up" || fail "update: $out"
echo three >"$G/seed/f" && gc "$G/seed" commit -qam three && gc "$G/seed" push -q origin HEAD:master
echo local >"$G/tree/g" && gc "$G/tree" add g && gc "$G/tree" commit -qm local
before=$(git -C "$G/tree" rev-parse HEAD)
out=$(SNIPPET='do_spl_local_hub_update; echo "rc=$?"' in_orc LOCAL_HUB_USER="$ME" LOCAL_HUB_TREE="$G/tree")
[[ "$out" == *rc=1* && "$out" == *"cannot fast-forward"* && "$(git -C "$G/tree" rev-parse HEAD)" == "$before" && "$out" != *UP-FROM* ]] \
  && pass "_update: a diverged tree is refused and left as it was" || fail "diverged: $out"

echo
(( fails == 0 )) && { echo "ALL PASS"; exit 0; } || { echo "$fails FAIL"; exit 1; }
