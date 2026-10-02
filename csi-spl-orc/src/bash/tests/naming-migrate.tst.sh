#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_naming_migrate (specs/058 section 6, CLE-77924): the move of
#          this machine's mailboxes $SPOOL_ROOT/<ID> -> <ID>@<box> + the compat
#          link <ID>, on a throwaway root (never the live one).
#   1. DRY_RUN (the default) touches nothing; box-desk and a bad box are
#      refused; a forward run refuses a spool that cannot answer `layout`
#   2. RUNNING-AGENT SIMULATION: writers keep delivering by the BARE path
#      (mkdir -p + tmp + rename, the spool binary's write) and a reader keeps
#      listing, while the migration runs. Every message lands in <ID>@<box>,
#      no writer or reader errors, no orphan <ID> dir, no tmp left over; the
#      role ids go last (003, 002, 001)
#   3. a re-run is a no-op; ROLLBACK=1 restores <ID> dirs with every message;
#      a rollback re-run is a no-op; then a forward run again (reversible)
#   4. a self-loop left by a killed run is finished; a conflicting <ID>@<box>
#      dir is reported and left alone (exit 1, nothing else blocked)
#   5. the id set changing during a run rolls back that run's moves
#   6. CONTROL: a plain mv + ln -s with one delivery in its gap leaves an
#      orphan <ID> dir holding the message, so the reader of <ID>@<box> never
#      sees it. The same delivery after the action's exchange lands in the one
#      dir
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }

R="$T/spool"
mkdir -p "$T/bin" "$R/agents" "$R/dispatch"
printf '#!/bin/sh\n[ "$1" = layout ] || exit 1\n' >"$T/bin/spool-new"
printf '#!/bin/sh\necho "unknown command \\"$1\\"" >&2; exit 1\n' >"$T/bin/spool-old"
chmod +x "$T/bin/"*
AGENTS="CLE-001 CLE-002 CLE-003 CLE-10 CLE-11 CLE-12 GRK-20 AGY-21 QWN-22"
for a in $AGENTS; do
  mkdir -p "$R/$a/inbox" "$R/$a/outbox" "$R/$a/archive"
  echo '{}' >"$R/$a/inbox/old-1.json"
done
printf 'CLE-10\tclaude\t%%1\t/x\t20261002T000000Z\n' >"$R/registry.tsv"
echo '{}' >"$R/agents/CLE-10.json"

mig() { # VAR=value... -> runs the action on $R
  SNIPPET='do_spl_naming_migrate' in_orc SPOOL_ROOT="$R" NAMING_BOX=hom SPOOL_BIN="$T/bin/spool-new" "$@"
}
tree() { (cd "$R" && find . -printf '%p %y %l\n' | sort); }
count() { find -L "$R/$1/inbox" -maxdepth 1 -type f -name '*.json' | wc -l; }

# 1 --------------------------------------------------------------------------
t0="$(tree)"
out="$(mig 2>&1)"
[[ "$(tree)" == "$t0" ]] && pass "1 dry run touches nothing" || fail "1 dry run changed the root"
grep -q 'would move CLE-10 to CLE-10@hom' <<<"$out" && pass "1 dry run prints the plan" || fail "1 no plan: $out"
mig NAMING_BOX=box-desk DRY_RUN=0 >/dev/null 2>&1 && fail "1 box-desk accepted" || pass "1 box-desk refused (rename once, to the machine's own box)"
mig NAMING_BOX=Bad_Box >/dev/null 2>&1 && fail "1 bad box accepted" || pass "1 a non-box id refused"
out="$(mig SPOOL_BIN="$T/bin/spool-old" DRY_RUN=0 2>&1)"
[[ $? -ne 0 && "$(tree)" == "$t0" ]] && pass "1 an old spool (no 'layout') refuses the forward run, nothing moved" || fail "1 old spool gate: $out"
mig SPOOL_TEST=1 SPOOL_LIVE_ROOT="$R" DRY_RUN=0 >/dev/null 2>&1 && fail "1 test guard missed the live root" || pass "1 SPOOL_TEST=1 refuses the live root"

