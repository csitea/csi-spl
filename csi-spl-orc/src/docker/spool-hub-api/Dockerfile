# The spool hub image: the static `spool` binary + the csi-spl-rdb hub DDL.
# do_setup_app_inf stages the build context (it builds the binary with
# CGO_ENABLED=0 from csi-spl-api; no toolchain or module download in here):
#   <ctx>/spool   <ctx>/sql/   <ctx>/Dockerfile
# MIGRATIONS_DIR is cnf env.hub.env.SPOOL_HUB_MIGRATIONS_DIR, where
# `spool migrate` looks by default.
FROM gcr.io/distroless/static-debian12:nonroot
ARG MIGRATIONS_DIR=/opt/spool/sql/postgres/spool-hub
COPY spool /usr/local/bin/spool
COPY sql/ ${MIGRATIONS_DIR}/
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/usr/local/bin/spool"]
CMD ["serve"]
