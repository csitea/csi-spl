#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local stack is wired from cnf and only from cnf, and its smoke
#          cannot report a missing verb as present.
#   1. do_gen_docker_env renders hub.env whose KEYS are exactly the hub env
#      names published in all.env.yaml env.hub.env (+ the lde-only ones) --
#      it renames and invents nothing -- with lde values (pg/gcs services,
#      {tenant}.localhost)
#   2. docker compose accepts the four files (infra, rdb, api, wui) with the
#      rendered env, and every published port binds 127.0.0.1 only (SKIP
#      without docker)
#   3. the wui service mounts the WHOLE csi-spl-wui dir (survives a srcDir
#      move), runs with the mock off against http://{tenant}.localhost:<hub
#      port>, and the hub's CORS list carries the WUI origin -- also when the
#      WUI port is overridden (LDE_WUI_PORT), for a sibling tree's WUI port and
#      for LDE_WUI_EXTRA_ORIGINS (a wildcard is refused). The service starts
#      offline (the tree's own nuxt, no package manager), as the tree owner.
#   4. _sai_has_verb: a spool that says `unknown command` is NOT a verb, under
#      pipefail (the regression that reported a missing `serve` as present);
#      control: a known verb is one
#   5. do_provision_spool_root on a scratch dir (group = the caller's): sticky
#      cleared, setgid on, a file made later inherits the default ACL: group
#      rw, other nothing (SKIP without sudo -n; the outsider exploit and its
#      control are spool-permissions.tst.sh)
#   6. lde switches (env.lde.switches): default all off, no session key, no
#      PLACEHOLDER rendered, mail "log"; LDE_AUTH_NATIVE=1 + LDE_WUI_DISPATCH=1
#      turn native + an ephemeral box-wui key on, with a per-tree session key
#      that is 0600, stable across renders and never logged; the auth URLs
#      follow LDE_WUI_PORT; a social provider without caller creds fails
#      fast; a typo'd switch fails instead of reading as off
#   7. do_spl_pin_box_wui (stubbed hub, CLI and pg): 404 names the switch;
#      200 pins box-wui with --force and proves the pins row; control: a row
#      holding another key fails
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

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. hub.env = the published names, lde values ------------------------------
SNIPPET='do_gen_docker_env' in_orc >"$T/gen.out" 2>&1 || { fail "do_gen_docker_env: $(tail -3 "$T/gen.out")"; }
H="$T/state/hub.env"
if [[ -f "$H" ]]; then
  # hub.env + auth.social + auth.native + mail env keys whose MERGED value is
  # not a PLACEHOLDER, + the four switch names, + SPOOL_HUB_DEFAULT_LOCALE
  # (derived from env.i18n.default_locale by do_spl_merged_cnf, spec 021),
  # + the four SPOOL_HUB_DEMO_* (derived from env.demo, spec 077 T023)
  want=$( (yq ea -r '. as $i ireduce ({}; . * $i) | [.env.hub.env, .env.auth.social.env, .env.auth.native.env, .env.mail.env]
             | .[] | to_entries | .[] | select((.value | tostring | test("PLACEHOLDER")) | not) | .key' \
             "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml"
           printf '%s\n' SPOOL_HUB_AUTH_NATIVE_ENABLED SPOOL_HUB_AUTH_PROVIDERS SPOOL_HUB_WUI_DISPATCH SPOOL_HUB_WUI_KEY_EPHEMERAL SPOOL_HUB_DEFAULT_LOCALE \
             SPOOL_HUB_DEMO_ENABLED SPOOL_HUB_DEMO_WORKSPACE SPOOL_HUB_DEMO_PROVIDERS SPOOL_HUB_DEMO_MAX_LIVE) | sort -u)
  got=$(cut -d= -f1 "$H" | sort -u)
  [[ "$want" == "$got" ]] && pass "hub.env keys = cnf hub/auth/mail env keys (no PLACEHOLDER) + 4 switches ($(wc -l <<<"$got"))" \
    || fail "hub.env keys differ from cnf: $(diff <(echo "$want") <(echo "$got") | grep '^[<>]' | tr '\n' ' ')"
  grep -qx 'SPOOL_HUB_ENV=lde' "$H" && pass "SPOOL_HUB_ENV=lde" || fail "SPOOL_HUB_ENV is not lde"
  grep -q '^SPOOL_HUB_DB_DSN=postgres://[^@]*@pg:5432/' "$H" && pass "DSN points at the pg service" || fail "DSN does not point at pg:5432"
  grep -qx 'STORAGE_EMULATOR_HOST=gcs:4443' "$H" && pass "GCS emulator host is the gcs service" || fail "STORAGE_EMULATOR_HOST"
  grep -qx 'SPOOL_HUB_TENANT_HOST_PATTERN={tenant}.localhost' "$H" && pass "tenant host pattern {tenant}.localhost" || fail "tenant host pattern"
  [[ "$(stat -c %a "$H")" == 600 ]] && pass "hub.env is 0600" || fail "hub.env mode $(stat -c %a "$H")"
