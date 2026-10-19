#!/bin/bash
#------------------------------------------------------------------------------
# @description RETIRED (SPL-2544): a no-op that prints one line pointing to
# @description the new path. SPL-2532 kept separate STANDBY role seats (g-001,
# @description a-001, g-002, ...) live for the lease's vendor fallback. A role
# @description seat has ONE real spool dir and its other letters are links to
# @description it (role-seat-switch.sh, SPL-1685), so a standby start wrote over
# @description a claude seat's prompt (2026-10-19 09:5xZ) and, refused since
# @description SPL-2541, none of the 6 default ids could start. The failover now
# @description switches the role's own seat to the next vendor IN PLACE:
# @description do_spl_role_failover (spl-role-failover.func.sh), launched by the
# @description fleet lease (spl_fleet_switch_tick). Every ROLE_FALLBACK_CMD
# @description (up, cron, enable, disable) starts, stops and writes nothing.
# @param ROLE_FALLBACK_CMD (optional) - ignored
# @example ./run -a do_spl_role_fallback_up
#------------------------------------------------------------------------------

do_spl_role_fallback_up() {
  echo "SKIP role fallback: retired (SPL-2544), no standby seat is started; a role seat that cannot act switches vendor in place: do_spl_role_failover (spl-role-failover.func.sh, launched by the fleet lease)"
  return 0
}
