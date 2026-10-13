#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_local_hub_unlock (spl-local-hub-unlock.func.sh) and the
#   pg vault overlay, hermetic: a stub docker records argv and the stdin
#   vault-unlock gets; a pty from util-linux `script` plays the owner's
#   terminal (input paced, so echo is measured after `read -s` is armed).
#   1. owner rule "ask for the passphrase only on the terminal": stdin from
#      /dev/null, from a pipe and from a file are REFUSED (exit 1) before
#      docker is called, also with a passphrase-looking env var set
#   2. on a tty: prompts "type the passphrase here", sends the passphrase
#      to `docker exec -i <pg> vault-unlock` on stdin only, never in argv;
#      the terminal never shows it (no echo)
#   3. a new volume asks twice: a mismatch and a short one are FATAL and
#      reach no vault-unlock
#   4. a wrong passphrase asks again; three wrong ones are FATAL
#   5. the vault overlay: pg builds from local-hub-pg-vault with the cnf
#      image arg, gets /dev/fuse + SYS_ADMIN, PGDATA off the volume, a tmpfs
#      state dir, and carries no passphrase-like variable
#   6. LIVE, only with LOCAL_HUB_VAULT_LIVE=1 and a DOCKER_HOST: build the
#      vault image, init + unlock a throwaway volume, a marker row is not
#      in the volume's bytes, a restart is locked, a wrong passphrase exits
#      2, the right one brings the row back
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PW="tst-pass-$$-abcdefgh"

mkdir -p "$T/bin"
cat >"$T/lde.env.yaml" <<EOF
env:
  lde:
    local_hub: {user: hub-x, home: /var/lib/hub-x, compose_project: proj-x, pg_port: 1, gcs_port: 2, hub_port: 3, wui_port: 4}
EOF
# stub docker: argv to argv.log; vault-unlock's stdin to stdin.log; its exit
# codes popped from rc.seq (default 0)
cat >"$T/bin/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/argv.log"
case "\$*" in
  "ps -q "*) echo cid123 ;;
  "exec cid123 cat /run/vault/state") cat "$T/state" ;;
  "exec -i cid123 vault-unlock")
    cat >>"$T/stdin.log"
    rc=\$(head -n1 "$T/rc.seq" 2>/dev/null); tail -n +2 "$T/rc.seq" >"$T/rc.tmp" 2>/dev/null; mv -f "$T/rc.tmp" "$T/rc.seq"
    exit "\${rc:-0}" ;;
esac
EOF
chmod +x "$T/bin/docker"

