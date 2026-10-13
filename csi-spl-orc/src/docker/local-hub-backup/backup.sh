#!/bin/sh
# shellcheck shell=busybox
#------------------------------------------------------------------------------
# The local hub's backup job (lane L4), run INSIDE the backup container (an
# alpine postgres image + age: busybox sh, no bash). Modes:
#   once              one encrypted dump of $PGDATABASE into $BACKUP_DIR
#   loop              `once` every day at $BACKUP_AT (HH:MM, UTC), for ever
#   restore <f|latest> decrypt + pg_restore one dump: into a NEW scratch DB
#                     ($RESTORE_DB, the default) or, with RESTORE_LIVE=1, back
#                     into $PGDATABASE; then the counts are checked against
#                     the dump's .meta
#   list              the dumps, newest last
#   keygen <dir>      a NEW owner key pair into <dir>: identity.age (the age
#                     secret key, wrapped with a passphrase the owner types:
#                     age -p) and recipient (the public key). The clear secret
#                     key exists only in a pipe, never on disk.
# The dump never touches disk in clear: pg_dump -Fc pipes straight into age.
# Keys: the job holds the age PUBLIC key only ($BACKUP_RECIPIENT, read-only);
# the secret identity ($BACKUP_IDENTITY) is OWNER-HELD (owner msg 8fbbb8e0):
# a passphrase-wrapped age identity, mounted only into a restore run, where
# age asks the owner for the passphrase on the terminal. A clear identity file
# is refused. Neither key is ever printed.
# Env: PGHOST PGUSER PGPASSWORD PGDATABASE (libpq), BACKUP_DIR (/backups),
# BACKUP_KEEP (14), BACKUP_AT (03:15), BACKUP_RECIPIENT (/run/keys/recipient),
# BACKUP_IDENTITY (/run/keys/identity), RESTORE_DB, RESTORE_LIVE, RESTORE_KEEP.
#------------------------------------------------------------------------------
set -eu
set -o pipefail

DIR="${BACKUP_DIR:-/backups}"
KEEP="${BACKUP_KEEP:-14}"
AT="${BACKUP_AT:-03:15}"
REC="${BACKUP_RECIPIENT:-/run/keys/recipient}"
IDF="${BACKUP_IDENTITY:-/run/keys/identity}"

log() { echo "$*" >&2; }
die() { log "FATAL backup: $*"; exit 1; }
# matches <ere> <value> -> 0 when the one-line value matches (no pipe: SIGPIPE-safe)
matches() { grep -Eq "$1" <<EOF
$2
EOF
}

# counts <db> -> "<base tables> <migrations>" of <db>
counts() {
  psql -X -v ON_ERROR_STOP=1 -d "$1" -Atc "select (select count(*) from information_schema.tables
    where table_type = 'BASE TABLE' and table_schema not in ('pg_catalog', 'information_schema'))
    || ' ' || coalesce((select count(*) from spool_schema_migrations
    where to_regclass('spool_schema_migrations') is not null), 0)"
}

check_recipient() {
  [ -s "$REC" ] || die "no age recipient (public key) at $REC: set LOCAL_HUB_BACKUP_RECIPIENT_FILE"
  if grep -q 'AGE-SECRET-KEY' "$REC"; then die "$REC holds a SECRET key: the job takes the public key (age-keygen -y) only"; fi
  grep -q '^age1' "$REC" || die "$REC is not an age recipient file (no age1... line)"
}

# check_identity -> the identity is passphrase-wrapped (age -p): a clear
# AGE-SECRET-KEY file on the box is refused (owner msg 8fbbb8e0)
check_identity() {
  [ -s "$IDF" ] || die "no age identity at $IDF: set LOCAL_HUB_BACKUP_IDENTITY_FILE"
  if grep -q 'AGE-SECRET-KEY' "$IDF"; then die "$IDF is a CLEAR secret key: refused; wrap it with a passphrase (keygen does)"; fi
  case "$(sed -n 1p "$IDF")" in
    age-encryption.org/v1 | '-----BEGIN AGE ENCRYPTED FILE-----') ;;
    *) die "$IDF is not a passphrase-wrapped age identity" ;;
  esac
}

do_keygen() {
  out="${1:-}"; [ -n "$out" ] && [ -d "$out" ] && [ -w "$out" ] || die "keygen needs a writable dir"
  [ ! -e "$out/identity.age" ] && [ ! -e "$out/recipient" ] || die "$out already holds a key: never overwritten"
  umask 077
  pub="$(mktemp)"
  age-keygen 2>"$pub" | age -p -o "$out/identity.age" || { rm -f "$pub" "$out/identity.age"; die "keygen failed: nothing kept"; }
  sed -n 's/^Public key: //p' "$pub" >"$out/recipient"; rm -f "$pub"; chmod 644 "$out/recipient"
  grep -q '^age1' "$out/recipient" || { rm -f "$out/identity.age" "$out/recipient"; die "no public key from age-keygen"; }
  echo "OK keygen: $out/identity.age (passphrase-wrapped, keep it OFF this box) and $out/recipient"
}

