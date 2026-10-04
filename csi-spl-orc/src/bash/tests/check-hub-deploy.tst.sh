#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_hub_deploy (spec 008 FR-P09) reads the live hub service
#          and compares it with cnf env.hub.image.ref -- and only reads.
#   1. current   (image == cnf ref, Ready, latest revision ready) -> rc 0
#   2. lagging   (another image)                                  -> rc 3
#      minted versions: a tag at/above the cnf floor is current; with
#      SPL_HUB_IMAGE_TAG (the deploy job) only exactly that tag is;
#      past 9.9.9 the tag is the key 1.0.1-c2 (/version shows 1.0.1)
#   3. unhealthy (Ready False / latest revision not the ready one) -> rc 4,
#      Ready read by condition TYPE, not by position
#   4. describe fails (no service / no access)                     -> rc 1
#   5. no GCP_ACCOUNT and no per-env SA key -> refused, never the owner account
#   6. every gcloud call carries --account, and none mutates
#      (no update / deploy / create / delete / set-iam / add-iam)
#      CONTROL: the stub records a call when one is made.
#   7. provider none (spec 076 T008, routed by do_spl_cloud_dispatch): the
#      compose hub container + /healthz, stubbed docker and curl, and ZERO
#      gcloud calls (a gcloud stub that records any call and fails):
#      current 0, unhealthy 4 (not healthy / no 2xx), lagging 3 (tag), no
#      hub container or no compose file 1; hub_deploy roll under none is
#      `docker compose up -d --wait`, under gcp the router's FATAL.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# nosa_home: a HOME with no ~/.gcp: no per-env SA key, while the REAL cnf
# still carries env.gcp.gcp_account_owner_email -- the CONTROL that a missing
# key is refused and the owner account is NEVER the fallback (owner rule
# 2026-09-19: the per-env service accounts only)
mkdir -p "$T/nosa_home"

# gcloud stub: records every call; mints a fake token; `run services describe`
# prints $FIXTURE, or fails when FIXTURE is empty.
mkdir -p "$T/stub"
cat >"$T/stub/gcloud" <<'EOF'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in
  "auth print-access-token"*) echo fake-token; exit 0 ;;
  "run services describe"*) [ -n "$FIXTURE" ] && cat "$FIXTURE" && exit 0
                            echo "ERROR: (gcloud.run.services.describe) NOT_FOUND" >&2; exit 1 ;;
esac
exit 1
EOF
chmod +x "$T/stub/gcloud"

export ENV=dev
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/$ENV" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_check_hub_deploy'
}