else
  fail "no hub.env rendered"
fi

# --- 2+3. compose accepts the files; every published port is loopback -------------
if docker compose version >/dev/null 2>&1 && [[ -f "$T/state/compose.env" ]]; then
  if docker compose -p lde-test --env-file "$T/state/compose.env" -f "$PROJ_ROOT/src/docker/docker-compose-infra.yaml" \
      -f "$PROJ_ROOT/src/docker/docker-compose-rdb.yaml" -f "$PROJ_ROOT/src/docker/docker-compose-api.yaml" \
      -f "$PROJ_ROOT/src/docker/docker-compose-wui.yaml" \
      config --format json >"$T/cfg.json" 2>"$T/cfg.err"; then
    pass "docker compose config accepts the 4 files"
    ips=$(yq -p json -r '.services[].ports[]?.host_ip' "$T/cfg.json" | sort | uniq -c | xargs)
    [[ "$ips" == "4 127.0.0.1" ]] && pass "all 4 published ports bind 127.0.0.1" || fail "published host_ip: $ips"
    src=$(yq -p json -r '.services.wui.volumes[] | select(.target == "/app") | .source' "$T/cfg.json")
    [[ "$src" == "$APP_ROOT/csi-spl-wui" ]] && pass "wui mounts the whole csi-spl-wui dir at /app" || fail "wui /app source: '$src'"
    [[ "$(yq -p json -r '.services.wui.environment.NUXT_PUBLIC_USE_MOCK' "$T/cfg.json")" == 0 ]] \
      && pass "wui runs with the mock off" || fail "wui NUXT_PUBLIC_USE_MOCK is not 0"
    base=$(yq -p json -r '.services.wui.environment.NUXT_PUBLIC_API_BASE' "$T/cfg.json")
    [[ "$base" =~ ^http://\{tenant\}\.localhost:[0-9]+$ ]] && pass "wui API base $base" || fail "wui API base: '$base'"
    proxy=$(yq -p json -r '.services.wui.environment.NUXT_DEV_AUTH_PROXY' "$T/cfg.json")
    [[ "$proxy" =~ ^http://hub:[0-9]+$ ]] && pass "wui proxies /api/v1/auth to $proxy (spec 010 FR-010)" || fail "wui auth proxy: '$proxy'"
    # offline at runtime: the tree's own nuxt, no corepack / pnpm / registry;
    # never root; no volume shadows node_modules (it IS the tree's)
    cmd=$(yq -p json -o json -I0 '.services.wui.command' "$T/cfg.json")
    [[ "$cmd" == *'node_modules/nuxt/bin/nuxt.mjs'* && "$cmd" != *pnpm* && "$cmd" != *corepack* && "$cmd" != *npm* ]] \
      && pass "wui starts the tree's nuxt offline: $cmd" || fail "wui command reaches for a package manager: $cmd"
    [[ "$(yq -p json -r '.services.wui.entrypoint // "none"' "$T/cfg.json")" == none ]] && pass "wui has no shell entrypoint" || fail "wui entrypoint set"
    user=$(yq -p json -r '.services.wui.user' "$T/cfg.json")
    [[ "$user" =~ ^[0-9]+:[0-9]+$ && "${user%%:*}" != 0 && "$user" == "$(stat -c %u:%g "$APP_ROOT/csi-spl-wui")" ]] \
      && pass "wui runs as the WUI tree owner $user" || fail "wui user '$user' (tree $(stat -c %u:%g "$APP_ROOT/csi-spl-wui"))"
    n=$(yq -p json -r '[.services.wui.volumes[]] | length' "$T/cfg.json")
    [[ "$n" == 1 ]] && pass "wui mounts only the tree (no node_modules/.nuxt shadow volume)" || fail "wui has $n volumes"
    # compose drops a profiled service from the default model: absent = gated
    [[ "$(yq -p json -r '.services | has("wui-install")' "$T/cfg.json")" == false ]] \
      && grep -A1 '^  wui-install:' "$PROJ_ROOT/src/docker/docker-compose-wui.yaml" | grep 'profiles: \[install\]' >/dev/null \
      && pass "the registry-bound install is a profile-gated one-shot (not in the default model)" || fail "wui-install is not profile-gated"
  else
    fail "compose config: $(head -3 "$T/cfg.err")"
  fi
else
  skip "no docker compose"
fi

# the WUI origin is allowed by the hub, at the cnf port and at an override
cors=$(sed -n 's/^SPOOL_HUB_VIEW_CORS_ORIGINS=//p' "$H" 2>/dev/null)
wport=$(yq -r '.env.lde.wui.host_port' "$APP_ROOT/csi-spl-cnf/csi-spl/lde.env.yaml")
[[ ",$cors," == *",http://localhost:$wport,"* ]] && pass "hub CORS allows the WUI origin (cnf port $wport)" || fail "hub CORS '$cors' lacks localhost:$wport"
SNIPPET='do_gen_docker_env' in_orc LDE_WUI_PORT=3999 >"$T/gen2.out" 2>&1 || fail "do_gen_docker_env LDE_WUI_PORT=3999: $(tail -3 "$T/gen2.out")"
cors2=$(sed -n 's/^SPOOL_HUB_VIEW_CORS_ORIGINS=//p' "$H" 2>/dev/null)
[[ ",$cors2," == *",http://localhost:3999,"* && ",$cors2," == *",http://localhost:$wport,"* ]] \
  && pass "LDE_WUI_PORT=3999 adds http://localhost:3999 and keeps the cnf origin" || fail "override CORS: '$cors2'"
[[ $(grep -c '^SPOOL_HUB_VIEW_CORS_ORIGINS=' "$H") == 1 ]] && pass "CORS name rendered once" || fail "CORS rendered $(grep -c '^SPOOL_HUB_VIEW_CORS_ORIGINS=' "$H") times"
# a sibling tree's WUI port (its rendered compose.env) and LDE_WUI_EXTRA_ORIGINS
# reach this tree's hub too: a worktree WUI reads the main hub with no proxy
mkdir -p "$T/sib-tree" && printf 'LDE_WUI_PORT=3067\n' >"$T/sib-tree/compose.env"
SNIPPET='do_gen_docker_env' in_orc LDE_WUI_EXTRA_ORIGINS='http://127.0.0.1:4001' >"$T/gen3.out" 2>&1 || fail "gen with sibling: $(tail -2 "$T/gen3.out")"
cors3=$(sed -n 's/^SPOOL_HUB_VIEW_CORS_ORIGINS=//p' "$H" 2>/dev/null)
[[ ",$cors3," == *",http://localhost:3067,"* ]] && pass "a sibling tree's WUI port 3067 is allowed" || fail "sibling CORS: '$cors3'"
[[ ",$cors3," == *",http://127.0.0.1:4001,"* ]] && pass "LDE_WUI_EXTRA_ORIGINS is allowed" || fail "extra CORS: '$cors3'"
[[ $(tr ',' '\n' <<<"$cors3" | sort | uniq -d | wc -l) == 0 ]] && pass "no origin listed twice" || fail "duplicate origins: $cors3"
SNIPPET='do_gen_docker_env' in_orc LDE_WUI_EXTRA_ORIGINS='*' >"$T/gen4.out" 2>&1 \
  && fail "control: LDE_WUI_EXTRA_ORIGINS='*' was accepted" || pass "control: a wildcard extra origin is refused"
rm -rf "$T/sib-tree"

# --- 4. verb detection under pipefail ------------------------------------------------
printf '#!/bin/sh\n[ "$1" = migrate ] && { echo "Usage of migrate:"; exit 0; }\necho "unknown command \\"$1\\""; exit 1\n' >"$T/spool"
chmod +x "$T/spool"
SNIPPET='_SAI_CLI='"$T/spool"'; _sai_has_verb serve && echo HAS-serve; _sai_has_verb migrate && echo HAS-migrate' in_orc >"$T/verb.out" 2>&1
grep -q HAS-serve "$T/verb.out" && fail "an unknown verb (serve) was detected as present" || pass "an 'unknown command' verb is not present (pipefail on)"
grep -q HAS-migrate "$T/verb.out" && pass "control: a known verb (migrate) is present" || fail "control: migrate not detected"

# --- 5. spool root permissions model ---------------------------------------------------
if sudo -n true 2>/dev/null && command -v setfacl >/dev/null; then
  d="$T/spool-root"; mkdir -p "$d"; chmod 1777 "$d"
  SNIPPET='do_provision_spool_root' in_orc SPOOL_ROOT_DIR="$d" SPOOL_ROOT_GROUP="$(id -gn)" >"$T/prov.out" 2>&1; rc=$?
  if [[ $rc -eq 0 && ! -k "$d" && -g "$d" ]]; then pass "sticky cleared, setgid set"; else fail "provision rc=$rc sticky=$([[ -k $d ]] && echo y) $(tail -2 "$T/prov.out")"; fi
  (umask 077; mkdir "$d/inbox"; echo x >"$d/inbox/m")
  [[ "$(stat -c %a "$d/inbox/m")" == 660 ]] && pass "a file made later under umask 077 is still group-rw, other nothing (default ACL)" \
    || fail "default ACL not inherited: $(stat -c %a "$d/inbox/m")"
  sudo -n rm -rf "$d"
else
  skip "no passwordless sudo / setfacl"
fi

# --- 6. lde switches ------------------------------------------------------------------
hv() { sed -n "s/^$1=//p" "$H"; }
SNIPPET='do_gen_docker_env' in_orc >"$T/sw0.out" 2>&1 || fail "default render: $(tail -2 "$T/sw0.out")"
[[ "$(hv SPOOL_HUB_AUTH_NATIVE_ENABLED)|$(hv SPOOL_HUB_AUTH_PROVIDERS)|$(hv SPOOL_HUB_WUI_DISPATCH)|$(hv SPOOL_HUB_WUI_KEY_EPHEMERAL)" == "false||false|false" ]] \
  && pass "default: native off, no provider, dispatch off" || fail "default switches: $(grep -E 'NATIVE_ENABLED|PROVIDERS|WUI_' "$H" | tr '\n' ' ')"
grep -q '^SPOOL_HUB_AUTH_SESSION_KEY=' "$H" && fail "a session key is rendered with every auth switch off" || pass "default: no session key"
grep -q PLACEHOLDER "$H" && fail "hub.env carries a PLACEHOLDER: $(grep PLACEHOLDER "$H" | cut -d= -f1 | tr '\n' ' ')" || pass "no PLACEHOLDER value reaches the lde hub"
[[ "$(hv SPOOL_HUB_MAIL_TRANSPORT)" == log ]] && pass "lde mail transport is log" || fail "mail transport '$(hv SPOOL_HUB_MAIL_TRANSPORT)'"

SNIPPET='do_gen_docker_env' in_orc LDE_AUTH_NATIVE=1 LDE_WUI_DISPATCH=true LDE_WUI_PORT=3999 LDE_HUB_PORT=58999 >"$T/sw1.out" 2>&1 || fail "switched render: $(tail -2 "$T/sw1.out")"
[[ "$(hv SPOOL_HUB_AUTH_NATIVE_ENABLED)|$(hv SPOOL_HUB_WUI_DISPATCH)|$(hv SPOOL_HUB_WUI_KEY_EPHEMERAL)" == "true|true|true" ]] \
  && pass "LDE_AUTH_NATIVE=1 LDE_WUI_DISPATCH=true: native on, dispatch on, ephemeral key" || fail "switched: $(grep -E 'NATIVE_ENABLED|WUI_' "$H" | tr '\n' ' ')"
key=$(hv SPOOL_HUB_AUTH_SESSION_KEY)
[[ "$key" =~ ^[0-9a-f]{64}$ ]] && pass "session key: 32 random bytes, hex" || fail "session key shape (${#key} chars)"
[[ "$(stat -c %a "$T/state/auth-session.key" 2>/dev/null)" == 600 ]] && pass "auth-session.key is 0600" || fail "auth-session.key mode $(stat -c %a "$T/state/auth-session.key" 2>&1)"
grep -qF "$key" "$T/sw1.out" && fail "the session key is in the render log" || pass "the session key is never logged"
SNIPPET='do_gen_docker_env' in_orc LDE_AUTH_NATIVE=1 >/dev/null 2>&1
[[ "$(hv SPOOL_HUB_AUTH_SESSION_KEY)" == "$key" ]] && pass "session key is stable across renders (sessions survive a restart)" || fail "session key changed on re-render"
SNIPPET='do_gen_docker_env' in_orc LDE_AUTH_NATIVE=1 LDE_WUI_PORT=3999 >/dev/null 2>&1
[[ "$(hv SPOOL_HUB_AUTH_APP_URL)" == http://localhost:3999 && "$(hv SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI)" == http://localhost:3999/api/v1/auth/google/callback ]] \
  && pass "APP_URL + redirect URIs follow LDE_WUI_PORT (the WUI origin, not the hub port)" \
  || fail "auth URLs: $(hv SPOOL_HUB_AUTH_APP_URL) $(hv SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI)"
grep -q '{lde_' "$H" && fail "an unfilled {lde_*} token: $(grep '{lde_' "$H" | cut -d= -f1)" || pass "every {lde_*} port token is filled"

SNIPPET='do_gen_docker_env' in_orc LDE_AUTH_PROVIDERS=google >"$T/sw2.out" 2>&1 \
  && fail "LDE_AUTH_PROVIDERS=google without client creds rendered" || { grep -q 'SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET' "$T/sw2.out" \
  && pass "a provider without caller creds fails fast, naming the var" || fail "provider fail message: $(tail -1 "$T/sw2.out")"; }
SNIPPET='do_gen_docker_env' in_orc LDE_AUTH_PROVIDERS=google SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID=lde-test-id \
  SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET=lde-test-secret SPOOL_HUB_AUTH_IDP_BASE_URL=http://127.0.0.1:5999 >"$T/sw3.out" 2>&1 || fail "social render: $(tail -1 "$T/sw3.out")"
[[ "$(hv SPOOL_HUB_AUTH_PROVIDERS)|$(hv SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID)|$(hv SPOOL_HUB_AUTH_IDP_BASE_URL)" == "google|lde-test-id|http://127.0.0.1:5999" ]] \
  && pass "LDE_AUTH_PROVIDERS=google renders the provider, caller creds and fake IdP" || fail "social: $(grep -E 'PROVIDERS|GOOGLE_CLIENT_ID|IDP' "$H" | tr '\n' ' ')"
SNIPPET='do_gen_docker_env' in_orc LDE_AUTH_NATIVE=maybe >"$T/sw4.out" 2>&1 && fail "LDE_AUTH_NATIVE=maybe was accepted" || pass "a typo'd switch fails instead of reading as off"

# --- 7. do_spl_pin_box_wui (stubbed hub, CLI, pg) ----------------------------------------
mkdir -p "$T/state/hello" "$T/state/bin"; echo root-key-stub >"$T/state/hello/root.key"
PUB="AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
printf '#!/bin/sh\necho "$@" >"%s/pin.args"\necho ok\n' "$T" >"$T/state/bin/spool"; chmod +x "$T/state/bin/spool"
PIN_STUB='curl() { printf "%s\n%s" "$STUB_BODY" "$STUB_CODE"; }; lde_compose() { echo "$STUB_ROW"; }; do_spl_pin_box_wui'
SNIPPET="$PIN_STUB" in_orc STUB_CODE=404 STUB_BODY='{"error":"not_found"}' STUB_ROW= >"$T/pin1.out" 2>&1 \
  && fail "a 404 pubkey pinned" || { grep -q 'LDE_WUI_DISPATCH=1' "$T/pin1.out" && pass "404 /v1/wui/pubkey fails and names LDE_WUI_DISPATCH=1" || fail "404 message: $(tail -1 "$T/pin1.out")"; }
SNIPPET="$PIN_STUB" in_orc STUB_CODE=200 STUB_BODY="{\"box_id\":\"box-wui\",\"pubkey\":\"$PUB\",\"dispatch\":true}" STUB_ROW="$PUB" >"$T/pin2.out" 2>&1 \
  && grep -q '"pinned":true' "$T/pin2.out" && pass "200: box-wui pinned, pins row proven" || fail "pin: $(tail -2 "$T/pin2.out")"
[[ "$(cat "$T/pin.args" 2>/dev/null)" == "hub-pin --box box-wui --pubkey $PUB --root-key $T/state/hello/root.key --force" ]] \
  && pass "hub-pin --box box-wui --force with the smoke tenant root key" || fail "hub-pin args: $(cat "$T/pin.args" 2>&1)"
SNIPPET="$PIN_STUB" in_orc STUB_CODE=200 STUB_BODY="{\"pubkey\":\"$PUB\",\"dispatch\":true}" STUB_ROW=other >"$T/pin3.out" 2>&1 \
  && fail "control: a pins row holding another key passed" || pass "control: a pins row holding another key fails"
SNIPPET="$PIN_STUB" in_orc TENANT_ID=acme STUB_CODE=200 >"$T/pin4.out" 2>&1 \
  && fail "another tenant pinned with the smoke root key" || pass "another tenant needs ROOT_KEY"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