FN='do_log() { echo "$*"; }
source "$PROJ_PATH/src/bash/run/spl-local-hub-harden-check.func.sh"
source "$PROJ_PATH/src/bash/run/spl-local-hub-unlock.func.sh"
do_spl_local_hub_unlock; echo "rc=$?"'
envs=(PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" LOCAL_HUB_CNF="$T/lde.env.yaml" DOCKER_HOST=unix:///nonexistent)
reset() { : >"$T/argv.log"; : >"$T/stdin.log"; rm -f "$T/rc.seq"; echo "${1:-locked 1}" >"$T/state"; }

# --- 1. non-tty stdin is refused ---------------------------------------------------
refused() {  # <name> <out>
  if [[ "$2" == *"rc=1"* && "$2" == *"terminal only"* && ! -s "$T/argv.log" ]]; then pass "refused: $1"
  else fail "not refused: $1 -- $2 / docker: $(cat "$T/argv.log")"; fi
}
reset; out=$(env "${envs[@]}" LOCAL_HUB_PASSPHRASE="$PW" bash -c "$FN" </dev/null 2>&1); refused "stdin </dev/null (passphrase env set)" "$out"
reset; out=$(printf '%s\n' "$PW" | env "${envs[@]}" bash -c "$FN" 2>&1); refused "a piped passphrase" "$out"
reset; printf '%s\n' "$PW" >"$T/pw.txt"; out=$(env "${envs[@]}" bash -c "$FN" <"$T/pw.txt" 2>&1); refused "stdin from a file" "$out"

# on_tty <input lines...> -- run the action on a pty, feeding one line a second
on_tty() {
  local l
  { sleep 1; for l in "$@"; do printf '%s\r' "$l"; sleep 1; done; sleep 1; } \
    | env "${envs[@]}" FN="$FN" SHELL=/bin/bash script -qec 'bash -c "$FN"' /dev/null 2>&1 | tr -d '\r'
}
if ! command -v script >/dev/null 2>&1; then
  skip "no util-linux script: the tty cases need a pty"
else
  # --- 2. on a tty ------------------------------------------------------------------
  reset "locked 1"; out=$(on_tty "$PW")
  [[ "$out" == *"type the passphrase here"* && "$out" == *"rc=0"* ]] && pass "tty: prompts and unlocks" || fail "tty unlock: $out"
  [[ "$(cat "$T/stdin.log")" == "$PW" ]] && pass "tty: the passphrase reaches vault-unlock on stdin" || fail "tty stdin: '$(cat "$T/stdin.log")'"
  grep -qF -- "$PW" "$T/argv.log" && fail "tty: the passphrase is in docker's argv" || pass "tty: never in argv"
  [[ "$out" != *"$PW"* ]] && pass "tty: no echo of the passphrase" || fail "tty: the passphrase was echoed: $out"
  reset unlocked; out=$(on_tty)
  [[ "$out" == *"already unlocked"* && ! -s "$T/stdin.log" ]] && pass "tty: an unlocked vault asks nothing" || fail "already: $out"

  # --- 3. a new volume ----------------------------------------------------------------
  reset needs-init; out=$(on_tty "$PW" "$PW")
  [[ "$out" == *"type it again"* && "$out" == *"rc=0"* && "$(cat "$T/stdin.log")" == "$PW" ]] \
    && pass "new volume: asks twice, sends once" || fail "new volume: $out"
  reset needs-init; out=$(on_tty "$PW" "${PW}x")
  [[ "$out" == *"differ"* && "$out" == *"rc=1"* && ! -s "$T/stdin.log" ]] && pass "new volume: a mismatch is FATAL" || fail "mismatch: $out"
  reset needs-init; out=$(on_tty short short)
  [[ "$out" == *"shorter than"* && "$out" == *"rc=1"* && ! -s "$T/stdin.log" ]] && pass "new volume: a short passphrase is FATAL" || fail "short: $out"

  # --- 4. wrong passphrases --------------------------------------------------------------
  reset "locked 1"; printf '2\n0\n' >"$T/rc.seq"; out=$(on_tty bad "$PW")
  [[ "$out" == *"wrong passphrase (try 1 of 3)"* && "$out" == *"rc=0"* ]] && pass "a wrong passphrase asks again" || fail "retry: $out"
  reset "locked 1"; printf '2\n2\n2\n' >"$T/rc.seq"; out=$(on_tty b1 b2 b3)
  [[ "$out" == *"3 wrong passphrases"* && "$out" == *"rc=1"* ]] && pass "three wrong passphrases are FATAL" || fail "3 wrong: $out"
fi

# --- 5. the vault overlay --------------------------------------------------------------
V="$PROJ_ROOT/src/docker/docker-compose-local-hub-vault.yaml"
q() { yq -r "$1" "$V"; }
[[ "$(q '.services.pg.build.context')" == ./local-hub-pg-vault && "$(q '.services.pg.build.args.LDE_PG_IMAGE')" == *'LDE_PG_IMAGE'* ]] \
  && pass "overlay: pg builds from local-hub-pg-vault on the cnf image" || fail "overlay build: $(q '.services.pg.build')"
[[ "$(q '.services.pg.devices[0]')" == /dev/fuse:/dev/fuse && "$(q '.services.pg.cap_add[0]')" == SYS_ADMIN ]] \
  && pass "overlay: /dev/fuse + SYS_ADMIN" || fail "overlay fuse"
[[ "$(q '.services.pg.environment.PGDATA')" == /run/pgplain/data && "$(q '.services.pg.tmpfs[0]')" == /run/vault:* ]] \
  && pass "overlay: PGDATA on the decrypted view, state on a tmpfs" || fail "overlay PGDATA/tmpfs"
grep -qiE 'pass(phrase|word)?[A-Z_]*:|_PASS[A-Z_]*:' <(q '.services.pg | del(.healthcheck)') \
  && fail "overlay: a passphrase-like variable in pg" || pass "overlay: no passphrase variable"
[[ "$(q '.services.pg.image')" != *postgres* ]] && pass "overlay: the built image never takes the cnf image's name" || fail "overlay image: $(q '.services.pg.image')"

# --- 6. LIVE ---------------------------------------------------------------------------
if [[ "${LOCAL_HUB_VAULT_LIVE:-0}" == 1 && -n "${DOCKER_HOST:-}" ]]; then
  img="spl-vault-tst-$$:local" vol="spl-vault-tst-$$" c="spl-vault-tst-$$"
  docker build -q --build-arg LDE_PG_IMAGE="${LDE_PG_IMAGE:-postgres:16-alpine}" -t "$img" "$PROJ_ROOT/src/docker/local-hub-pg-vault" >/dev/null
  start() { docker run -d --name "$c" --device /dev/fuse --cap-add SYS_ADMIN --tmpfs /run/vault:mode=0700 \
    -e PGDATA=/run/pgplain/data -e POSTGRES_USER=u -e POSTGRES_PASSWORD=p -e POSTGRES_DB=d -v "$vol:/var/lib/postgresql/data" "$img" >/dev/null; sleep 2; }
  ready() { local _; for _ in $(seq 40); do docker exec "$c" pg_isready -h 127.0.0.1 -U u -d d >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
  start
  printf '%s\n' "$PW" | docker exec -i "$c" vault-unlock >/dev/null; ready
  docker exec "$c" psql -qh 127.0.0.1 -U u -d d -c "create table t(v text); insert into t values ('MARKER-$$'); checkpoint;" >/dev/null
  if ! docker run --rm -v "$vol:/v" busybox:stable test -f /v/gocryptfs.conf; then fail "live: the volume is not a gocryptfs store"
  elif docker run --rm -v "$vol:/v" busybox:stable grep -rl "MARKER-$$" /v >/dev/null 2>&1; then fail "live: the marker is in the volume's bytes"
  else pass "live: the volume is a gocryptfs store without the marker's bytes"; fi
  docker restart "$c" >/dev/null; sleep 3
  [[ "$(docker exec "$c" cat /run/vault/state)" == "locked "* ]] && pass "live: a restart is locked" || fail "live: restart not locked"
  printf 'wrong-one\n' | docker exec -i "$c" vault-unlock >/dev/null 2>&1; rc=$?
  [[ $rc -eq 2 ]] && pass "live: a wrong passphrase exits 2" || fail "live: wrong rc=$rc"
  printf '%s\n' "$PW" | docker exec -i "$c" vault-unlock >/dev/null 2>&1; ready
  [[ "$(docker exec "$c" psql -h 127.0.0.1 -U u -d d -tAc 'select v from t')" == "MARKER-$$" ]] && pass "live: the right one brings the row back" || fail "live: row lost"
  docker rm -f "$c" >/dev/null; docker volume rm "$vol" >/dev/null; docker rmi "$img" >/dev/null
else
  # opt-in, like lde-up's LIVE: not a SKIP, so CI's no-SKIP rule stays meaningful
  echo "INFO: LIVE vault not run (set LOCAL_HUB_VAULT_LIVE=1 with a DOCKER_HOST)"
fi

echo "--- spl-local-hub-unlock: $fails failure(s)"
[[ $fails -eq 0 ]]
