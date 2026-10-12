#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The host port of an orc test's throwaway Postgres, or a stop (CI topic
# f67e3656). The pg tests start one with `docker run ... -p 127.0.0.1::5432`
# and read the mapped port with `docker port`. When the container did not
# start, that read is empty, the DSN falls through to 127.0.0.1:5432, and the
# test fails much later on a misleading auth error (run 38214878587:
# "password authentication failed for user spool" -> "FAIL: migrate", the
# real cause a port bind error). Source it and read the port with:
#   source "$HERE/pg-throwaway.inc.sh"
#   PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
# Self-contained, unlike test-lib.inc.sh: most pg tests keep their own T and
# EXIT trap (it removes the container), which test-lib.inc.sh would replace.
# Test: pg-throwaway-port.tst.sh.
#------------------------------------------------------------------------------

# pg_throwaway_port <container> - the host port mapped to the container's 5432
# on stdout. A container that is not running or an empty or non-numeric port
# prints one FAIL line on stderr and returns 1, before any DSN is built.
pg_throwaway_port() {
  local ctr="$1" running port
  running="$(docker inspect -f '{{.State.Running}}' "$ctr" 2>/dev/null)"
  port="$(docker port "$ctr" 5432 2>/dev/null | sed -n 1p | sed 's/.*://')"
  if [[ "$running" != true || ! "$port" =~ ^[0-9]+$ ]]; then
    echo "FAIL: throwaway postgres did not start: $ctr running=${running:-<none>} port=${port:-<empty>}" >&2
    return 1
  fi
  echo "$port"
}
