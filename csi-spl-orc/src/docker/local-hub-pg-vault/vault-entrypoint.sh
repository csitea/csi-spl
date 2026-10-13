#!/bin/sh
# csi-spl local hub ::: the pg vault entrypoint (local hub swarm, lane L5).
# The pg-data volume holds gocryptfs CIPHERTEXT only. Postgres runs on the
# decrypted view, a FUSE mount that exists only inside this container and
# only after the owner typed the passphrase on the terminal
# (do_spl_local_hub_unlock -> `docker exec -i <pg> vault-unlock`). Nothing
# here stores, logs or passes the passphrase in argv or env: gocryptfs reads
# it from a 0600 FIFO on a tmpfs, the FIFO holds nothing once read.
#
# States in $VAULT_RUN/state: needs-init (empty volume), locked <n> (the
# n-th wait for the passphrase), wrong <n>, unlocked. A restart starts
# locked again: the tmpfs and the FUSE mount die with the container.
set -u
CIPHER="${VAULT_CIPHER_DIR:-/var/lib/postgresql/data}"
PLAIN="${VAULT_PLAIN_DIR:-/run/pgplain}"
VAULT_RUN="${VAULT_RUN:-/run/vault}"
STATE="$VAULT_RUN/state"
FIFO="$VAULT_RUN/pass"
umask 077
mkdir -p "$VAULT_RUN" "$PLAIN"
state() { echo "$1" >"$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"; }

# a volume with data but no gocryptfs.conf is a plaintext pg-data: refuse it
if [ ! -f "$CIPHER/gocryptfs.conf" ] && [ -n "$(ls -A "$CIPHER" 2>/dev/null)" ]; then
  echo "vault: $CIPHER holds data but no gocryptfs.conf (a plaintext volume?): refusing" >&2
  exit 1
fi
rm -f "$FIFO"; mkfifo -m 0600 "$FIFO" || exit 1

n=0
while :; do
  if [ ! -f "$CIPHER/gocryptfs.conf" ]; then
    state needs-init
    echo "vault: new volume, waiting for a passphrase (do_spl_local_hub_unlock)"
    gocryptfs -q -init -passfile "$FIFO" "$CIPHER" >/dev/null 2>&1 || { echo "vault: init failed" >&2; sleep 1; continue; }
  fi
  n=$((n + 1))
  state "locked $n"
  echo "vault: locked, waiting for the passphrase (do_spl_local_hub_unlock)"
  gocryptfs -fg -q -nosyslog -allow_other -passfile "$FIFO" "$CIPHER" "$PLAIN" &
  gpid=$!
  while kill -0 "$gpid" 2>/dev/null && ! mountpoint -q "$PLAIN"; do sleep 0.2; done
  mountpoint -q "$PLAIN" && break
  wait "$gpid" 2>/dev/null
  state "wrong $n"
  echo "vault: wrong passphrase" >&2
  sleep 2
done
state unlocked
echo "vault: unlocked"

# postgres as a child, so a stop flushes it before the mount goes away
pgpid=""
stop() {
  [ -n "$pgpid" ] && kill -TERM "$pgpid" 2>/dev/null && wait "$pgpid"
  fusermount3 -u "$PLAIN" 2>/dev/null || umount "$PLAIN" 2>/dev/null
  wait "$gpid" 2>/dev/null
  exit 0
}
trap stop TERM INT
docker-entrypoint.sh "$@" &
pgpid=$!
wait "$pgpid"
rc=$?
fusermount3 -u "$PLAIN" 2>/dev/null || umount "$PLAIN" 2>/dev/null
exit "$rc"
