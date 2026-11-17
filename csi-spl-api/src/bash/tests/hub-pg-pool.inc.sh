# shellcheck shell=bash
# p14-02 (SPL-5819): one pool of slots that the store and the hub Postgres
# groups of hub-pg.tst.sh share, so the two lists run side by side up to one
# cap (HUB_PG_GROUP_JOBS) instead of one after another within each chain.
# Since SPL-5654 every group has its own freshly migrated database, so the
# one-at-a-time order protected nothing; the database setup itself stays one
# at a time (db_lock in hub-pg.tst.sh). A slot is a token in a FIFO opened
# read-write before the chains fork: a group takes one before it starts and
# gives it back when it ends, however it ends (the EXIT trap).
# hub-pg-pool.tst.sh proves the peak number running at once is the cap, every
# group runs exactly once, and a red group still fails the gate by its name.

pg_pool_open() { # <dir> <cap>: the token pool the store and hub chains share
  local dir="$1" cap="$2" i
  case "$cap" in
    '' | *[!0-9]* | 0*) echo "HUB_PG_GROUP_JOBS must be a whole number >= 1 (got '$cap')" >&2; return 2 ;;
  esac
  mkfifo "$dir/pg-group-pool.fifo"
  exec {PG_POOL_FD}<>"$dir/pg-group-pool.fifo"
  for ((i = 0; i < cap; i++)); do echo t >&"$PG_POOL_FD"; done
  PG_POOL_PIDS=()
}

pg_pool_run() { # <cmd...>: wait for a free slot, then run cmd in the background holding it
  read -r -u "$PG_POOL_FD" _
  # shellcheck disable=SC2064 # the fd is fixed once the pool is open
  ( trap "echo t >&$PG_POOL_FD" EXIT; "$@" ) &
  PG_POOL_PIDS+=("$!")
}

pg_pool_wait() { # every job this shell started; 1 if any of them failed
  local p rc=0
  for p in "${PG_POOL_PIDS[@]}"; do wait "$p" || rc=1; done
  PG_POOL_PIDS=()
  return "$rc"
}
