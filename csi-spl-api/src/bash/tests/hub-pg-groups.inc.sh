# shellcheck shell=bash disable=SC2034 # the variables are read by the files that source it
# The internal/hub Postgres run, split into SEQUENTIAL go test processes
# (hub-pg.tst.sh runs them one after another, each with its own -timeout), the
# shape of store-pg-groups.inc.sh. As one process it took 1038 s of the 20m
# GO_TEST_TIMEOUT in red job 114504882724 (816 s and 900 s green in jobs
# 114633083898, 114642216718): breadth, not a hang. A group is a -run range of
# top-level names, balanced by measured wall times; the last group's range is
# open-ended (and takes the Fuzz seed corpora), so a new test lands in exactly
# one group. hub-pg-groups.tst.sh proves every `go test -list` test runs in
# exactly one process (none lost, none twice) and that a dropped group goes red.
# Measured 2026-10-12 (docker pg16, -race, GOMAXPROCS=8 of 16 cores, n = 2,
# wall from a test's run/cont to its end): 671 tests, none over 6 s, the
# process 198 s at load 32 and 213 s at load 16; per group a 49/50 s,
# b 52/56, c 49/57, d 48/50, the largest 27 % of the run, so ~280 s of the
# 20m at CI's worst 1038 s.

# The groups hub-pg.tst.sh runs, in this order.
HUB_PG_GROUPS=(a b c d)

hub_pg_group_run() { # <group>: its -run regexp (top-level test names)
  case "$1" in
    a) echo '^Test[A-C]' ;;
    b) echo '^Test[D-L]' ;;
    c) echo '^Test[M-S]' ;;
    d) echo '^(Test($|[^A-S])|Fuzz|Example)' ;;
    *) echo "hub_pg_group_run: unknown group '$1'" >&2; return 2 ;;
  esac
}
