#!/bin/sh
# csi-spl local hub ::: `docker exec -i <pg> vault-unlock`, the in-container
# half of do_spl_local_hub_unlock (lane L5). Reads ONE line, the passphrase,
# from stdin (the host action took it from the owner's terminal) and hands it
# to vault-entrypoint's gocryptfs through the 0600 FIFO; twice for a new
# volume (init, then mount). printf is the shell builtin: the passphrase is
# never in argv, env or a file.
# Exit: 0 unlocked; 2 wrong passphrase; 3 no passphrase on stdin; 4 the
# vault is not waiting (no entrypoint state); 5 timed out.
set -u
VAULT_RUN="${VAULT_RUN:-/run/vault}"
STATE="$VAULT_RUN/state"
FIFO="$VAULT_RUN/pass"
st() { cat "$STATE" 2>/dev/null; }

pass=""
IFS= read -r pass || [ -n "$pass" ] || true
[ -n "$pass" ] || { echo "vault-unlock: no passphrase on stdin" >&2; exit 3; }
# right after a wrong one the entrypoint pauses before it waits again
i=0; while case "$(st)" in "wrong "*) true ;; *) false ;; esac && [ $i -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
s="$(st)"
case "$s" in
  unlocked) pass=""; echo "vault-unlock: already unlocked"; exit 0 ;;
  needs-init)
    printf '%s\n' "$pass" >"$FIFO"
    i=0; while [ "$(st)" = needs-init ] && [ $i -lt 300 ]; do sleep 0.2; i=$((i + 1)); done
    s="$(st)" ;;
esac
case "$s" in
  "locked "*) ;;
  *) pass=""; echo "vault-unlock: the vault is not waiting (state: ${s:-none})" >&2; exit 4 ;;
esac
printf '%s\n' "$pass" >"$FIFO"
pass=""
i=0
while [ $i -lt 300 ]; do
  now="$(st)"
  [ "$now" = unlocked ] && { echo "vault-unlock: unlocked"; exit 0; }
  [ "$now" != "$s" ] && { echo "vault-unlock: wrong passphrase" >&2; exit 2; }
  sleep 0.2; i=$((i + 1))
done
echo "vault-unlock: timed out waiting for the vault" >&2
exit 5
