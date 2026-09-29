# The spool hub for the standalone stack (the root docker-compose.yml): builds
# the `spool` binary from source and bundles the csi-spl-rdb DDL, so a clean
# machine needs nothing but docker. Build context: the repo root, narrowed by
# hub.Dockerfile.dockerignore to the Go module, the DDL, .version and .git.
# Alpine, not distroless: the entrypoint is a shell script (init runs `spool
# migrate`, the runtime-role SQL through psql, and seeds the first tenant).
#
# The version (specs/047 W6): SPOOL_VERSION when given, else `git describe
# --tags` of the checkout (v1.9.7 on a tagged commit, v1.9.7-3-g<sha> after
# it), else the .version floor with -dev. GET /version and `spool version`
# report it without the leading v, like the hosted hub.
FROM golang:1.25-alpine AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
WORKDIR /src
COPY csi-spl-api/src/go/spool-hub-api/go.mod csi-spl-api/src/go/spool-hub-api/go.sum ./
RUN go mod download
RUN apk add --no-cache git
# .gi[t]: a download without .git (a zip, a worktree whose .git is a file)
# still builds, on the .version floor
COPY .version .gi[t] /meta/
ARG SPOOL_VERSION=
RUN set -eu; g() { git -c safe.directory='*' --git-dir=/meta "$@" 2>/dev/null; }; \
    v="$SPOOL_VERSION"; [ -n "$v" ] || v="$(g describe --tags --match 'v[0-9]*')" || true; \
    [ -n "$v" ] || v="$(tr -d ' \n' </meta/.version)-dev"; \
    printf '%s' "${v#v}" >/meta/version.txt; \
    printf '%s' "$(g rev-parse HEAD || echo unknown)" >/meta/commit.txt; \
    echo "spool version $(cat /meta/version.txt) commit $(cat /meta/commit.txt)"
COPY csi-spl-api/src/go/spool-hub-api/ ./
RUN go build -trimpath -ldflags "-s -w -X main.version=$(cat /meta/version.txt) -X main.commit=$(cat /meta/commit.txt) -X main.builtAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)" -o /out/spool ./cmd/spool

FROM alpine:3.22
RUN apk add --no-cache postgresql16-client ca-certificates tzdata \
 && addgroup -S -g 10001 spool && adduser -S -D -H -u 10001 -G spool spool \
 && mkdir -p /var/lib/spool/files /var/lib/spool/state \
 && chown -R spool:spool /var/lib/spool
COPY --from=build /out/spool /usr/local/bin/spool
COPY csi-spl-rdb/src/sql/postgres/spool-hub/ /opt/spool/sql/postgres/spool-hub/
COPY csi-spl-rdb/src/sql/postgres/spool-hub-roles/ /opt/spool/sql/postgres/spool-hub-roles/
COPY csi-spl-api/src/docker/hub-entrypoint.sh /usr/local/bin/hub-entrypoint.sh
ENV SPOOL_HUB_MIGRATIONS_DIR=/opt/spool/sql/postgres/spool-hub \
    SPOOL_HUB_FILES_DIR=/var/lib/spool/files \
    SPOOL_STATE_DIR=/var/lib/spool/state
USER spool
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/usr/local/bin/hub-entrypoint.sh"]
CMD ["serve"]
