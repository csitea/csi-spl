# The WUI for the standalone stack (the root docker-compose.yml): `nuxt
# generate` in a node stage, then Caddy serves the static bundle AND reverse
# proxies the hub on the same origin (src/docker/Caddyfile), so the browser
# needs no CORS and no second host. Build context: csi-spl-wui.
#
# The public URL is baked into the bundle at build time (Nuxt public runtime
# config of a static generate), so a change of SPOOL_PUBLIC_URL needs
# `docker compose up --build`.
FROM node:20-alpine AS build
WORKDIR /app
ENV NUXT_TELEMETRY_DISABLED=1 CI=1
RUN corepack enable
COPY package.json pnpm-lock.yaml .npmrc ./
# postinstall runs `nuxt prepare`, which needs the config and the sources
COPY nuxt.config.ts tsconfig.json .version ./
COPY i18n/ ./i18n/
COPY src/ ./src/
RUN pnpm install --frozen-lockfile
ARG SPOOL_PUBLIC_URL=http://localhost:8080
ARG SPOOL_TENANT=main
ARG SPOOL_LOBBY_TASK_ID=00000000-0000-4000-8000-000000000001
ARG SPOOL_DEFAULT_LOCALE=en
# The hub is the same origin as the page: reads, the live socket and
# /api/v1/auth/** all go to SPOOL_PUBLIC_URL, which Caddy routes to the hub.
RUN NUXT_PUBLIC_API_BASE="$SPOOL_PUBLIC_URL" \
    NUXT_PUBLIC_AUTH_BASE="" \
    NUXT_PUBLIC_TENANT="$SPOOL_TENANT" \
    NUXT_PUBLIC_LOBBY_TASK_ID="$SPOOL_LOBBY_TASK_ID" \
    NUXT_PUBLIC_DEFAULT_LOCALE="$SPOOL_DEFAULT_LOCALE" \
    NUXT_PUBLIC_USE_MOCK=0 \
    pnpm run generate

FROM caddy:2-alpine
COPY src/docker/Caddyfile /etc/caddy/Caddyfile
COPY --from=build /app/.output/public/ /srv/
