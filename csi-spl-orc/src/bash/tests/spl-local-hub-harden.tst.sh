#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local hub's hardening gates (spl-local-hub-harden-check.func.sh, spl-local-hub-ports-gate.func.sh),
#   hermetic: a temp cnf, temp /etc/sub[ug]id, linger and run dirs, the test
#   user as the hub user, stub docker / ss / getent / id on PATH.
#   1. _slh_cnf reads user, home, project and ports from cnf env.lde.local_hub;
#      LOCAL_HUB_USER / LOCAL_HUB_HOME win; a missing key is FATAL, no literal
#   2. harden_check on a good host: no FAIL line, exit 0
#   3. harden_check FAILs (exit 1), one case each: home 0755, the hub user in
#      the docker group, another user in its group, no subuid line, no linger,
#      a rootful daemon, a data root outside the home, a compose port on
#      0.0.0.0 or with no host_ip, a hub.env with a cloud endpoint, with no
#      GCS emulator or with cloud credentials, a container pid owned by host
#      root, a running container published on 0.0.0.0; control: a container
#      as the hub user on 127.0.0.1 passes
#   4. ports_gate: loopback listeners pass; a hub-user listener on 0.0.0.0, a
#      local hub port on [::] by anyone, and a public udp one of the hub user
#      fail; a foreign public listener on another port is not its business
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ME=$(id -un); MYUID=$(id -u); MYGID=$(id -g); MYGRP=$(id -gn)
export T ME MYUID MYGID MYGRP

mkdir -p "$T/bin" "$T/home" "$T/linger" "$T/run/$MYUID" "$T/etc"
chmod 0700 "$T/home" "$T/run/$MYUID"
cat >"$T/lde.env.yaml" <<EOF
env:
  lde:
    local_hub:
      user: hub-from-cnf
      home: /var/lib/hub-from-cnf
      compose_project: proj-from-cnf
      pg_port: 55532
      gcs_port: 54543
      hub_port: 58180
      wui_port: 3180
EOF

# --- stubs: every answer is a file a case can rewrite --------------------------
cat >"$T/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "info --format {{json .SecurityOptions}}") cat "$T/d.secopt" ;;
  "info --format {{.DockerRootDir}}") cat "$T/d.root" ;;
  "ps -q --filter label=com.docker.compose.project=proj-x") cat "$T/d.ps" ;;
  inspect*) cat "$T/d.inspect" ;;
  *) echo "docker stub: \$*" >&2; exit 2 ;;
esac
EOF
cat >"$T/bin/ss" <<EOF
#!/usr/bin/env bash
cat "$T/ss.out"
EOF
cat >"$T/bin/getent" <<EOF
#!/usr/bin/env bash
case "\$1" in
  group) cat "$T/g.group" ;;
  passwd) echo "$ME:x:$MYUID:$MYGID::$T/home:/usr/sbin/nologin" ;;
esac
EOF
cat >"$T/bin/id" <<EOF
#!/usr/bin/env bash
[[ "\$1" == -nG ]] && { cat "$T/id.groups"; exit 0; }
exec /usr/bin/id "\$@"
EOF
chmod +x "$T/bin/"*

good_state() {
  chmod 0700 "$T/home"
  echo '["name=seccomp,profile=builtin","name=rootless","name=cgroupns"]' >"$T/d.secopt"
  echo "$T/home/.local/share/docker" >"$T/d.root"
  : >"$T/d.ps"; : >"$T/d.inspect"
  echo "$MYGRP" >"$T/id.groups"
  echo "$MYGRP:x:$MYGID:" >"$T/g.group"
  echo "$ME:100000:65536" >"$T/etc/subuid"; echo "$ME:100000:65536" >"$T/etc/subgid"
  touch "$T/linger/$ME"
  [[ -S "$T/run/$MYUID/docker.sock" ]] || python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$T/run/$MYUID/docker.sock"
  echo '{"services":{"pg":{"ports":[{"host_ip":"127.0.0.1","published":"55532","target":5432}]},"x":{}}}' >"$T/compose.json"
  printf 'STORAGE_EMULATOR_HOST=http://gcs:4443\nSPOOL_HUB_DATABASE_URL=postgres://u@pg:5432/d\n' >"$T/hub.env"
  printf 'tcp LISTEN 0 4096 127.0.0.1:58180 0.0.0.0:* uid:%s ino:1 sk:1 <->\ntcp LISTEN 0 4096 [::1]:3180 [::]:* uid:%s ino:2 sk:2 <->\ntcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* ino:3 sk:3 <->\n' "$MYUID" "$MYUID" >"$T/ss.out"
}