# 2 --------------------------------------------------------------------------
N=600
WRITERS="CLE-001 CLE-002 CLE-10 GRK-20 QWN-22"
wpids=()
for a in $WRITERS; do
  ( errs=0
    for i in $(seq 1 "$N"); do
      mkdir -p "$R/$a/inbox" || errs=$((errs + 1))
      tmp="$(mktemp "$R/$a/inbox/.tmp-XXXXXX")" || { errs=$((errs + 1)); continue; }
      echo "{\"i\":$i}" >"$tmp" && mv -f "$tmp" "$R/$a/inbox/live-$i.json" || errs=$((errs + 1))
    done
    echo "$errs" >"$T/werr.$a" ) &
  wpids+=("$!")
done
( errs=0; while [ ! -e "$T/stop" ]; do
    for a in $WRITERS; do ls "$R/$a/inbox" >/dev/null 2>&1 || errs=$((errs + 1)); done
  done; echo "$errs" >"$T/rerr" ) &
reader=$!
sleep 0.2
mig DRY_RUN=0 >"$T/run1.log" 2>&1; rc=$?
live=0; for a in $WRITERS; do [ -e "$T/werr.$a" ] || live=$((live + 1)); done
wait "${wpids[@]}"
touch "$T/stop"; wait "$reader"
[[ $rc -eq 0 ]] && pass "2 the migration ran while agents wrote (exit 0)" || fail "2 migration exit $rc: $(cat "$T/run1.log")"
[[ $live -gt 0 ]] && pass "2 the writers were still delivering when the move ended ($live of 5): a real overlap" || fail "2 no overlap: the writers finished before the move"
werr=0; for a in $WRITERS; do werr=$((werr + $(cat "$T/werr.$a"))); done
[[ $werr -eq 0 && "$(cat "$T/rerr")" -eq 0 ]] && pass "2 no writer or reader saw an error" || fail "2 errors: writers $werr, reader $(cat "$T/rerr")"
lost=0
for a in $WRITERS; do
  n="$(find "$R/$a@hom/inbox" -maxdepth 1 -name 'live-*.json' | wc -l)"
  [[ "$n" -eq "$N" ]] || { lost=1; echo "  $a@hom/inbox holds $n of $N"; }
done
[[ $lost -eq 0 ]] && pass "2 every message of $((N * 5)) is in <ID>@hom/inbox (zero lost)" || fail "2 messages lost"
bad=0
for a in $AGENTS; do
  [[ -L "$R/$a" && "$(readlink "$R/$a")" == "$a@hom" && -d "$R/$a@hom" && ! -L "$R/$a@hom" ]] || { bad=1; echo "  $a: $(ls -ld "$R/$a" "$R/$a@hom" 2>&1)"; }
done
[[ $bad -eq 0 ]] && pass "2 every mailbox is <ID>@hom + the link <ID>; no orphan <ID> dir" || fail "2 layout wrong"
[[ -z "$(find "$R" -name '.tmp-*')" ]] && pass "2 no tmp file left behind" || fail "2 tmp files left"
order="$(grep -oE 'OK [A-Z]+-[0-9]+ ->' "$T/run1.log" | awk '{print $2}' | tail -3 | tr '\n' ' ')"
[[ "$order" == "CLE-003 CLE-002 CLE-001 " ]] && pass "2 the role ids move last: 003, 002, 001" || fail "2 order: $order"
[[ -f "$R/agents/CLE-10.json" && ! -L "$R/agents/CLE-10.json" && -f "$R/registry.tsv" ]] && pass "2 identity map and registry untouched" || fail "2 agents/ or registry changed"

