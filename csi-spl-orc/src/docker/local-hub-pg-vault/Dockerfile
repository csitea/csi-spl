# csi-spl local hub ::: the lde Postgres image plus gocryptfs (lane L5): the
# pg-data volume holds ciphertext only, see vault-entrypoint.sh. Built by
# `lde_compose build` from docker-compose-local-hub-vault.yaml, which passes
# the cnf image (env.lde.pg.image) as LDE_PG_IMAGE.
ARG LDE_PG_IMAGE
# hadolint ignore=DL3006
FROM ${LDE_PG_IMAGE}
# hadolint ignore=DL3018,DL3008
RUN if command -v apk >/dev/null; then apk add --no-cache gocryptfs fuse3; \
    else apt-get update && apt-get install -y --no-install-recommends gocryptfs fuse3 && rm -rf /var/lib/apt/lists/*; fi
COPY vault-entrypoint.sh /usr/local/bin/vault-entrypoint.sh
COPY vault-unlock.sh /usr/local/bin/vault-unlock
RUN chmod 0755 /usr/local/bin/vault-entrypoint.sh /usr/local/bin/vault-unlock
ENTRYPOINT ["/usr/local/bin/vault-entrypoint.sh"]
CMD ["postgres"]
