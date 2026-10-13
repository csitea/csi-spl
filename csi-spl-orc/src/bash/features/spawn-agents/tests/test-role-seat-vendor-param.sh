#!/usr/bin/env bash
# test-role-seat-vendor-param.sh — SPL-1695 (owner HUM-10): "Keep the
# hardcoded 001, 002 and 003 numbers. The vendor letter (c, g, and a when that
# vendor is seated) is a parameter and can be switched." spl_role_vendor reads
# the parameter (SPL_ROLE_VENDOR > ROTATE_ROLE_VENDOR > rotate.conf > claude),
# spl_role_seat N the live id of seat N (lease.conf first), and no default
# under csi-spl-orc/src still names a role seat by a fixed letter.
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
t_sandbox
. "$T_FEAT/lib/spool-env.inc.sh"
unset SPL_ROLE_VENDOR ROTATE_ROLE_VENDOR LEASE_ORCH LEASE_MASTER LEASE_FAILOVER LEASE_CONF LEASE_DIR SPOOL_ORCHESTRATOR_ID
D="$SPOOL_ROOT/dispatch"; mkdir -p "$D"

nope() { ! "$@" 2>/dev/null; }

# 1. the parameter: default claude, rotate.conf, then the environment
eq "1. no rotate.conf = claude" claude "$(spl_role_vendor)"
printf 'ROTATE_ORCH_SPLIT=1\nROTATE_ROLE_VENDOR=grok\n' >"$D/rotate.conf"
eq "1. rotate.conf ROTATE_ROLE_VENDOR=grok" grok "$(spl_role_vendor)"
eq "1. ROTATE_ROLE_VENDOR env beats rotate.conf" agy "$(ROTATE_ROLE_VENDOR=agy spl_role_vendor)"
eq "1. SPL_ROLE_VENDOR beats both" claude "$(SPL_ROLE_VENDOR=claude ROTATE_ROLE_VENDOR=agy spl_role_vendor)"
eq "1. an unknown vendor = claude" claude "$(SPL_ROLE_VENDOR=x spl_role_vendor)"
eq "1. LEASE_DIR names the conf dir" claude "$(LEASE_DIR="$T_TMP/none" spl_role_vendor)"

# 2. the seat ids follow it, the numbers stay
eq "2. grok seats, no lease.conf" "g-001 g-002 g-003" "$(spl_role_seat 1) $(spl_role_seat 2) $(spl_role_seat 3)"
eq "2. switched back" "c-001 c-002 c-003" "$(export SPL_ROLE_VENDOR=claude; spl_role_seat 1) $(SPL_ROLE_VENDOR=claude spl_role_seat 002) $(SPL_ROLE_VENDOR=claude spl_role_seat 3)"
for n in 0 4 x ''; do check "2. no seat '$n'" nope spl_role_seat "$n"; done

# 3. lease.conf (the seat switch flips it) wins over the parameter: a grok
# switch that fell back to claude leaves c-00N live
printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-004\nLEASE_ORCH=g-001@sat\n' >"$D/lease.conf"
eq "3. lease.conf orch (box dropped)" g-001 "$(spl_role_seat 1)"
eq "3. lease.conf master c-002 under grok" c-002 "$(spl_role_seat 2)"
eq "3. a lease id of another number = the parameter" g-003 "$(spl_role_seat 3)"
eq "3. LEASE_ORCH env beats lease.conf" a-001 "$(LEASE_ORCH=a-001 spl_role_seat 1)"
eq "3. LEASE_CONF names the file" g-002 "$(LEASE_CONF="$T_TMP/none.conf" spl_role_seat 2)"
rm -f "$D/lease.conf"

# 4. the defaults that said c-00N: SPOOL_ORCHESTRATOR_ID, a run action's
eq "4. SPOOL_ORCHESTRATOR_ID default" g-001 "$(unset SPOOL_ORCHESTRATOR_ID; spool_env_resolve; echo "$SPOOL_ORCHESTRATOR_ID")"
eq "4. CONTROL: SPOOL_ORCHESTRATOR_ID set" c-009 "$(SPOOL_ORCHESTRATOR_ID=c-009; spool_env_resolve; echo "$SPOOL_ORCHESTRATOR_ID")"
RUN="$(cd "$T_FEAT/../../run" && pwd)"
got="$(
  # shellcheck source=/dev/null
  . "$RUN/spl-dispatch-tick.func.sh"
  # shellcheck disable=SC2034 # LH / LT are read by the sourced holder
  spl_lease_read() { LH=none LT=0; }; spl_lease_remote() { return 1; }
  _spl_dispatch_tick_holder
)"
eq "4. dispatch tick holder, no lease" g-001 "$got"
got="$(
  # shellcheck source=/dev/null
  . "$RUN/spl-asks-tick.func.sh"
  spl_asks_alert_who() { :; }; spl_asks_alert() { printf '%s' "$3"; }
  ASKS_OWNER_MIN=1 spl_asks_fallback_alert c-001 '[{"state":"open","ask_id":"abcdef0123","from":"c-400","age_s":600,"created_at":"","summary":"s"}]' ""
)"
has "4. asks alert names the live seats" "wake a DO seat (g-001/g-002/g-003)" "$got"

# 5. no default under csi-spl-orc/src names a role seat by a fixed letter
# (tests and comments exempt)
src="$(cd "$T_FEAT/../.." && pwd)"
fixed="$(grep -rnE ':[-=]c-00[1-3]\}|\|\| *[a-z_]+=c-00[1-3]$|c-001 c-002 c-003|c-001/c-002/c-003' "$src" --include='*.sh' 2>/dev/null |
  grep -vE '/tests?/|\.tst\.sh:' | grep -vE '^[^:]+:[0-9]+: *#' || true)"
eq "5. no fixed-letter role seat default" "" "$fixed"
t_done
