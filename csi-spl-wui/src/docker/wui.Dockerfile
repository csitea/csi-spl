# The WUI for the standalone stack (the root docker-compose.yml): `nuxt
# generate` in a node stage, then Caddy serves the static bundle AND reverse
# proxies the hub on the same origin (src/docker/Caddyfile), so the browser
# needs no CORS and no second host. Build context: the repo root, narrowed by
# wui.Dockerfile.dockerignore to csi-spl-wui, .version and .git.
#
# The footer version (specs/047 W6): SPOOL_VERSION when given, else `git
# describe --tags` of the checkout, else the root .version floor with -dev.
#
# Spec 072 A3: the bundle carries no env values. At container start
# wui-config.sh writes /srv/config.json from SPOOL_PUBLIC_URL, SPOOL_TENANT,
# SPOOL_LOBBY_TASK_ID and SPOOL_ENV_NAME, and the page reads it at boot, so a
# domain or tenant change is a restart, not a rebuild. The build args below
# are only the defaults of those env values; SPOOL_DEFAULT_LOCALE stays a
# build value because it decides which routes carry a locale prefix.
FROM node:20-alpine AS build
WORKDIR /app
ENV NUXT_TELEMETRY_DISABLED=1 CI=1
RUN corepack enable
COPY csi-spl-wui/package.json csi-spl-wui/pnpm-lock.yaml csi-spl-wui/.npmrc ./
# postinstall runs `nuxt prepare`, which needs the config and the sources
COPY csi-spl-wui/nuxt.config.ts csi-spl-wui/tsconfig.json csi-spl-wui/.version ./
COPY csi-spl-wui/i18n/ ./i18n/
COPY csi-spl-wui/src/ ./src/
RUN pnpm install --frozen-lockfile
RUN apk add --no-cache git
COPY .version .gi[t] /meta/
ARG SPOOL_VERSION=
RUN set -eu; v="$SPOOL_VERSION"; \
    [ -n "$v" ] || v="$(git -c safe.directory='*' --git-dir=/meta describe --tags --match 'v[0-9]*' 2>/dev/null)" || true; \
    [ -n "$v" ] || v="$(tr -d ' \n' </meta/.version)-dev"; \
    printf 'v%s' "${v#v}" >/meta/version.txt; echo "WUI version $(cat /meta/version.txt)"
ARG SPOOL_DEFAULT_LOCALE=en
# No NUXT_PUBLIC_API_BASE / TENANT / LOBBY: one bundle for every origin.
RUN NUXT_PUBLIC_APP_VERSION="$(cat /meta/version.txt)" \
    NUXT_PUBLIC_DEFAULT_LOCALE="$SPOOL_DEFAULT_LOCALE" \
    NUXT_PUBLIC_USE_MOCK=0 \
    pnpm run generate

FROM caddy:2-alpine
COPY csi-spl-wui/src/docker/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/.output/public/ /srv/
COPY --chmod=0755 csi-spl-wui/src/docker/wui-config.sh /usr/local/bin/wui-config.sh
# defaults of the runtime values (the compose file may still pass them as
# build args); the container's env overrides each at start
ARG SPOOL_TENANT=main
ARG SPOOL_LOBBY_TASK_ID=00000000-0000-4000-8000-000000000001
ENV SPOOL_TENANT=$SPOOL_TENANT SPOOL_LOBBY_TASK_ID=$SPOOL_LOBBY_TASK_ID
ENTRYPOINT ["/usr/local/bin/wui-config.sh"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