do_once() {
  check_recipient
  [ -d "$DIR" ] && [ -w "$DIR" ] || die "$DIR is not a writable dir"
  umask 027
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  name="$PGDATABASE-$stamp.dump.age"
  c="$(counts "$PGDATABASE")" || die "cannot read $PGDATABASE on $PGHOST"
  if ! pg_dump -Fc -d "$PGDATABASE" | age -R "$REC" -o "$DIR/.$name.tmp"; then
    rm -f "$DIR/.$name.tmp"; die "pg_dump | age failed: nothing kept"
  fi
  sha="$(sha256sum "$DIR/.$name.tmp" | cut -d' ' -f1)"
  mv "$DIR/.$name.tmp" "$DIR/$name"
  printf 'file=%s\nsha256=%s\ndb=%s\ntables=%s\nmigrations=%s\n' "$name" "$sha" "$PGDATABASE" "${c% *}" "${c#* }" >"$DIR/$name.meta"
  echo "OK backup $name $(wc -c <"$DIR/$name") bytes, tables=${c% *} migrations=${c#* }"
  prune
}

# dumps -> the dump names in $DIR, oldest first (names sort by their UTC stamp)
dumps() {
  for p in "$DIR"/*.dump.age; do [ -e "$p" ] && basename "$p"; done | sort
}

# prune -> keep the newest $KEEP dumps (names sort by their UTC stamp)
prune() {
  n=0
  for f in $(dumps | sort -r); do
    n=$((n + 1))
    [ "$n" -le "$KEEP" ] && continue
    rm -f "$DIR/$f" "$DIR/$f.meta"; log "INFO pruned $f (keep $KEEP)"
  done
}

# secs_until <HH:MM> -> seconds from now to the next HH:MM UTC (1..86400)
secs_until() {
  h="${1%%:*}"; m="${1#*:}"
  t=$(( ${h#0} * 3600 + ${m#0} * 60 )); now=$(( $(date -u +%s) % 86400 ))
  d=$(( (t - now + 86400) % 86400 ))
  [ "$d" -gt 0 ] || d=86400
  echo "$d"
}

do_loop() {
  matches '^([01][0-9]|2[0-3]):[0-5][0-9]$' "$AT" || die "BACKUP_AT must be HH:MM (UTC), got '$AT'"
  check_recipient
  while :; do
    s="$(secs_until "$AT")"; log "INFO next backup at $AT UTC, in ${s}s"
    sleep "$s"
    ( do_once ) || log "ERROR backup run failed (above); next try tomorrow at $AT UTC"
  done
}

# pick <name|latest> -> the dump's file name in $DIR
pick() {
  if [ "$1" = latest ]; then f="$(dumps | tail -n 1)"; else f="$(basename "$1")"; fi
  [ -n "$f" ] && [ -f "$DIR/$f" ] || die "no dump '$1' in $DIR"
  [ -f "$DIR/$f.meta" ] || die "no $f.meta: cannot prove the restore"
  echo "$f"
}

do_restore() {
  f="$(pick "${1:-latest}")"
  check_identity
  want="$(sed -n 's/^sha256=//p' "$DIR/$f.meta")"
  [ "$(sha256sum "$DIR/$f" | cut -d' ' -f1)" = "$want" ] || die "$f: sha256 does not match its .meta"
  if [ "${RESTORE_LIVE:-0}" = 1 ]; then
    db="$PGDATABASE"; opts="--clean --if-exists --single-transaction"
  else
    db="${RESTORE_DB:-${PGDATABASE}_restore_$(date -u +%Y%m%d%H%M%S)}"; opts="--no-owner --no-privileges"
    matches '^[a-z_][a-z0-9_]*$' "$db" || die "RESTORE_DB must be [a-z_][a-z0-9_]*, got '$db'"
    [ "$db" != "$PGDATABASE" ] || die "a scratch restore never targets the live $PGDATABASE (RESTORE_LIVE=1 does)"
    createdb "$db" || die "cannot create the scratch DB $db (it must not exist)"
  fi
  # shellcheck disable=SC2086 # opts is a word list on purpose
  age -d -i "$IDF" "$DIR/$f" | pg_restore --exit-on-error $opts -d "$db" || die "restore of $f into $db failed"
  got="$(counts "$db")"
  exp="$(sed -n 's/^tables=//p' "$DIR/$f.meta") $(sed -n 's/^migrations=//p' "$DIR/$f.meta")"
  rc=0
  if [ "$got" = "$exp" ]; then echo "PASS restore $f -> $db: tables migrations = $got (= .meta)"
  else echo "FAIL restore $f -> $db: tables migrations = $got, .meta says $exp"; rc=1; fi
  if [ "${RESTORE_LIVE:-0}" != 1 ] && [ "${RESTORE_KEEP:-0}" != 1 ]; then dropdb "$db" && log "INFO dropped the scratch DB $db"; fi
  return "$rc"
}

do_list() {
  for f in $(dumps); do
    echo "$f $(wc -c <"$DIR/$f") $(sed -n 's/^tables=//p' "$DIR/$f.meta" 2>/dev/null)"
  done
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  once) do_once ;;
  loop) do_loop ;;
  restore) do_restore "$@" ;;
  list) do_list ;;
  keygen) do_keygen "$@" ;;
  *) die "usage: backup.sh once|loop|restore <file|latest>|list|keygen <dir>" ;;
esac
