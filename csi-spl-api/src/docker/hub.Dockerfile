# The spool hub for the standalone stack (the root docker-compose.yml): builds
# the `spool` binary from source and bundles the csi-spl-rdb DDL, so a clean
# machine needs nothing but docker. Build contexts (compose sets both):
#   .    csi-spl-api            the Go module under src/go/spool-hub-api
#   rdb  csi-spl-rdb            src/sql/postgres/{spool-hub,spool-hub-roles}
# Alpine, not distroless: the entrypoint is a shell script (init runs `spool
# migrate`, the runtime-role SQL through psql, and seeds the first tenant).
FROM golang:1.25-alpine AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
WORKDIR /src
COPY src/go/spool-hub-api/go.mod src/go/spool-hub-api/go.sum ./
RUN go mod download
COPY src/go/spool-hub-api/ ./
RUN go build -trimpath -ldflags "-s -w" -o /out/spool ./cmd/spool

FROM alpine:3.22
RUN apk add --no-cache postgresql16-client ca-certificates tzdata \
 && addgroup -S -g 10001 spool && adduser -S -D -H -u 10001 -G spool spool \
 && mkdir -p /var/lib/spool/files /var/lib/spool/state \
 && chown -R spool:spool /var/lib/spool
COPY --from=build /out/spool /usr/local/bin/spool
COPY --from=rdb src/sql/postgres/spool-hub/ /opt/spool/sql/postgres/spool-hub/
COPY --from=rdb src/sql/postgres/spool-hub-roles/ /opt/spool/sql/postgres/spool-hub-roles/
COPY src/docker/hub-entrypoint.sh /usr/local/bin/hub-entrypoint.sh
ENV SPOOL_HUB_MIGRATIONS_DIR=/opt/spool/sql/postgres/spool-hub \
    SPOOL_HUB_FILES_DIR=/var/lib/spool/files \
    SPOOL_STATE_DIR=/var/lib/spool/state
USER spool
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/usr/local/bin/hub-entrypoint.sh"]
CMD ["serve"]
