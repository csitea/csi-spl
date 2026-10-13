#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local hub's production WUI overlay
#          (src/docker/docker-compose-local-hub.yaml + src/docker/local-hub/):
#          the GENERATED bundle behind a same-origin proxy, never the Nuxt dev
#          server.
#   1. compose accepts the four lde files + the overlay; wui-generate is a
#      profile-gated one-shot (absent from the default model, present under
#      --profile local-hub-build)
#   2. wui-generate: runs as 0:0 (rootless: container root = the stack's
#      own user, the one uid that may write the mounted tree), the mock off,
#      the {tenant} API base and LDE_WUI_TENANT baked, writes the named volume
#      wui-dist, publishes no port, never restarts
#   3. wui-static: non-root, read-only rootfs, every capability dropped but
#      NET_BIND_SERVICE (caddy's file capability: without it exec fails),
#      no-new-privileges, wui-dist mounted read-only, the tree NOT mounted
#      (only the Caddyfile, read-only), on 127.0.0.1:LDE_WUI_PORT only, on
#      the lde network, restart unless-stopped, a healthcheck; config.json
#      apiBase "" (same origin) and tenant LDE_WUI_TENANT
#   4. the overlay sets no hub environment (cnf env.lde.local_hub.hub.env is
#      the one home) and leaves the lde dev `wui` service as it was
#   5. every published port of the merged model binds 127.0.0.1
#   6. the Caddyfile: admin off, every hub path (/v1/*, /api/*, /healthz,
#      /version) proxied to hub, /config.json answered from the env, the SPA
#      fallback /200.html, a CSP with connect-src 'self'; `caddy validate`
#      when the image is already local (never pulled)
#   7. wui-generate.sh (stubbed npm/npx): the bundle replaces the old dist
#      (no stale file left), files world-readable; a failed generate or a
#      generate with no index leaves the old dist untouched (controls);
#      no node_modules = one frozen install, present = none
#   Steps 1-5 SKIP without docker compose. No container is started.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
D="$PROJ_ROOT/src/docker"
OVERLAY="$D/docker-compose-local-hub.yaml"
CADDY="$D/local-hub/Caddyfile"
GEN="$D/local-hub/wui-generate.sh"
TENANT=throwaway-l2

for f in "$OVERLAY" "$CADDY" "$GEN"; do
  [[ -f "$f" ]] && pass "exists: ${f#"$PROJ_ROOT"/}" || fail "missing: ${f#"$PROJ_ROOT"/}"
done

# --- 1..5. the merged compose model ------------------------------------------------
lh_compose() {
  docker compose -p lh-test --env-file "$T/state/compose.env" -f "$D/docker-compose-infra.yaml" \
    -f "$D/docker-compose-rdb.yaml" -f "$D/docker-compose-api.yaml" -f "$D/docker-compose-wui.yaml" \
    -f "$OVERLAY" "$@"
}
env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" LDE_STATE_DIR="$T/state" bash -c '
  set -uo pipefail
  do_log() { echo "$*"; }
  for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
  do_gen_docker_env' >"$T/gen.out" 2>&1 || fail "do_gen_docker_env: $(tail -3 "$T/gen.out")"
# compose.env carries LDE_WUI_TENANT (the lead's do_gen_docker_env); pin a
# throwaway value either way
if [[ -f "$T/state/compose.env" ]]; then
  grep -v '^LDE_WUI_TENANT=' "$T/state/compose.env" >"$T/compose.env.tmp"
  echo "LDE_WUI_TENANT=$TENANT" >>"$T/compose.env.tmp"
  mv "$T/compose.env.tmp" "$T/state/compose.env"
fi
WPORT=$(sed -n 's/^LDE_WUI_PORT=//p' "$T/state/compose.env" 2>/dev/null)