run_fn() {
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" LOCAL_HUB_CNF="$T/lde.env.yaml" \
    LOCAL_HUB_USER="$ME" LOCAL_HUB_HOME="$T/home" LOCAL_HUB_PROJECT=proj-x \
    LOCAL_HUB_SUBUID_FILE="$T/etc/subuid" LOCAL_HUB_SUBGID_FILE="$T/etc/subgid" \
    LOCAL_HUB_LINGER_DIR="$T/linger" LOCAL_HUB_RUN_DIR="$T/run" LOCAL_HUB_SYS_UID_MAX=999999 \
    LOCAL_HUB_COMPOSE_JSON="$T/compose.json" LOCAL_HUB_HUB_ENV="$T/hub.env" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-local-hub-harden-check.func.sh"; source "$PROJ_PATH/src/bash/run/spl-local-hub-ports-gate.func.sh"
    eval "$SNIPPET"'
}
export -f run_fn

# --- 1. cnf ---------------------------------------------------------------------
out=$(env -u LOCAL_HUB_USER -u LOCAL_HUB_HOME PROJ_PATH="$PROJ_ROOT" LOCAL_HUB_CNF="$T/lde.env.yaml" bash -c '
  do_log() { echo "$*"; }; source "$PROJ_PATH/src/bash/run/spl-local-hub-harden-check.func.sh"; source "$PROJ_PATH/src/bash/run/spl-local-hub-ports-gate.func.sh"
  _slh_cnf && echo "U=$LOCAL_HUB_USER H=$LOCAL_HUB_HOME P=$LOCAL_HUB_PROJECT PORTS=$LOCAL_HUB_PORTS"' 2>&1)
[[ "$out" == "U=hub-from-cnf H=/var/lib/hub-from-cnf P=proj-from-cnf PORTS=55532 54543 58180 3180" ]] \
  && pass "cnf: user, home, project and the four ports come from env.lde.local_hub" || fail "cnf: $out"
out=$(SNIPPET='_slh_cnf && echo "U=$LOCAL_HUB_USER H=$LOCAL_HUB_HOME"' run_fn 2>&1)
[[ "$out" == "U=$ME H=$T/home" ]] && pass "cnf: LOCAL_HUB_USER / LOCAL_HUB_HOME win" || fail "cnf env: $out"
yq -i 'del(.env.lde.local_hub.hub_port)' "$T/lde.env.yaml"
out=$(SNIPPET='_slh_cnf && echo OK' run_fn 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *FATAL*hub_port* ]] && pass "cnf: a missing key is FATAL (no literal default)" || fail "cnf missing key: rc=$rc $out"
yq -i '.env.lde.local_hub.hub_port = 58180' "$T/lde.env.yaml"

# --- 2. a good host ---------------------------------------------------------------
good_state
out=$(SNIPPET='do_spl_local_hub_harden_check' run_fn 2>&1); rc=$?
if [[ $rc -eq 0 && "$out" != *FAIL* ]]; then pass "harden_check: a good host passes (exit 0, $(grep -c '^PASS' <<<"$out") PASS lines)"
else fail "harden_check good host: rc=$rc"; echo "$out"; fi

