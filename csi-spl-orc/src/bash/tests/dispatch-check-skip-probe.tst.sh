#!/usr/bin/env bash
# do_spl_dispatch_check (SPL-1648): the hum| read in
# spl-dispatch-subscribe.func.sh leaves #probe out of BOTH counts, the same
# channels the unanswered sweep skips. Hermetic: stubbed message rows and a
# psql that applies the SQL's m.channel NOT IN list. No hub, no prd.
#
# An unsigned #probe row produces no UNSIGNED line. An unsigned #lobby row
# still does. A #probe row beside a #lobby row does not raise either count.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"; fails=0
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

mkdir -p "$T/bin" "$T/spool"
# The real read sends its SQL to psql. This one applies only that SQL's
# m.channel NOT IN list to the stubbed rows (channel<TAB>sig, empty sig =
# unsigned) and prints the hum| line the check judges.
cat >"$T/bin/psql" <<'PSQL'
#!/usr/bin/env bash
sql=$(cat)
python3 - "$sql" "$HUM_ROWS" <<'PY'
import re, sys
sql, path = sys.argv[1], sys.argv[2]
m = re.search(r"m\.channel\s+NOT\s+IN\s*\(([^)]*)\)", sql)
skip = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()
posts = uns = 0
for line in open(path):
    line = line.rstrip("\n")
    if not line:
        continue
    ch, sig = line.split("\t", 1)
    if ch == "" or ch in skip:
        continue
    posts += 1
    if sig == "":
        uns += 1
print(f"hum|{posts}|{uns}")
PY
PSQL
chmod +x "$T/bin/psql"

run() { # rows file already written
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" HUM_ROWS="$T/rows" PATH="$T/bin:$PATH" \
    SPL_PROXY_DSN="postgres://u:p@127.0.0.1:1/db" \
    DISPATCH_ORCH=c-001 DISPATCH_MASTER=c-002 DISPATCH_FAILOVER=c-003 \
    DISPATCH_SILENCE_WINDOW=120 bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-dispatch-subscribe.func.sh"
    data="$(_spl_dispatch_subs_read t1)" || exit 1
    printf "%s\n" "$data"
    spl_dispatch_inbound t1 "$data"' >"$T/o" 2>&1
}

printf 'probe\t\n' >"$T/rows"
run
grep -qx 'hum|0|0' "$T/o" && ! grep -q '^UNSIGNED ' "$T/o" &&
  pass "unsigned #probe row: neither count moves, no UNSIGNED line" ||
  fail "unsigned #probe row counted: $(cat "$T/o")"

printf 'lobby\t\n' >"$T/rows"
run
grep -qx 'hum|1|1' "$T/o" && grep -q '^UNSIGNED t1 1 of 1 human posts ' "$T/o" &&
  pass "CONTROL: unsigned #lobby row still produces the UNSIGNED line" ||
  fail "unsigned #lobby row did not: $(cat "$T/o")"

printf 'probe\t\nlobby\t\n' >"$T/rows"
run
grep -qx 'hum|1|1' "$T/o" && grep -q '^UNSIGNED t1 1 of 1 human posts ' "$T/o" &&
  pass "unsigned #probe beside #lobby: both counts stay 1 of 1" ||
  fail "#probe changed a count: $(cat "$T/o")"

echo "---"; (( fails == 0 )) && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
