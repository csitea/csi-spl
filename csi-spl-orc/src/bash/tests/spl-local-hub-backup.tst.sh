#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the local hub's backups (lane L4): do_spl_local_hub_backup /
# _restore / _backup_check / _backup_keygen and the job's in-container script
# (src/docker/local-hub-backup/backup.sh), on temp dirs. Hermetic: pg_dump,
# psql, pg_restore, createdb, dropdb and age are stubs; docker / lde_compose
# are stubbed for the actions. No fleet DB, no live spool root, no live home.
#   1. backup.sh once: the dump goes pg_dump | age straight to <name>.dump.age
#      (no clear file ever in the dir), a .meta with the sha256 and counts;
#      refusals: no recipient, a SECRET key as the recipient, a failed
#      pg_dump keeps nothing; retention keeps the newest BACKUP_KEEP
#   2. backup.sh restore (owner msg 8fbbb8e0, owner-held key): a CLEAR
#      identity is refused, a passphrase-wrapped one is used; a sha256
#      mismatch refuses; a scratch restore never targets the live DB; counts
#      vs .meta are the verdict (control: a mismatch FAILs); the scratch DB is
#      dropped; no key byte is ever printed
#   3. the actions: _backup_check refuses a missing / secret recipient and a
#      clear identity; _backup runs `backup once` through lde_compose; restore
#      needs a terminal (the owner types the passphrase), mounts the identity
#      read-only, refuses LIVE while the hub runs or without the confirm
#      and every passphrase is typed on the terminal only (owner msg
#      3cfe43ce): restore and keygen refuse stdin </dev/null and a pipe
#   4. the compose overlay (SKIP without docker compose): service backup has
#      no published port, is read-only, drops every cap, mounts the
#      recipient read-only and never an identity
#   5. (opt-in LOCAL_HUB_BACKUP_DOCKER_PROOF=1, real docker) the round trip:
#      pg up, seed, keygen with a throwaway passphrase, backup, restore into
#      a scratch DB through a pty, PASS on the counts
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
# dumps -> the dump names in $D, oldest first
dumps() { local p; for p in "$D"/*.dump.age; do [[ -e "$p" ]] && basename "$p"; done | sort; }
JOB="$PROJ_ROOT/src/docker/local-hub-backup/backup.sh"
OVL="$PROJ_ROOT/src/docker/docker-compose-local-hub-backup.yaml"
SHA=(dash); command -v busybox >/dev/null && SHA=(busybox sh)
SECRET_MARK="AGE-SECRET-KEY-1TESTMARKERZZZ"

# --- stubs of the pg tools and age, for backup.sh -------------------------------
B="$T/bin"; mkdir -p "$B"
cat >"$B/pg_dump" <<'EOF'
#!/bin/sh
[ "${STUB_DUMP_FAIL:-0}" = 1 ] && { echo "pg_dump: boom" >&2; exit 1; }
echo "PGDMP clear rows of $PGDATABASE"
EOF
cat >"$B/psql" <<'EOF'
#!/bin/sh
for a; do d="$a"; done
case "$*" in *" -d $PGDATABASE "*) echo "${STUB_LIVE_COUNTS:-12 7}" ;; *) echo "${STUB_RESTORED_COUNTS:-12 7}" ;; esac
EOF
cat >"$B/age" <<'EOF'
#!/bin/sh
# -R <rec> -o <out> (encrypt stdin) | -d -i <id> <file> (decrypt to stdout)
echo "age $*" >>"$STUB_LOG"
case "$1" in
  -R) { echo "AGEENC"; cat; } >"$4" ;;
  -d) tail -n +2 "$4" ;;
esac
EOF
cat >"$B/pg_restore" <<'EOF'
#!/bin/sh
echo "pg_restore $*" >>"$STUB_LOG"; cat >/dev/null
EOF
printf '#!/bin/sh\necho "createdb $*" >>"$STUB_LOG"\n' >"$B/createdb"
printf '#!/bin/sh\necho "dropdb $*" >>"$STUB_LOG"\n' >"$B/dropdb"
chmod +x "$B"/*
K="$T/keys"; mkdir -p "$K"
echo "age1qqqtestrecipientqqq" >"$K/recipient"
echo "$SECRET_MARK" >"$K/secret"
printf 'age-encryption.org/v1\n-> scrypt abc 18\nwrapped\n' >"$K/identity.age"
D="$T/backups"; mkdir -p "$D"
job() { env PATH="$B:$PATH" STUB_LOG="$T/job.log" PGHOST=pg PGUSER=u PGPASSWORD=x PGDATABASE=spool \
  BACKUP_DIR="$D" BACKUP_RECIPIENT="$K/recipient" BACKUP_IDENTITY="$K/identity.age" "$@"; }

# --- 1. once ------------------------------------------------------------------
out="$(job "${SHA[@]}" "$JOB" once 2>&1)"; rc=$?
f="$(dumps | sed -n 1p)"
if [[ $rc -eq 0 && -n "$f" && -f "$D/$f.meta" ]]; then pass "once: $f + .meta"; else fail "once rc=$rc: $out"; fi
if grep -rl 'PGDMP' "$D" | grep -v '\.dump\.age$' >/dev/null || [[ "$(head -1 "$D/$f")" != AGEENC ]]; then fail "a clear dump is on disk"; else pass "no clear dump in the dir (only age output)"; fi
[[ -z "$(find "$D" -mindepth 1 ! -name '*.dump.age' ! -name '*.dump.age.meta')" ]] && pass "no temp file left" || fail "left: $(ls -A "$D")"
[[ "$(sed -n 's/^sha256=//p' "$D/$f.meta")" == "$(sha256sum "$D/$f" | cut -d' ' -f1)" ]] && pass ".meta sha256 = the file" || fail ".meta sha256 wrong"
grep -qx 'tables=12' "$D/$f.meta" && grep -qx 'migrations=7' "$D/$f.meta" && pass ".meta counts" || fail ".meta: $(cat "$D/$f.meta")"
[[ "$(stat -c %a "$D/$f")" == 640 ]] && pass "dump is 0640 (group postgres reads it for a restore)" || fail "dump mode $(stat -c %a "$D/$f")"

out="$(job BACKUP_RECIPIENT="$K/none" "${SHA[@]}" "$JOB" once 2>&1)" && fail "no recipient passed" || { grep -q 'LOCAL_HUB_BACKUP_RECIPIENT_FILE' <<<"$out" && pass "no recipient: refused, names the env" || fail "no recipient msg: $out"; }
out="$(job BACKUP_RECIPIENT="$K/secret" "${SHA[@]}" "$JOB" once 2>&1)" && fail "a SECRET key as recipient passed" || pass "a secret key as the recipient: refused"
grep -q "$SECRET_MARK" <<<"$out" && fail "the secret key was printed" || pass "the secret key is never printed"
n0="$(ls -A "$D" | wc -l)"
out="$(job STUB_DUMP_FAIL=1 "${SHA[@]}" "$JOB" once 2>&1)" && fail "a failed pg_dump passed" || { [[ "$(ls -A "$D" | wc -l)" == "$n0" ]] && pass "failed pg_dump: refused, nothing kept" || fail "failed pg_dump left $(ls -A "$D")"; }

for s in 20260101T000000Z 20260102T000000Z 20260103T000000Z; do : >"$D/spool-$s.dump.age"; : >"$D/spool-$s.dump.age.meta"; done
job BACKUP_KEEP=2 "${SHA[@]}" "$JOB" once >/dev/null 2>&1
left="$(dumps | wc -l)"
[[ "$left" == 2 && ! -e "$D/spool-20260101T000000Z.dump.age" && ! -e "$D/spool-20260102T000000Z.dump.age.meta" ]] && pass "retention keeps the newest 2 (dump + meta)" || fail "retention left $left: $(ls "$D")"

# --- 2. restore ---------------------------------------------------------------
: >"$T/job.log"
out="$(job BACKUP_IDENTITY="$K/secret" "${SHA[@]}" "$JOB" restore latest 2>&1)" && fail "a CLEAR identity passed" || { grep -q 'CLEAR' <<<"$out" && pass "a clear identity is refused (owner 8fbbb8e0)" || fail "clear identity msg: $out"; }
grep -q "$SECRET_MARK" <<<"$out" && fail "the identity was printed" || pass "the identity is never printed"
out="$(job RESTORE_DB=spool_proof "${SHA[@]}" "$JOB" restore latest 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^PASS restore .* -> spool_proof' <<<"$out" && pass "restore latest -> scratch spool_proof: PASS on the counts" || fail "restore rc=$rc: $out"
grep -q '^createdb spool_proof' "$T/job.log" && grep -q '^pg_restore --exit-on-error --no-owner --no-privileges -d spool_proof' "$T/job.log" && grep -q '^dropdb spool_proof' "$T/job.log" \
  && pass "scratch: createdb, pg_restore --no-owner, dropdb" || fail "restore calls: $(cat "$T/job.log")"
grep -q "^age -d -i $K/identity.age " "$T/job.log" && pass "age -d with the wrapped identity" || fail "age calls: $(grep '^age' "$T/job.log")"
out="$(job RESTORE_DB=spool "${SHA[@]}" "$JOB" restore latest 2>&1)" && fail "scratch restore into the live DB passed" || pass "a scratch restore never targets the live DB"
out="$(job RESTORE_DB=spool_p2 STUB_RESTORED_COUNTS='11 7' "${SHA[@]}" "$JOB" restore latest 2>&1)" && fail "control: a count mismatch passed" || { grep -q '^FAIL restore' <<<"$out" && pass "control: a count mismatch FAILs" || fail "mismatch msg: $out"; }
g="$(dumps | tail -1)"; echo tamper >>"$D/$g"
out="$(job RESTORE_DB=spool_p3 "${SHA[@]}" "$JOB" restore "$g" 2>&1)" && fail "a tampered dump passed" || { grep -q 'sha256' <<<"$out" && pass "a sha256 mismatch refuses" || fail "tamper msg: $out"; }

# --- 3. the actions -----------------------------------------------------------
orc_stub 0 docker
ACT_STUBS='spl_local_hub_env() { export LDE_COMPOSE_PROJECT=spl-local-hub LDE_PG_DB=spool; }
spl_local_hub_cnf() { export LOCAL_HUB_USER=hubu LOCAL_HUB_HOME="${LOCAL_HUB_HOME:-/nonexistent}" LOCAL_HUB_CONFIG="${LOCAL_HUB_CONFIG:-/nonexistent/local-hub.env}"; }
spl_local_hub_is_user() { [[ "${STUB_NOT_HUB:-0}" == 0 ]]; }
spl_local_hub_reexec() { echo "REEXEC $1 pass=${LOCAL_HUB_REEXEC_PASS:-} idf=${LOCAL_HUB_BACKUP_IDENTITY_FILE:-}" >>"$STUB_LOG"
  [[ -n "${LOCAL_HUB_BACKUP_IDENTITY_FILE:-}" && -f "$LOCAL_HUB_BACKUP_IDENTITY_FILE" ]] && { cmp -s "$LOCAL_HUB_BACKUP_IDENTITY_FILE" "$STUB_IDF" && echo STAGED-SAME >>"$STUB_LOG"; stat -c "%a" "${LOCAL_HUB_BACKUP_IDENTITY_FILE%/*}" >>"$STUB_LOG"; }
  return "${STUB_REEXEC_RC:-0}"; }
lde_compose() { echo "lde_compose $*" >>"$STUB_LOG"
  if [[ "$*" == *" keygen /keys" ]]; then local v="$*"; v="${v#*-v }"; v="${v%%:/keys*}"; echo age1x >"$v/recipient"; echo w >"$v/identity.age"; fi; }
docker() { echo "docker $*" >>"$STUB_LOG"; [[ "$*" == ps* ]] && echo "${STUB_HUB_ID:-}"; return 0; }'
act() { : >"$T/calls.log"; SNIPPET="$ACT_STUBS; $1" in_orc "${@:2}" 2>&1; }
out="$(act do_spl_local_hub_backup_check)" && fail "check passed with no recipient" || pass "check: no LOCAL_HUB_BACKUP_RECIPIENT_FILE refused"
out="$(act do_spl_local_hub_backup_check LOCAL_HUB_BACKUP_RECIPIENT_FILE="$K/secret")" && fail "check passed a secret recipient" || pass "check: a secret key as the recipient refused"
grep -q "$SECRET_MARK" <<<"$out" && fail "check printed the key" || pass "check never prints the key"
out="$(act do_spl_local_hub_backup_check LOCAL_HUB_BACKUP_RECIPIENT_FILE="$K/recipient" LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/secret")" && fail "check passed a clear identity on the box" || pass "check: a clear identity on the box refused"
cp "$K/recipient" "$K/rec600"; chmod 600 "$K/rec600"
out="$(act do_spl_local_hub_backup_check LOCAL_HUB_BACKUP_RECIPIENT_FILE="$K/rec600")" && fail "check passed a 0600 recipient the job cannot read" || pass "check: a recipient the job cannot read (0600) refused"
out="$(act do_spl_local_hub_backup_check LOCAL_HUB_BACKUP_RECIPIENT_FILE="$K/recipient")" && pass "check: a public recipient passes" || fail "check: $out"
out="$(act do_spl_local_hub_backup LOCAL_HUB_BACKUP_RECIPIENT_FILE="$K/recipient")"
grep -qx 'lde_compose run --rm -T backup once' "$T/calls.log" && pass "backup: lde_compose run --rm -T backup once" || fail "backup calls: $(cat "$T/calls.log") $out"
out="$(act 'do_spl_local_hub_restore </dev/null' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age")" && fail "restore without a terminal passed" || { grep -q 'terminal' <<<"$out" && pass "restore needs a terminal (the owner types the passphrase)" || fail "no-tty msg: $out"; }
out="$(act 'echo pw | do_spl_local_hub_restore' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age")" && fail "restore with piped stdin passed" || pass "restore refuses piped stdin (owner 3cfe43ce)"
mkdir -p "$T/kd"
out="$(act 'do_spl_local_hub_backup_keygen </dev/null' LOCAL_HUB_BACKUP_KEY_DIR="$T/kd")" && fail "keygen without a terminal passed" || { grep -q 'terminal' <<<"$out" && pass "keygen refuses stdin </dev/null" || fail "keygen no-tty msg: $out"; }
out="$(act 'echo pw | do_spl_local_hub_backup_keygen' LOCAL_HUB_BACKUP_KEY_DIR="$T/kd")" && fail "keygen with piped stdin passed" || pass "keygen refuses piped stdin"
grep -q '^lde_compose' "$T/calls.log" && fail "a refused keygen still ran compose" || pass "a refused keygen runs nothing"
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_restore' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age" LOCAL_HUB_RESTORE_DB=spool_proof)"
grep -q "^lde_compose run --rm -u $(id -u):70 -v $K/identity.age:/run/keys/identity:ro -e RESTORE_DB=spool_proof -e RESTORE_LIVE=0 -e RESTORE_KEEP=0 backup restore latest$" "$T/calls.log" \
  && pass "restore: identity mounted read-only, scratch DB, latest" || fail "restore calls: $(cat "$T/calls.log") $out"
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_restore' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/secret")" && fail "restore passed a clear identity" || pass "restore: a clear identity refused"
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_restore' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age" LOCAL_HUB_RESTORE_LIVE=1)" && fail "LIVE without confirm passed" || pass "LIVE needs LOCAL_HUB_RESTORE_CONFIRM=<db>"
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_restore' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age" LOCAL_HUB_RESTORE_LIVE=1 LOCAL_HUB_RESTORE_CONFIRM=spool STUB_HUB_ID=abc123)" && fail "LIVE with the hub running passed" || { grep -q 'hub' <<<"$out" && pass "LIVE refused while the hub runs" || fail "hub-running msg: $out"; }
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_restore' LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age" LOCAL_HUB_RESTORE_LIVE=1 LOCAL_HUB_RESTORE_CONFIRM=spool)"
grep -q -- '-e RESTORE_LIVE=1 .*backup restore latest$' "$T/calls.log" && pass "LIVE with the hub stopped + confirm runs" || fail "live calls: $(cat "$T/calls.log") $out"

# not the hub user: every action re-runs as it, nothing runs here
for a in do_spl_local_hub_backup do_spl_local_hub_backup_list do_spl_local_hub_backup_check; do
  out="$(act "$a" STUB_NOT_HUB=1 STUB_REEXEC_RC=7)"; rc=$?
  grep -q "^REEXEC $a " "$T/calls.log" && ! grep -q '^lde_compose' "$T/calls.log" && [[ $rc == 7 ]] \
    && pass "$a: not the hub user -> re-runs as it (its exit status kept)" || fail "$a reexec rc=$rc: $(cat "$T/calls.log") $out"
done
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_backup_keygen' STUB_NOT_HUB=1)"
grep -q '^REEXEC do_spl_local_hub_backup_keygen pass=LOCAL_HUB_BACKUP_KEY_DIR ' "$T/calls.log" && ! grep -q '^lde_compose' "$T/calls.log" \
  && pass "keygen: not the hub user -> re-runs as it, KEY_DIR passed" || fail "keygen reexec: $(cat "$T/calls.log") $out"
# restore as the operator: the wrapped identity is staged for the hub user (0700), passed, then removed
mkdir -p "$T/hh/state"; printf '#!/bin/bash\nwhile [[ $1 == -* ]]; do [[ $1 == -u ]] && shift; shift; done; exec "$@"\n' >"$T/sudo"; chmod +x "$T/sudo"
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_restore' STUB_NOT_HUB=1 LOCAL_HUB_SUDO="$T/sudo" LOCAL_HUB_HOME="$T/hh" STUB_IDF="$K/identity.age" \
  LOCAL_HUB_BACKUP_IDENTITY_FILE="$K/identity.age" LOCAL_HUB_RESTORE_DB=spool_proof)"; rc=$?
grep -q "^REEXEC do_spl_local_hub_restore pass=LOCAL_HUB_BACKUP_IDENTITY_FILE .*LOCAL_HUB_RESTORE_DB.* idf=$T/hh/state/restore-key\." "$T/calls.log" && grep -qx STAGED-SAME "$T/calls.log" && grep -qx 700 "$T/calls.log" \
  && pass "restore: not the hub user -> identity staged (0700, same bytes) and passed" || fail "restore reexec rc=$rc: $(cat "$T/calls.log") $out"
[[ $rc == 0 && -z "$(ls -A "$T/hh/state")" ]] && pass "restore: the staged identity is removed after the run" || fail "staged left: $(ls -A "$T/hh/state")"
# keygen as the hub user, no KEY_DIR: <config dir>/backup-key (0700), recipient 0644
mkdir -p "$T/cfgd"
out="$(act 'spl_lhr_tty() { return 0; }; do_spl_local_hub_backup_keygen 2>&1; echo rc=$?' LOCAL_HUB_CONFIG="$T/cfgd/local-hub.env")"
grep -q -- "-v $T/cfgd/backup-key:/keys backup keygen /keys$" "$T/calls.log" && [[ "$(stat -c %a "$T/cfgd/backup-key")" == 700 && "$(stat -c %a "$T/cfgd/backup-key/recipient")" == 644 ]] \
  && pass "keygen: default dir <config dir>/backup-key (0700), recipient 0644" || fail "keygen default: $(cat "$T/calls.log") $out"

# --- 4. the compose overlay ---------------------------------------------------
if docker compose version >/dev/null 2>&1; then
  cfg="$(LDE_PG_IMAGE=postgres:16-alpine LDE_PG_USER=u LDE_PG_PASSWORD=p LDE_PG_DB=spool LDE_PG_PORT=55999 LDE_GCS_IMAGE=x LDE_GCS_PORT=54999 \
    LOCAL_HUB_BACKUP_RECIPIENT_FILE="$K/recipient" docker compose -p lhb-test -f "$PROJ_ROOT/src/docker/docker-compose-infra.yaml" \
    -f "$PROJ_ROOT/src/docker/docker-compose-rdb.yaml" -f "$OVL" config --format json 2>"$T/cfg.err")"
  if [[ -n "$cfg" ]]; then
    jq -e '.services.backup | (.ports // []) == [] and .read_only == true and .cap_drop == ["ALL"]' <<<"$cfg" >/dev/null \
      && pass "backup: no port, read-only, cap_drop ALL" || fail "backup hardening: $(jq -c '.services.backup | {ports,read_only,cap_drop}' <<<"$cfg")"
    jq -e --arg r "$K/recipient" '[.services.backup.volumes[] | select(.target == "/run/keys/recipient")] | length == 1 and .[0].source == $r and .[0].read_only == true' <<<"$cfg" >/dev/null \
      && pass "recipient mounted read-only" || fail "recipient mount: $(jq -c '.services.backup.volumes' <<<"$cfg")"
    jq -e '[.services.backup.volumes[] | select(.target | test("identity"))] | length == 0' <<<"$cfg" >/dev/null \
      && pass "the job never mounts an identity" || fail "identity mounted in the job"
  else fail "compose config: $(tail -3 "$T/cfg.err")"; fi
else echo "SKIP: docker compose not available"; fi

# --- 5. opt-in: the real round trip ---------------------------------------------
# The passphrase goes in through a pty (script(1)), as the owner's terminal
# would; the identity is a throwaway made here.
if [[ "${LOCAL_HUB_BACKUP_DOCKER_PROOF:-0}" == 1 ]]; then
  P="lhb-proof-$$" PK="$T/pkeys" PD="$T/drive.sh"; mkdir -p "$PK"
  export LDE_PG_IMAGE=postgres:16-alpine LDE_PG_USER=spool LDE_PG_PASSWORD=proof_pw LDE_PG_DB=spool LDE_PG_PORT=55991 \
    LDE_GCS_IMAGE=fsouza/fake-gcs-server:1.52.2 LDE_GCS_PORT=54991 LOCAL_HUB_BACKUP_RECIPIENT_FILE="$PK/recipient"
  pc() { docker compose -p "$P" -f "$PROJ_ROOT/src/docker/docker-compose-infra.yaml" -f "$PROJ_ROOT/src/docker/docker-compose-rdb.yaml" -f "$OVL" "$@"; }
  cat >"$PD" <<EOF2
set -uo pipefail
do_log() { echo "\$*"; }
for f in "$PROJ_ROOT"/lib/bash/funcs/*.func.sh "$PROJ_ROOT"/src/bash/run/*.func.sh; do source "\$f"; done
spl_local_hub_env() { export LDE_COMPOSE_PROJECT=$P; }
spl_local_hub_cnf() { :; }; spl_local_hub_is_user() { return 0; }
lde_compose() { docker compose -p $P -f "$PROJ_ROOT/src/docker/docker-compose-infra.yaml" -f "$PROJ_ROOT/src/docker/docker-compose-rdb.yaml" -f "$OVL" "\$@"; }
"\$@"
EOF2
  pc up -d --wait pg >"$T/p.up" 2>&1 || fail "proof: pg up: $(tail -3 "$T/p.up")"
  pc exec -T pg psql -q -U spool -d spool -c "create table spool_schema_migrations(v int); insert into spool_schema_migrations values (1),(2),(3);
    create table proof_rows(x int); insert into proof_rows select generate_series(1, 500);" >/dev/null 2>&1
  printf 'throwaway-pw\nthrowaway-pw\n' | LOCAL_HUB_BACKUP_KEY_DIR="$PK" script -qec "bash $PD do_spl_local_hub_backup_keygen" /dev/null >"$T/p.kg" 2>&1
  [[ -s "$PK/recipient" ]] && [[ "$(sed -n 1p "$PK/identity.age")" == age-encryption.org/v1 ]] && ! grep -q AGE-SECRET-KEY "$PK/identity.age" \
    && pass "proof: keygen via the terminal -> wrapped identity + recipient" || fail "proof keygen: $(tail -5 "$T/p.kg")"
  bash "$PD" do_spl_local_hub_backup >"$T/p.bk" 2>&1 && grep -q 'tables=2 migrations=3' "$T/p.bk" && pass "proof: backup once (tables=2 migrations=3)" || fail "proof backup: $(tail -5 "$T/p.bk")"
  printf 'throwaway-pw\n' | LOCAL_HUB_BACKUP_IDENTITY_FILE="$PK/identity.age" LOCAL_HUB_RESTORE_DB=spool_proof script -qec "bash $PD do_spl_local_hub_restore" /dev/null >"$T/p.rs" 2>&1
  grep -q 'PASS restore .* -> spool_proof: tables migrations = 2 3' "$T/p.rs" && pass "proof: restore into scratch spool_proof, counts = .meta" || fail "proof restore: $(tail -8 "$T/p.rs")"
  [[ -z "$(pc exec -T pg psql -U spool -d spool -Atc "select 1 from pg_database where datname = 'spool_proof'")" ]] && pass "proof: the scratch DB is dropped" || fail "proof: spool_proof left behind"
  printf 'wrong-pw\n' | LOCAL_HUB_BACKUP_IDENTITY_FILE="$PK/identity.age" LOCAL_HUB_RESTORE_DB=spool_p2 script -qec "bash $PD do_spl_local_hub_restore" /dev/null >"$T/p.rs2" 2>&1
  grep -q 'PASS restore' "$T/p.rs2" && fail "proof control: a wrong passphrase restored" || pass "proof control: a wrong passphrase restores nothing"
  pc down -v >/dev/null 2>&1
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