# --- 3. one FAIL per case -----------------------------------------------------------
expect_fail() {  # <name> <grep in the FAIL line> <mutation>
  good_state; eval "$3"
  out=$(SNIPPET='do_spl_local_hub_harden_check' run_fn 2>&1); rc=$?
  if [[ $rc -eq 1 ]] && grep -q "^FAIL.*$2" <<<"$out"; then pass "harden_check FAILs: $1"
  else fail "harden_check did not FAIL on $1 (rc=$rc): $(grep -E '^(FAIL|FATAL)' <<<"$out")"; fi
}
expect_fail "home 0755" "home" 'chmod 0755 "$T/home"'
expect_fail "the hub user in the docker group" "docker" 'echo "$MYGRP docker" >"$T/id.groups"'
expect_fail "another user in its group" "group" 'echo "$MYGRP:x:$MYGID:intruder" >"$T/g.group"'
expect_fail "no subuid line" "subuid" ': >"$T/etc/subuid"'
expect_fail "no linger" "linger" 'rm -f "$T/linger/$ME"'
expect_fail "a rootful daemon" "rootless" 'echo "[\"name=seccomp,profile=builtin\"]" >"$T/d.secopt"'
expect_fail "a data root outside the home" "data root" 'echo /var/lib/docker >"$T/d.root"'
expect_fail "a compose port on 0.0.0.0" "compose" 'echo "{\"services\":{\"wui\":{\"ports\":[{\"host_ip\":\"0.0.0.0\",\"published\":\"3180\",\"target\":3000}]}}}" >"$T/compose.json"'
expect_fail "a compose port with no host_ip" "compose" 'echo "{\"services\":{\"wui\":{\"ports\":[{\"published\":\"3180\",\"target\":3000}]}}}" >"$T/compose.json"'
expect_fail "a hub.env with a cloud endpoint" "hub.env" 'echo "SPOOL_HUB_X=https://storage.googleapis.com/b" >>"$T/hub.env"'
expect_fail "a hub.env with no GCS emulator" "STORAGE_EMULATOR_HOST" 'grep -v STORAGE_EMULATOR_HOST "$T/hub.env" >"$T/h2"; mv "$T/h2" "$T/hub.env"'
expect_fail "a hub.env with cloud credentials" "hub.env" 'echo "GOOGLE_APPLICATION_CREDENTIALS=/k.json" >>"$T/hub.env"'
expect_fail "a hub.env sending mail by smtp" "mail" 'echo "SPOOL_HUB_MAIL_TRANSPORT=smtp" >>"$T/hub.env"'
expect_fail "a hub.env with social sign-in" "social" 'echo "SPOOL_HUB_AUTH_PROVIDERS=google" >>"$T/hub.env"'
expect_fail "a container pid owned by host root" "host root" 'echo c1 >"$T/d.ps"; echo "/c1 1 127.0.0.1" >"$T/d.inspect"'
expect_fail "a running container published on 0.0.0.0" "published" 'echo c1 >"$T/d.ps"; echo "/c1 $$ 0.0.0.0" >"$T/d.inspect"'
good_state; echo c1 >"$T/d.ps"; echo "/c1 $$ 127.0.0.1" >"$T/d.inspect"
out=$(SNIPPET='do_spl_local_hub_harden_check' run_fn 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "control: a container as the hub user, on 127.0.0.1, passes" || fail "control container: rc=$rc $(grep FAIL <<<"$out")"

# --- 4. the ports gate ----------------------------------------------------------------
good_state
out=$(SNIPPET='do_spl_local_hub_ports_gate' run_fn 2>&1); rc=$?
[[ $rc -eq 0 ]] && pass "ports_gate: loopback listeners + a foreign :22 pass" || fail "ports_gate good: rc=$rc $out"
gate_fail() {  # <name> <ss line>
  good_state; echo "$2" >>"$T/ss.out"
  out=$(SNIPPET='do_spl_local_hub_ports_gate' run_fn 2>&1); rc=$?
  [[ $rc -eq 1 && "$out" == *FAIL* ]] && pass "ports_gate FAILs: $1" || fail "ports_gate on $1: rc=$rc $out"
}
gate_fail "a hub-user listener on 0.0.0.0" "tcp LISTEN 0 4096 0.0.0.0:41000 0.0.0.0:* uid:$MYUID ino:9 sk:9 <->"
gate_fail "a local hub port on [::] by anyone" "tcp LISTEN 0 4096 [::]:55532 [::]:* ino:9 sk:9 <->"
gate_fail "a public udp listener of the hub user" "udp UNCONN 0 0 *:5353 *:* uid:$MYUID ino:9 sk:9 <->"

echo "--- spl-local-hub-harden: $fails failure(s)"
[[ $fails -eq 0 ]]
