#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the lease's tenant copies reach the desks that moved to the desk user
# (spec 069, SPL-5120). spl_fleet_mirror_tenants walked only the roots the
# caller can enter, so a box user's loop served no moved tenant. Sandbox: caller
# A (this user), desk user B, B's cloud root chmod 000 except inside the hop.
#   1. tenants pinned under B's 0700 root are served, through the hop
#   2. t1 (the lease tenant), a test workspace, an empty pin and another box's
#      pin are not; a tenant in both roots is listed once
#   3. no sudo rule, or a hop that hangs: the caller's own tenants only, in
#      time, the root named in the log once until it lists again
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
OA="$(basename "$PROJ_ROOT" | sed 's/-orc$//')"
ME="$(id -un)" DU=t-desk-user
HA="$T/home-a" HB="$T/home-b"
RA="$HA/.local/share/$OA/cloud/prd" RB="$HB/.local/share/$OA/cloud/prd"
if [[ "$(id -u)" == 0 ]]; then echo "SKIP: root enters a chmod 000 root"; exit 0; fi
mkdir -p "$T/stub" "$T/spool/dispatch"
cat >"$T/stub/getent" <<STUB
#!/bin/sh
[ "\$1" = passwd ] || exit 2
case "\$2" in
  $ME) echo "$ME:x:5001:5001::$HA:/bin/sh" ;;
  $DU) echo "$DU:x:5002:5002::$HB:/bin/sh" ;;
  *) exit 2 ;;
esac
STUB
cat >"$T/stub/as" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "$DU" && "\$2" == -- ]] || exit 1
shift 2
chmod 700 "$RB"; "\$@"; rc=\$?; chmod 000 "$RB"; exit \$rc
STUB
printf '#!/bin/sh\nexit 1\n' >"$T/stub/as-refused"
printf '#!/bin/sh\nexec sleep 20\n' >"$T/stub/as-hang"
chmod +x "$T/stub/"*
printf 'SPOOL_AGENT_USER=%s\n' "$DU" >"$T/box.env"

pin() { mkdir -p "$1/desk/$2/$3"; echo "$4" >"$1/desk/$2/$3/pinned"; }
mkdir -p "$RA/desk" "$RB/desk"
pin "$RA" t1 sat pinned
pin "$RA" own-a sat pinned
pin "$RA" both sat pinned
pin "$RB" both sat pinned
pin "$RB" csitea sat pinned
pin "$RB" ws-b sat pinned
pin "$RB" t1 sat-rsp pinned
pin "$RB" other other-box pinned
pin "$RB" acme-proof sat pinned
mkdir -p "$RB/desk/empty/sat"; : >"$RB/desk/empty/sat/pinned"
chmod 000 "$RB"

tenants() {
  env -u SPOOL_DESK_USER -u SPOOL_AGENT_USER -u SPOOL_BOX_USER -u LEASE_MIRROR_TENANTS \
    PATH="$T/stub:$PATH" HOME="$HA" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_ORG_APP="$OA" ENV=prd \
    SPL_STATE_DIR="$RA" SPL_DESK_AS_CMD="$1" SPOOL_BOX_ENV="$T/box.env" LEASE_HOP_TIMEOUT=1 \
    LEASE_ENV=prd LEASE_TENANT=t1 LEASE_DESK_BOX=sat SPOOL_ROOT="$T/spool" bash -c '
    set -uo pipefail
    do_log() { echo "LOG $*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_lease_init; spl_fleet_mirror_tenants' 2>/dev/null | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' '
}

got="$(tenants "$T/stub/as")"
[[ "$got" == "both csitea own-a ws-b " ]] &&
  pass "1-2. the moved tenants are served through the hop; lease tenant, test workspace, empty pin, other box out; 'both' once" ||
  fail "1-2. tenants: '$got'"
got="$(tenants "$T/stub/as-refused")"
[[ "$got" == "both own-a " ]] && pass "3. no sudo rule: this user's own tenants, as before" || fail "3. refused: '$got'"
t0=$SECONDS; got="$(tenants "$T/stub/as-hang")"; took=$((SECONDS - t0))
[[ "$got" == "both own-a " && "$took" -lt 8 ]] && pass "3. a hop that hangs is cut at its limit (${took}s)" || fail "3. hang: '$got' ${took}s"

lines() { grep -c "$1" "$T/spool/dispatch/lease.log" 2>/dev/null; }
[[ "$(lines 'COPY-ROOT-UNREAD .*the hop to t-desk-user failed (rc 1)')" == 1 && "$(lines 'COPY-ROOT-UNREAD')" == 1 ]] &&
  pass "3. a refused hop names the root in the log, once across refused and hung" || fail "3. log: $(cat "$T/spool/dispatch/lease.log" 2>&1)"
got="$(tenants "$T/stub/as")"
[[ "$got" == "both csitea own-a ws-b " && "$(lines 'COPY-ROOT .*listed again')" == 1 ]] &&
  pass "3. the hop back: the tenants return, logged once" || fail "3. back: '$got' $(cat "$T/spool/dispatch/lease.log" 2>&1)"

chmod 700 "$RB"
[[ "$fails" == 0 ]]
