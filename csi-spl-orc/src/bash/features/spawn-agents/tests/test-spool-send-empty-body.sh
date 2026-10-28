#!/usr/bin/env bash
# spool-send.sh refuses an empty or whitespace-only body (SPL-3953): review
# seats sent `--kind result --body "$(cat review-report.md)"` while the file
# was never written; $(cat ...) expanded to '' and the receiver got nothing
# (6 messages from 2 seats, 2026-10-27). Every kind is refused, exit 2,
# before anything is written to any inbox or outbox; --body-file of an empty
# or missing file likewise. Hermetic: own SPOOL_ROOT, no hub, no poke.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
jsons() { find "$SPOOL_ROOT" -name '*.json' -newer "$T_TMP/mark" 2>/dev/null | wc -l; }

printf 'c-782\tclaude\t%%0\t/x\t20260101T000000Z\n' >>"$SPOOL_ROOT/registry.tsv"
mkdir -p "$SPOOL_ROOT/c-782/inbox"

# ---- red control: an empty body, the $(cat <missing file>) case ------------
: >"$T_TMP/mark"
err="$(bash "$SS" --from c-781 --to c-782 --kind result --body "" --no-poke 2>&1 >/dev/null)"; rc=$?
eq "--kind result --body '': refused, exit 2" 2 "$rc"
has "…the line names the cause" "the body is empty: if it came from \$(cat FILE), FILE is missing or empty; nothing was sent" "$err"
eq "…nothing written to any inbox or outbox" 0 "$(jsons)"
check "…no outbox for the sender" test ! -d "$SPOOL_ROOT/c-781/outbox"

for b in "   " "$(printf ' \n\t \n')"; do
  bash "$SS" --from c-781 --to c-782 --kind result --body "$b" --no-poke >/dev/null 2>&1; rc=$?
  eq "a whitespace-only body ($(printf '%q' "$b")): refused, exit 2" 2 "$rc"
done
for k in task note reject blocker msg; do
  bash "$SS" --from c-781 --to c-782 --kind "$k" --body "" --no-poke --no-ask >/dev/null 2>&1
  eq "--kind $k with an empty body: refused, exit 2" 2 "$?"
done
eq "…none of them wrote a message" 0 "$(jsons)"

# ---- the file form ----------------------------------------------------------
: >"$T_TMP/empty.md"
err="$(bash "$SS" --from c-781 --to c-782 --kind result --body-file "$T_TMP/empty.md" --no-poke 2>&1 >/dev/null)"; rc=$?
eq "--body-file of an empty file: refused, exit 2" 2 "$rc"
has "…with the same line" "the body is empty" "$err"
err="$(bash "$SS" --from c-781 --to c-782 --kind result --body-file "$T_TMP/never-written.md" --no-poke 2>&1 >/dev/null)"; rc=$?
eq "--body-file of a missing file: an error, exit 2" 2 "$rc"
has "…naming the file" "cannot read --body-file $T_TMP/never-written.md" "$err"
eq "…still nothing written" 0 "$(jsons)"

# ---- a real body still goes ------------------------------------------------
bash "$SS" --from c-781 --to c-782 --kind result --body " review: 3 findings " --no-poke >/dev/null 2>&1
eq "a body with text (and edge spaces): sent, exit 0" 0 "$?"
printf 'review: ok\n' >"$T_TMP/report.md"
bash "$SS" --from c-781 --to c-782 --kind result --body-file "$T_TMP/report.md" --no-poke >/dev/null 2>&1
eq "--body-file of a written file: sent, exit 0" 0 "$?"
eq "…both delivered" 2 "$(find "$SPOOL_ROOT/c-782/inbox" -maxdepth 1 -name '*.json' | wc -l)"

t_done