# 3 --------------------------------------------------------------------------
t1="$(tree)"
out="$(mig DRY_RUN=0 2>&1)"
[[ "$(tree)" == "$t1" ]] && grep -q '"moved":0' <<<"$out" && pass "3 a re-run is a no-op" || fail "3 re-run changed something: $out"
mig ROLLBACK=1 DRY_RUN=0 >"$T/rb.log" 2>&1; rc=$?
ok=$rc
for a in $AGENTS; do [[ -d "$R/$a" && ! -L "$R/$a" && ! -e "$R/$a@hom" && ! -L "$R/$a@hom" ]] || ok=1; done
[[ $ok -eq 0 ]] && pass "3 ROLLBACK restores the <ID> dirs, no <ID>@hom left" || fail "3 rollback: $(cat "$T/rb.log")"
[[ "$(count CLE-10)" -eq $((N + 1)) && "$(count CLE-003)" -eq 1 ]] && pass "3 ...with every message" || fail "3 rollback lost messages ($(count CLE-10))"
t2="$(tree)"
mig ROLLBACK=1 DRY_RUN=0 >/dev/null 2>&1
[[ "$(tree)" == "$t2" ]] && pass "3 a rollback re-run is a no-op" || fail "3 rollback re-run changed something"
mig DRY_RUN=0 >/dev/null 2>&1 && [[ -L "$R/CLE-10" && "$(count CLE-10@hom)" -eq $((N + 1)) ]] && pass "3 forward again after a rollback (reversible)" || fail "3 forward after rollback"

# 4 --------------------------------------------------------------------------
mkdir -p "$R/CLE-30/inbox"; echo '{}' >"$R/CLE-30/inbox/a.json"; ln -s CLE-30@hom "$R/CLE-30@hom"
mkdir -p "$R/CLE-31/inbox" "$R/CLE-31@hom/inbox"
out="$(mig DRY_RUN=0 2>&1)"; rc=$?
[[ -L "$R/CLE-30" && -d "$R/CLE-30@hom" && "$(count CLE-30)" -eq 1 ]] && pass "4 a killed run's self-loop is finished" || fail "4 self-loop: $out"
[[ $rc -ne 0 && -d "$R/CLE-31" && ! -L "$R/CLE-31" && -d "$R/CLE-31@hom" ]] && grep -q 'CLE-31.*left as it is' <<<"$out" &&
  pass "4 a conflicting <ID>@hom dir is reported and left alone (exit $rc)" || fail "4 conflict: rc=$rc $out"
rm -rf "$R/CLE-31@hom"

# 5 --------------------------------------------------------------------------
mkdir -p "$R/CLE-40/inbox"
SNIPPET='n=0; _spl_naming_scan() { n=$((n + 1)); [ $n -eq 1 ] && echo CLE-40 || echo CLE-40 CLE-99; }; do_spl_naming_migrate' \
  in_orc SPOOL_ROOT="$R" NAMING_BOX=hom SPOOL_BIN="$T/bin/spool-new" ONLY="CLE-40" DRY_RUN=0 >"$T/r5.log" 2>&1; rc=$?
[[ $rc -ne 0 && -d "$R/CLE-40" && ! -L "$R/CLE-40" && ! -e "$R/CLE-40@hom" ]] && pass "5 a changed id set rolls this run's moves back" || fail "5 $(cat "$T/r5.log")"

# 6 --------------------------------------------------------------------------
C="$T/ctl"; mkdir -p "$C/CLE-50/inbox" "$C/CLE-51/inbox"
deliver() { mkdir -p "$1/inbox" && echo '{}' >"$1/inbox/gap.json"; }
mv "$C/CLE-50" "$C/CLE-50@hom"; deliver "$C/CLE-50"; ln -s CLE-50@hom "$C/CLE-50" 2>/dev/null
if [[ -d "$C/CLE-50" && ! -L "$C/CLE-50" && ! -e "$C/CLE-50@hom/inbox/gap.json" ]]; then
  pass "6 CONTROL: mv + ln -s with a delivery in the gap leaves an orphan CLE-50 dir; CLE-50@hom never gets the message"
else
  fail "6 control did not show the gap"
fi
SNIPPET='do_spl_naming_migrate' in_orc SPOOL_ROOT="$C" NAMING_BOX=hom SPOOL_BIN="$T/bin/spool-new" ONLY=CLE-51 DRY_RUN=0 >/dev/null 2>&1
deliver "$C/CLE-51"
[[ -L "$C/CLE-51" && -f "$C/CLE-51@hom/inbox/gap.json" ]] && pass "6 the same delivery after the exchange lands in CLE-51@hom" || fail "6 exchange delivery"

[[ $fails -eq 0 ]] && echo "naming-migrate.tst.sh: all passed" || echo "naming-migrate.tst.sh: $fails failed"
exit $((fails > 0))
