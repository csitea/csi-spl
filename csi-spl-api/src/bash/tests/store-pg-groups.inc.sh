# shellcheck shell=bash disable=SC2034 # the variables are read by the files that source it
# The internal/store Postgres run, split into SEQUENTIAL go test processes
# (hub-pg.tst.sh runs them one after another, each with its own -timeout).
# As one process it hit the 20m GO_TEST_TIMEOUT under runner load (job
# 114504882724, TestWriteBatchRoundTrips): breadth, not a hang. A group is a
# -run range of test names plus a -skip, balanced by measured wall times; the
# last group's range is open-ended, so a new test lands in exactly one group.
# store-pg-groups.tst.sh proves every `go test -list` test runs in exactly one
# process (none lost, none twice) and that a dropped group goes red.
# Measured 2026-10-11 (docker pg16 as here, -race, wsdoc skipped, n = 2,
# wall from a test's run to its end: a parent's Elapsed leaves out its
# parallel subtests): the process took 352 s at load 14 and 509 s at load 37
# (16 cores); per group a 85/130 s, b 109/147, c 75/127, d 82/104, the largest
# 31 % of the run. CI ran the same process 973 s green (job 114494439276) and
# >1200 s red, so a group is ~400 s there: under half of 20m.

# spec 113's workspace-doc suites: their own process (wsdoc), skipped by every group.
STORE_PG_WSDOC='^TestWorkspaceDoc'
# The two heaviest TopicHead tests (43..81 s and 32..46 s) get their own group.
STORE_PG_TOPIC_HEAD_HEAVY='^TestTopicHead(Cases|RandomSequences)$'

# The groups hub-pg.tst.sh runs, in this order.
STORE_PG_GROUPS=(a b c d)

store_pg_group_run() { # <group>: its -run regexp (top-level test names)
  case "$1" in
    a) echo '^Test[A-M]' ;;
    b) echo '^Test[N-S]' ;;
    c) echo "$STORE_PG_TOPIC_HEAD_HEAVY" ;;
    d) echo '^Test($|[^A-S])' ;;
    *) echo "store_pg_group_run: unknown group '$1'" >&2; return 2 ;;
  esac
}

store_pg_group_skip() { # <group>: its -skip regexp
  case "$1" in
    a|b|c) echo "$STORE_PG_WSDOC" ;;
    d) echo "$STORE_PG_WSDOC|$STORE_PG_TOPIC_HEAD_HEAVY" ;;
    *) echo "store_pg_group_skip: unknown group '$1'" >&2; return 2 ;;
  esac
}