if docker compose version >/dev/null 2>&1 && [[ -f "$T/state/compose.env" && -f "$OVERLAY" ]]; then
  if lh_compose config --format json >"$T/def.json" 2>"$T/def.err" \
     && lh_compose --profile local-hub-build config --format json >"$T/cfg.json" 2>"$T/cfg.err"; then
    pass "1. compose accepts the 4 lde files + the overlay"
    q() { yq -p json -oy -r "$1" "$T/cfg.json"; }
    [[ "$(yq -p json -oy -r '.services | has("wui-generate")' "$T/def.json")" == false && "$(q '.services | has("wui-generate")')" == true ]] \
      && pass "1. wui-generate is gated by the local-hub-build profile" || fail "1. wui-generate is not profile-gated"
    [[ "$(yq -p json -oy -r '.services | has("wui-static")' "$T/def.json")" == true ]] \
      && pass "1. wui-static is in the default model" || fail "1. wui-static missing from the default model"

    # 2. wui-generate
    G='.services["wui-generate"]'
    [[ "$(q "$G.user")" == 0:0 ]] && pass "2. wui-generate runs as 0:0" || fail "2. wui-generate user '$(q "$G.user")'"
    [[ "$(q "$G.environment.NUXT_PUBLIC_USE_MOCK")" == 0 ]] && pass "2. mock off" || fail "2. NUXT_PUBLIC_USE_MOCK is not 0"
    base=$(q "$G.environment.NUXT_PUBLIC_API_BASE")
    [[ "$base" =~ ^http://\{tenant\}\.localhost:[0-9]+$ ]] && pass "2. baked API base $base" || fail "2. API base '$base'"
    [[ "$(q "$G.environment.NUXT_PUBLIC_TENANT")" == "$TENANT" ]] && pass "2. tenant = LDE_WUI_TENANT" || fail "2. tenant '$(q "$G.environment.NUXT_PUBLIC_TENANT")'"
    [[ "$(q "[$G.volumes[] | select(.type == \"volume\" and .source == \"wui-dist\")] | length")" == 1 ]] \
      && pass "2. writes the named volume wui-dist" || fail "2. no wui-dist volume on wui-generate"
    [[ "$(q "$G.volumes[] | select(.target == \"/app\") | .source")" == "$APP_ROOT/csi-spl-wui" ]] \
      && pass "2. builds the tree's csi-spl-wui" || fail "2. /app is not the tree's csi-spl-wui"
    [[ "$(q "$G.ports // [] | length")" == 0 ]] && pass "2. publishes no port" || fail "2. wui-generate publishes a port"
    [[ "$(q "$G.restart // \"no\"")" == no ]] && pass "2. one-shot (restart no)" || fail "2. wui-generate restarts"

    # 3. wui-static
    S='.services["wui-static"]'
    u=$(q "$S.user")
    [[ "$u" =~ ^[0-9]+:[0-9]+$ && "${u%%:*}" != 0 ]] && pass "3. wui-static runs non-root ($u)" || fail "3. wui-static user '$u'"
    [[ "$(q "$S.read_only")" == true ]] && pass "3. read-only rootfs" || fail "3. rootfs writable"
    [[ "$(q "$S.cap_drop | join(\",\")")" == ALL && "$(q "$S.cap_add // [] | join(\",\")")" == NET_BIND_SERVICE ]] \
      && pass "3. every capability dropped but NET_BIND_SERVICE (the binary's file cap)" || fail "3. cap_drop '$(q "$S.cap_drop")' cap_add '$(q "$S.cap_add")'"
    grep -x 'no-new-privileges:true' <<<"$(q "$S.security_opt[]")" >/dev/null && pass "3. no-new-privileges" || fail "3. no no-new-privileges"
    [[ "$(q "$S.volumes[] | select(.source == \"wui-dist\") | .read_only")" == true ]] \
      && pass "3. serves wui-dist read-only" || fail "3. wui-dist not mounted read-only"
    binds=$(q "[$S.volumes[] | select(.type == \"bind\")] | map(.source + \"|\" + (.read_only|tostring)) | join(\" \")")
    [[ "$binds" == "$CADDY|true" ]] && pass "3. the only bind is the Caddyfile, read-only" || fail "3. binds: '$binds'"
    p=$(q "[$S.ports[] | .host_ip + \"|\" + .published] | join(\" \")")
    [[ -n "$WPORT" && "$p" == "127.0.0.1|$WPORT" ]] && pass "3. published on 127.0.0.1:$WPORT only" || fail "3. ports '$p'"
    [[ "$(q "$S.networks | keys | join(\",\")")" == lde ]] && pass "3. on the lde network" || fail "3. networks"
    [[ "$(q "$S.restart")" == unless-stopped ]] && pass "3. restart unless-stopped" || fail "3. restart '$(q "$S.restart")'"
    [[ -n "$(q "$S.healthcheck.test // \"\"")" ]] && pass "3. has a healthcheck" || fail "3. no healthcheck"
    [[ "$(q "$S.environment | has(\"LOCAL_HUB_WUI_API_BASE\")")" == true && "$(q "$S.environment.LOCAL_HUB_WUI_API_BASE")" == "" ]] \
      && pass "3. config.json apiBase defaults to \"\" (same origin)" || fail "3. LOCAL_HUB_WUI_API_BASE '$(q "$S.environment.LOCAL_HUB_WUI_API_BASE")'"
    [[ "$(q "$S.environment.LOCAL_HUB_WUI_TENANT")" == "$TENANT" ]] && pass "3. config.json tenant = LDE_WUI_TENANT" || fail "3. tenant"

    # 4. no hub env; lde wui untouched
    yq -e '.services.hub' "$OVERLAY" >/dev/null 2>&1 && fail "4. the overlay touches the hub service" || pass "4. the overlay sets nothing on hub"
    yq -e '.services.wui' "$OVERLAY" >/dev/null 2>&1 && fail "4. the overlay touches the lde wui service" || pass "4. the lde wui service is left as it is"

    # 5. loopback only
    ips=$(q '[.services[].ports[]?.host_ip] | unique | join(",")')
    [[ "$ips" == 127.0.0.1 ]] && pass "5. every published port binds 127.0.0.1" || fail "5. host_ip: $ips"
  else
    fail "1. compose config: $(cat "$T/def.err" "$T/cfg.err" 2>/dev/null | sed -n 1,3p | tr '\n' ' ')"
  fi
else
  skip "1-5. no docker compose (or no overlay)"
fi

# --- 6. the Caddyfile ----------------------------------------------------------------
if [[ -f "$CADDY" ]]; then
  c=$(grep -v '^[[:space:]]*#' "$CADDY")
  grep -qE '^[[:space:]]*admin off' <<<"$c" && pass "6. admin API off" || fail "6. admin API not off"
  m=$(grep -E '^[[:space:]]*@hub path' <<<"$c")
  for p in '/v1/*' '/api/*' '/healthz' '/version'; do
    [[ "$m " == *" $p "* ]] && pass "6. proxies $p to the hub" || fail "6. $p not proxied"
  done
  grep -qE 'reverse_proxy \{\$LOCAL_HUB_UPSTREAM\}' <<<"$c" && pass "6. upstream from LOCAL_HUB_UPSTREAM" || fail "6. upstream"
  grep -qF '"apiBase":"{$LOCAL_HUB_WUI_API_BASE}"' <<<"$c" && grep -qF '"authBase":""' <<<"$c" \
    && grep -qF '"tenant":"{$LOCAL_HUB_WUI_TENANT}"' <<<"$c" \
    && pass "6. /config.json from the env" || fail "6. /config.json body"
  grep -qF 'try_files {path} {path}.html {path}/index.html /200.html' <<<"$c" && pass "6. SPA fallback /200.html" || fail "6. SPA fallback"
  grep -qF "connect-src 'self'" <<<"$c" && pass "6. CSP connect-src 'self'" || fail "6. CSP"
  img=$(yq -r '.services["wui-static"].image' "$OVERLAY" 2>/dev/null | sed -E 's/^\$\{[A-Z_]+:-(.*)\}$/\1/')
  if [[ -n "$img" && "$img" != null ]] && docker image inspect "$img" >/dev/null 2>&1; then
    docker run --rm -v "$CADDY:/etc/caddy/Caddyfile:ro" -e LOCAL_HUB_UPSTREAM=hub:8080 -e LOCAL_HUB_WUI_TENANT=$TENANT \
      -e LOCAL_HUB_WUI_API_BASE= "$img" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$T/val.out" 2>&1 \
      && pass "6. caddy validate ($img)" || fail "6. caddy validate: $(tail -2 "$T/val.out")"
  else
    skip "6. caddy validate (image '$img' not local; the test never pulls)"
  fi
fi

# --- 7. wui-generate.sh -----------------------------------------------------------
if [[ -f "$GEN" ]]; then
  W="$T/wui" DIST="$T/dist"
  mkdir -p "$W/node_modules" "$DIST/sub" "$T/bin"
  echo '{ "name": "x", "packageManager": "pnpm@9.15.4" }' >"$W/package.json"
  echo old >"$DIST/stale.html"; echo old >"$DIST/sub/old.js"; echo old >"$DIST/.hidden"
  # stub npm: `npm run generate` writes .output/public (GEN_MODE ok | fail | empty)
  cat >"$T/bin/npm" <<'EOF'
#!/bin/sh
echo "npm $*" >>"$STUB_LOG"
[ "$GEN_MODE" = fail ] && exit 1
rm -rf .output; mkdir -p .output/public/_nuxt
[ "$GEN_MODE" = empty ] && exit 0
echo new >.output/public/index.html; echo new >.output/public/200.html; echo js >.output/public/_nuxt/a.js
chmod 600 .output/public/index.html; chmod 700 .output/public/_nuxt
EOF
  printf '#!/bin/sh\necho "npx $*" >>"$STUB_LOG"\nmkdir -p node_modules\n' >"$T/bin/npx"
  chmod +x "$T/bin/npm" "$T/bin/npx"
  run_gen() { env PATH="$T/bin:$PATH" STUB_LOG="$T/calls.log" WUI_DIR="$W" WUI_DIST="$DIST" "$@" sh "$GEN" >"$T/gen7.out" 2>&1; }

  run_gen GEN_MODE=fail && fail "7. a failed generate exits 0" || pass "7. a failed generate exits non-zero"
  [[ -f "$DIST/stale.html" ]] && pass "7. control: a failed generate leaves the old dist" || fail "7. a failed generate wiped the dist"
  run_gen GEN_MODE=empty && fail "7. a generate with no index exits 0" || pass "7. a generate with no index.html exits non-zero"
  [[ -f "$DIST/stale.html" ]] && pass "7. control: no index leaves the old dist" || fail "7. no index wiped the dist"
  : >"$T/calls.log"
  if run_gen GEN_MODE=ok; then pass "7. generate ok"; else fail "7. generate: $(tail -3 "$T/gen7.out")"; fi
  [[ -f "$DIST/index.html" && -f "$DIST/_nuxt/a.js" ]] && pass "7. the bundle is in the dist" || fail "7. bundle missing from dist"
  [[ ! -e "$DIST/stale.html" && ! -e "$DIST/sub" && ! -e "$DIST/.hidden" ]] && pass "7. no stale file left" || fail "7. stale files: $(ls -A "$DIST" | tr '\n' ' ')"
  [[ "$(stat -c %a "$DIST/index.html" 2>/dev/null)" == 644 && "$(stat -c %a "$DIST/_nuxt" 2>/dev/null)" == 755 ]] \
    && pass "7. world-readable (the non-root server reads it)" || fail "7. modes $(stat -c %a "$DIST/index.html" "$DIST/_nuxt" 2>&1 | xargs)"
  grep -q '^npx ' "$T/calls.log" && fail "7. installed with node_modules present" || pass "7. node_modules present: no install"
  rm -rf "$W/node_modules"; : >"$T/calls.log"
  run_gen GEN_MODE=ok || fail "7. generate after install: $(tail -3 "$T/gen7.out")"
  [[ "$(grep -c '^npx --yes pnpm@9.15.4 install --frozen-lockfile' "$T/calls.log")" == 1 ]] && pass "7. no node_modules: one frozen install" || fail "7. install calls: $(cat "$T/calls.log")"
fi

echo "local-hub-compose: $fails failure(s)"
[[ "$fails" == 0 ]]