ref=$(env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/ref" bash -c '
  do_log() { :; }; for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
  do_spl_cloud_cnf && echo "$SPL_IMAGE_REF"')
[[ -n "$ref" ]] || { fail "cannot resolve the dev cnf image ref"; exit 1; }

fixture() { # <file> <image> <ready> <created> <latest>
  cat >"$1" <<EOF
{"spec":{"template":{"spec":{"containers":[{"image":"$2"}]}}},
 "status":{"conditions":[{"type":"ConfigurationsReady","status":"True"},{"type":"Ready","status":"$3"}],
           "latestCreatedRevisionName":"$4","latestReadyRevisionName":"$5"}}
EOF
}

check() { # <label> <want rc> <want verdict word or ""> [env...]
  local label="$1" want="$2" word="$3"; shift 3
  out=$(in_orc GCP_ACCOUNT=op@example.com "$@" 2>"$T/err"); rc=$?
  if [[ $rc -eq $want && ( -z "$word" || "$out" == "dev $word "* ) ]]; then pass "$label (rc $rc)"
  else fail "$label: rc=$rc want $want, out='$out' err='$(tail -1 "$T/err")'"; fi
}

fixture "$T/current.json" "$ref" True r-2 r-2
fixture "$T/lagging.json" "${ref%:*}:0.0.0-old" True r-1 r-1
fixture "$T/notready.json" "$ref" False r-3 r-2
fixture "$T/rollout.json" "$ref" True r-3 r-2

: >"$T/calls.log"
check "current: cnf image, Ready, latest revision ready" 0 current FIXTURE="$T/current.json"
check "lagging: service runs another image"               3 lagging FIXTURE="$T/lagging.json"
check "unhealthy: Ready=False (read by type, not index)"  4 unhealthy FIXTURE="$T/notready.json"
check "unhealthy: latest created revision is not ready"   4 unhealthy FIXTURE="$T/rollout.json"
check "describe fails -> cannot tell"                     1 "" FIXTURE=

# The release version is minted per deploy; cnf hub.image.tag is the floor.
floor="${ref##*:}"
IFS=. read -r fa fb fc <<<"$floor"
ahead="$fa.$fb.$(( fc < 9 ? fc + 1 : fc ))"; [[ "$ahead" != "$floor" ]] || ahead="$fa.$(( fb < 9 ? fb + 1 : fb )).0"
behind="0.0.0"
fixture "$T/ahead.json" "${ref%:*}:$ahead" True r-4 r-4
fixture "$T/behind.json" "${ref%:*}:$behind" True r-4 r-4
fixture "$T/otherrepo.json" "example.com/other/spool-hub:$ahead" True r-4 r-4
check "current: a minted tag ABOVE the floor ($ahead > $floor), no SPL_HUB_IMAGE_TAG" 0 current FIXTURE="$T/ahead.json"
check "lagging: a tag BELOW the floor ($behind < $floor)"                            3 lagging FIXTURE="$T/behind.json"
check "lagging: a later tag in ANOTHER repository"                                   3 lagging FIXTURE="$T/otherrepo.json"
check "current: SPL_HUB_IMAGE_TAG=$ahead and the service runs exactly it"            0 current FIXTURE="$T/ahead.json" SPL_HUB_IMAGE_TAG="$ahead"
check "lagging: SPL_HUB_IMAGE_TAG=$ahead but the service still runs the floor"       3 lagging FIXTURE="$T/current.json" SPL_HUB_IMAGE_TAG="$ahead"

# Past 9.9.9 the image tag is the release KEY 1.0.1-c2 while /version shows
# 1.0.1 (spl-release-version CYCLES); cycle 1's :1.0.1 is another image.
fixture "$T/c2.json" "${ref%:*}:1.0.1-c2" True r-5 r-5
fixture "$T/c1.json" "${ref%:*}:1.0.1" True r-5 r-5
check "current: cycle-2 key 1.0.1-c2 is later than the cycle-1 floor ($floor)"       0 current FIXTURE="$T/c2.json"
check "lagging: cycle-1 1.0.1 is still below the floor ($floor)"                     3 lagging FIXTURE="$T/c1.json"
check "current: SPL_HUB_IMAGE_TAG=1.0.1-c2 and the service runs exactly :1.0.1-c2"   0 current FIXTURE="$T/c2.json" SPL_HUB_IMAGE_TAG=1.0.1-c2
check "lagging: SPL_HUB_IMAGE_TAG=1.0.1-c2 but the service runs cycle-1 :1.0.1"      3 lagging FIXTURE="$T/c1.json" SPL_HUB_IMAGE_TAG=1.0.1-c2
check "lagging: the plain /version 1.0.1 is not the key of a :1.0.1-c2 service"      3 lagging FIXTURE="$T/c2.json" SPL_HUB_IMAGE_TAG=1.0.1
check "refused: SPL_HUB_IMAGE_TAG=1.0.1-c1 is no release key (cycle 1 is plain)"     1 "" FIXTURE="$T/c2.json" SPL_HUB_IMAGE_TAG=1.0.1-c1

out=$(in_orc GCP_ACCOUNT= HOME="$T/nosa_home" FIXTURE="$T/current.json" 2>&1); rc=$?
owner=$(yq -r '.env.gcp.gcp_account_owner_email // ""' "$APP_ROOT"/*-cnf/*/all.env.yaml)
[[ $rc -ne 0 && -n "$owner" ]] && grep -q 'no project SA key' <<<"$out" && ! grep -qF "$owner" <<<"$out" \
  && pass "no GCP_ACCOUNT and no SA key is refused; the cnf owner account is never used" || fail "no account: rc=$rc $out"

n=$(grep -c '^gcloud ' "$T/calls.log")
[[ $n -ge 10 ]] && pass "control: the stub recorded $n gcloud calls" || fail "control: stub recorded only $n calls"
if grep -vq -- '--account=op@example.com' "$T/calls.log"; then fail "a gcloud call without --account: $(grep -v -- '--account=' "$T/calls.log" | sed -n 1p)"
else pass "every gcloud call carries --account"; fi
if grep -Eq ' (update|deploy|create|delete|set-iam-policy|add-iam-policy-binding|replace)( |$)' "$T/calls.log"; then
  fail "a mutating gcloud call: $(grep -E ' (update|deploy|create|delete|set-iam-policy|add-iam-policy-binding|replace)( |$)' "$T/calls.log" | sed -n 1p)"
else pass "no mutating gcloud call (describe + token mint only)"; fi

# --- 7. provider none: no gcloud, the compose stack and /healthz ------------
# docker: `compose ps` prints $PS_ROW (tab-separated State Health Image), fails
# when PS_FAIL=1; every call logged. curl: logs its argv, exits $CURL_RC.
# gcloud: logs any call to its own file and fails -- one line there is a FAIL.
S="$T/stack"; mkdir -p "$S" "$T/nstub"
echo 'name: spool' >"$S/docker-compose.yml"
cat >"$T/nstub/docker" <<'EOF'
#!/bin/sh
echo "docker $*" >>"$NSTUB_LOG"
case "$*" in *" ps "*) [ "${PS_FAIL:-0}" = 1 ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
                       [ -n "${PS_ROW:-}" ] && printf '%b\n' "$PS_ROW" ;; esac
exit 0
EOF
cat >"$T/nstub/curl" <<'EOF'
#!/bin/sh
echo "curl $*" >>"$NSTUB_LOG"; exit "${CURL_RC:-0}"
EOF
cat >"$T/nstub/gcloud" <<'EOF'
#!/bin/sh
echo "gcloud $*" >>"$GCLOUD_LOG"; exit 99
EOF
chmod +x "$T/nstub/"*
: >"$T/gcloud-none.log"
HUB_IMG="${ref%:*}:$ahead"
in_none() { # [VAR=value ...] -- <snippet>; stdout -> $T/nout, stderr -> $T/nerr
  local -a envs=(); while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done; shift
  : >"$T/nstub.log"
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" NSTUB_LOG="$T/nstub.log" GCLOUD_LOG="$T/gcloud-none.log" \
    PATH="$T/nstub:$PATH" SPOOL_CLOUD_PROVIDER=none SPOOL_SELF_HOST_DIR="$S" SPOOL_PUBLIC_URL= \
    PS_ROW="running\thealthy\t$HUB_IMG" "${envs[@]}" SNIPPET="$1" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"' >"$T/nout" 2>"$T/nerr"
}
ncheck() { # <label> <want rc> <want verdict word or ""> [env...]
  local label="$1" want="$2" word="$3"; shift 3
  in_none "$@" -- do_check_hub_deploy; local rc=$? out; out=$(cat "$T/nout")
  if [[ $rc -eq $want && ( -z "$word" || "$out" == "dev $word "* ) ]]; then pass "none: $label (rc $rc)"
  else fail "none: $label: rc=$rc want $want, out='$out' err='$(tail -1 "$T/nerr")'"; fi
}
printf "SPOOL_PUBLIC_URL='https://chat.example.com'\n" >"$S/.env"
ncheck "hub running + healthy, /healthz 2xx -> current"          0 current
grep -q "^curl .*https://chat.example.com/healthz" "$T/nstub.log" && grep -q "^docker compose --project-directory $S ps .* hub" "$T/nstub.log" \
  && pass "none: probes the compose hub container and the .env SPOOL_PUBLIC_URL /healthz" || fail "none: probe calls: $(cat "$T/nstub.log")"
ncheck "hub health=starting -> unhealthy"                        4 unhealthy PS_ROW="running\tstarting\t$HUB_IMG"
grep -q '^curl ' "$T/nstub.log" && fail "none: curl ran although the container is not healthy" || pass "none: an unhealthy container is reported before any HTTP probe"
ncheck "hub exited -> unhealthy"                                 4 unhealthy PS_ROW="exited\t\t$HUB_IMG"
ncheck "container healthy but /healthz no 2xx -> unhealthy"      4 unhealthy CURL_RC=22
ncheck "SPL_HUB_IMAGE_TAG=$ahead and the hub runs it -> current" 0 current SPL_HUB_IMAGE_TAG="$ahead"
ncheck "SPL_HUB_IMAGE_TAG=9.9.9 but the hub runs $ahead -> lagging" 3 lagging SPL_HUB_IMAGE_TAG=9.9.9
ncheck "no hub container -> cannot tell"                         1 "" PS_ROW=
ncheck "docker daemon does not answer -> cannot tell"            1 "" PS_FAIL=1
ncheck "no docker-compose.yml -> cannot tell"                    1 "" SPOOL_SELF_HOST_DIR="$T/nostack"
rm -f "$S/.env"
ncheck "no SPOOL_PUBLIC_URL -> the local port"                   0 current SPOOL_HTTP_PORT=18080
grep -q "^curl .*http://127.0.0.1:18080/healthz" "$T/nstub.log" && pass "none: without SPOOL_PUBLIC_URL /healthz is the local SPOOL_HTTP_PORT" || fail "none: local url: $(cat "$T/nstub.log")"
ncheck "SPOOL_HUB_HEALTH_URL wins"                               0 current SPOOL_HUB_HEALTH_URL=http://127.0.0.1:9/healthz
grep -q "^curl .*http://127.0.0.1:9/healthz" "$T/nstub.log" && pass "none: SPOOL_HUB_HEALTH_URL is the probe" || fail "none: health url: $(cat "$T/nstub.log")"

# hub_deploy roll: none is do_spl_self_host_up's `docker compose up -d --wait`;
# gcp has no shell roll (workflows 20 and 30 deploy the cloud), so the router FATALs.
in_none -- 'do_spl_cloud_dispatch hub_deploy roll "$SPOOL_SELF_HOST_DIR"'; rc=$?
[[ $rc -eq 0 ]] && grep -qx "docker compose --project-directory $S up -d --wait" "$T/nstub.log" \
  && pass "none: hub_deploy roll is docker compose up -d --wait on the stack" || fail "none roll: rc=$rc $(cat "$T/nstub.log") $(cat "$T/nerr")"
in_none SPOOL_CLOUD_PROVIDER=gcp -- 'do_spl_cloud_dispatch hub_deploy roll "$SPOOL_SELF_HOST_DIR"'; rc=$?
[[ $rc -eq 1 ]] && grep -q 'do_hub_deploy_roll_gcp is not defined' "$T/nerr" && [[ ! -s "$T/nstub.log" ]] \
  && pass "gcp: hub_deploy roll has no shell adapter (router FATAL, nothing run)" || fail "gcp roll: rc=$rc $(cat "$T/nerr")"

n=$(wc -l <"$T/gcloud-none.log")
[[ $n -eq 0 ]] && pass "none: zero gcloud calls across every none case" || fail "none: $n gcloud call(s): $(sed -n 1p "$T/gcloud-none.log")"
GCLOUD_LOG="$T/gcloud-ctl.log" "$T/nstub/gcloud" run services describe x >/dev/null 2>&1
[[ -s "$T/gcloud-ctl.log" ]] && pass "control: the none gcloud stub records a call when one is made" || fail "control: none gcloud stub records nothing"

[[ $fails -eq 0 ]] && echo "PASS: all check-hub-deploy assertions" || { echo "FAILED: $fails"; exit 1; }
