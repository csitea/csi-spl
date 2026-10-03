#!/usr/bin/env bash
# spool-send.sh, one topic per lane (token/focus practice 08): a task on a
# second topic to a lane that owns one is refused (exit 3, nothing sent),
# SPOOL_SECOND_TOPIC_OK=1 overrides and is logged, role seats are exempt, and
# a long body WARNs but still sends.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
n_inbox() { find "$SPOOL_ROOT/$1/inbox" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }
tid() { sed -n 's/.*"task_id" *: *"\([^"]*\)".*/\1/p'; }

for id in CLE-81 CLE-82 CLE-001 CLE-85; do
  printf '%s\tclaude\t%%0\t/x\t20260101T000000Z\n' "$id" >> "$SPOOL_ROOT/registry.tsv"
done

# ---- the first task gives the lane its topic --------------------------------
T1="$(bash "$SS" --from CLE-80 --to CLE-81 --kind task --body one --no-poke | tid)"
check "the first task mints the lane's topic" test -n "$T1"

# ---- refuse: a task on another topic ---------------------------------------
err="$(bash "$SS" --from CLE-80 --to CLE-81 --kind task --body two --no-poke 2>&1 >/dev/null)"; rc=$?
eq "a task on a new topic: refused, exit 3" 3 "$rc"
has "the refusal names the owned topic" "that lane owns topic ${T1}; spawn a new lane" "$err"
eq "…and nothing was sent" 1 "$(n_inbox CLE-81)"
bash "$SS" --from CLE-80 --to CLE-81 --kind task --task 11111111-2222-4333-8444-555555555555 --body two --no-poke >/dev/null 2>&1
eq "an explicit other --task: refused, exit 3" 3 "$?"

# ---- same topic, and the non-task kinds, pass -------------------------------
bash "$SS" --from CLE-80 --to CLE-81 --kind task --task "$T1" --body more --no-poke >/dev/null 2>&1
eq "a task on the lane's own topic: exit 0" 0 "$?"
bash "$SS" --from CLE-80 --to CLE-81 --kind note --body fyi --no-poke >/dev/null 2>&1
eq "a note on a new topic is not a task: exit 0" 0 "$?"

# ---- override: SPOOL_SECOND_TOPIC_OK=1 sends and logs -----------------------
err="$(SPOOL_SECOND_TOPIC_OK=1 bash "$SS" --from CLE-80 --to CLE-81 --kind task --body forced --no-poke 2>&1 >/dev/null)"; rc=$?
eq "SPOOL_SECOND_TOPIC_OK=1: sent, exit 0" 0 "$rc"
has "the override WARNs" "SPOOL_SECOND_TOPIC_OK=1" "$err"
has "the override is logged" "$(printf 'CLE-80\tCLE-81\t%s\tnew' "$T1")" "$(cat "$SPOOL_ROOT/second-topic.log" 2>/dev/null)"

# ---- a reused id starts clean: only tasks since its registry row count ------
printf 'CLE-81\tclaude\t%%0\t/x\t20991231T000000Z\n' >> "$SPOOL_ROOT/registry.tsv"
bash "$SS" --from CLE-80 --to CLE-81 --kind task --body respawned --no-poke >/dev/null 2>&1
eq "a respawned id owns no topic from before its spawn: exit 0" 0 "$?"

# ---- role seats are exempt ---------------------------------------------------
bash "$SS" --from CLE-80 --to CLE-001 --kind task --body a --no-poke >/dev/null 2>&1
bash "$SS" --from CLE-80 --to CLE-001 --kind task --body b --no-poke >/dev/null 2>&1
eq "role seat 001 takes a second topic: exit 0" 0 "$?"
mkdir -p "$SPOOL_ROOT/dispatch"; echo 'LEASE_ORCH=CLE-85' > "$SPOOL_ROOT/dispatch/lease.conf"
bash "$SS" --from CLE-80 --to CLE-85 --kind task --body a --no-poke >/dev/null 2>&1
bash "$SS" --from CLE-80 --to CLE-85 --kind task --body b --no-poke >/dev/null 2>&1
eq "the lease.conf orch seat takes a second topic: exit 0" 0 "$?"

# ---- a long body WARNs and still sends --------------------------------------
long="$(printf 'x%.0s' $(seq 1 1300))"
err="$(bash "$SS" --from CLE-80 --to CLE-82 --kind note --body "$long" --no-poke 2>&1 >/dev/null)"; rc=$?
eq "a 1300-char body: sent, exit 0" 0 "$rc"
has "…with a WARN to send a path" "put the detail in a file and send the path" "$err"
eq "…and it was delivered" 1 "$(n_inbox CLE-82)"
err="$(bash "$SS" --from CLE-80 --to CLE-82 --kind note --body short --no-poke 2>&1 >/dev/null)"
hasnt "a short body does not WARN" "send the path" "$err"

t_done
