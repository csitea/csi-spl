# csi-spl local hub ::: the backup job's image (lane L4): the SAME postgres
# image as the pg service (pg_dump/pg_restore of its major) plus age. Built by
# compose from docker-compose-local-hub-backup.yaml; nothing on the host.
# /backups is 0750 group postgres: a restore runs as the host user (who alone
# reads the owner's identity) in that group.
ARG PG_IMAGE
FROM ${PG_IMAGE}
RUN apk add --no-cache age \
 && install -d -o postgres -g postgres -m 0750 /backups
COPY --chmod=0755 backup.sh /usr/local/bin/backup.sh
USER postgres
ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["loop"]
