#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_laptop_box_install (SPL-6680, spec 037 "Laptop box"): a member's
#          Debian laptop as a fleet worker box, one line. Everything runs in a
#          mktemp root with stubs: no apt, no user, no sudo, no hub.
#   1. the hours window: valid forms -> systemd days + start + end; a window
#      that ends before it starts, a 9:00 hour, a bad day -> exit 2
#   2. bad values are refused before anything runs (exit 2): tag, hours,
#      tenant, env, agent cap, move box, member user, ask way, ask person
#   3. not Debian -> exit 3, nothing run
#   4. DRY_RUN (default): the root plan (packages, the agents' user with a
#      locked password and no sudo group, box.env, laptop-box.env with the
#      hours, the cap and the move box; her controls and pop-up root-owned,
#      the tick timer as the agents' user, the pop-up only in her session),
#      the hub from the cnf, no root call, no install call
#   5. DRY_RUN=0: the root runner gets the same plan; install.sh runs as the
#      agent user with --cli claude --fleet and the tag; the token reaches it
#      through SPOOL_JOIN_TOKEN only, never an argv or a log, and no file
#      under the test root holds it afterwards
#   6. no token -> exit 2, nothing run as root
#   7. a failing install.sh -> exit 1, the token file still removed
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
export IN_ORC_RUN="spl-laptop-box-install provision-spool-root"

CO="$T/co"; mkdir -p "$CO/csi-spl-cnf/csi-spl" "$CO/csi-spl-orc"
printf '{"env":{"dns":{"api_fqdn":"hub.example.com"},"box":{"spool_root":"%s/spool","spool_root_group":"grp-x"},"steps":{"060-gcp-vm-satellite":{"box_agent_user":"agt-u"}}}}\n' "$T" \
  >"$CO/csi-spl-cnf/csi-spl/prd.env.json"
: >"$T/debian_version"
cat >"$T/rootrun" <<'EOF'
#!/usr/bin/env bash
for c in "$@"; do echo "$c" >>"$ROOTLOG"; done
EOF
cat >"$T/install.sh" <<'EOF'
#!/usr/bin/env bash
{ echo "ARGS $*"; echo "TOKEN ${SPOOL_JOIN_TOKEN:-}"; echo "HUB $SPOOL_HUB_URL"; echo "TF_LEFT $( [ -e "$TOKEN_FILE" ] && echo yes || echo no)"; } >>"$INSTLOG"
exit "${INST_RC:-0}"
EOF
chmod +x "$T/rootrun" "$T/install.sh"
run_install() {
  : >"$T/root.log"; : >"$T/inst.log"
  SNIPPET=do_spl_laptop_box_install in_orc LAPTOP_CHECKOUT="$CO" LAPTOP_OS_RELEASE="${OSREL:-$T/debian_version}" \
    LAPTOP_ROOT_RUN="$T/rootrun" LAPTOP_AS_USER=env LAPTOP_INSTALL_SH="$T/install.sh" \
    ROOTLOG="$T/root.log" INSTLOG="$T/inst.log" TMPDIR="$T" "$@" >"$T/o" 2>&1
}
OK=(BOX_TAG=lap-a "HOURS=Mon-Fri 09:00-17:00" TENANT_ID=t9 MOVE_BOX=home LAPTOP_MEMBER=mem)

# 1
src() { bash -c 'do_log(){ :; }; source "$1"; shift; spl_laptop_hours_parse "$1"' _ "$PROJ_ROOT/lib/bash/funcs/spl-laptop-box.func.sh" "$1"; }
[[ "$(src 'Mon-Fri 09:00-17:00')" == "Mon..Fri 09:00 17:00" ]] && pass "1 Mon-Fri window" || fail "1 Mon-Fri window: $(src 'Mon-Fri 09:00-17:00')"
[[ "$(src 'Mon,Wed-Fri 08:30-16:00')" == "Mon,Wed..Fri 08:30 16:00" ]] && pass "1 list + range" || fail "1 list + range"
bad=0; for h in 'Mon-Fri 17:00-09:00' 'Mon 09:00-09:00' 'Mon-Fri 9:00-17:00' 'Xyz 09:00-10:00' ''; do src "$h" >/dev/null; [[ $? -eq 2 ]] || bad=1; done
(( bad == 0 )) && pass "1 bad windows exit 2" || fail "1 a bad window was taken"

# 2
for kv in BOX_TAG=Lap_A "HOURS=Mon 18:00-08:00" TENANT_ID=T1 LAPTOP_ENV=stage AGENT_MAX=0 MOVE_BOX=Home "LAPTOP_MEMBER=a b" LAPTOP_ASK=sms LAPTOP_ASK_HUM=bob; do
  run_install "${OK[@]}" "$kv"; rc=$?
  [[ $rc -eq 2 && ! -s "$T/root.log" ]] && pass "2 refused: $kv" || fail "2 $kv: rc=$rc $(head -2 "$T/o")"
done

# 3
OSREL="$T/nope" run_install "${OK[@]}"; rc=$?
[[ $rc -eq 3 && ! -s "$T/root.log" ]] && pass "3 not Debian: exit 3" || fail "3 not Debian: rc=$rc"

# 4
run_install "${OK[@]}"; rc=$?
o="$(cat "$T/o")"
if [[ $rc -eq 0 && ! -s "$T/root.log" && ! -s "$T/inst.log" ]] \
  && grep -q "useradd -m -s /bin/bash 'agt-u' && passwd -l 'agt-u'" <<<"$o" \
  && ! grep -qE 'usermod -aG (sudo|adm)' <<<"$o" \
  && grep -q "SPOOL_BOX_TAG=lap-a" <<<"$o" && grep -q "SPOOL_FLEET_TENANT=t9" <<<"$o" \
  && grep -q "LAPTOP_HOURS=Mon-Fri 09:00-17:00' 'LAPTOP_AGENT_MAX=4'" <<<"$o" \
  && grep -q "'LAPTOP_MOVE_BOX=home' 'LAPTOP_MEMBER=mem' 'LAPTOP_ASK=wui'" <<<"$o" && grep -q "usermod -aG 'grp-x' 'mem'" <<<"$o" \
  && grep -q "'User=agt-u'" <<<"$o" && grep -q "'ExecStart=$CO/csi-spl-orc/run -a do_spl_laptop_box_tick'" <<<"$o" \
  && grep -q "'ConditionUser=mem'" <<<"$o" && grep -q "install -o root -g root -m 0755 '$CO/csi-spl-orc/src/bash/features/laptop-box/laptop-box-ctl.sh' /usr/local/bin/spl-laptop-box" <<<"$o" \
  && grep -q "systemctl enable --now spl-laptop-box-tick.timer" <<<"$o" \
  && grep -q "install -d -o 'agt-u' -g 'grp-x' -m 2770 '$T/spool'" <<<"$o" \
  && grep -q "hub https://hub.example.com" <<<"$o"; then pass "4 dry run: the plan, nothing run"
else fail "4 dry run: rc=$rc"; echo "$o"; fi

# 5
SECRET="spj1.t9.secret-$$"
run_install "${OK[@]}" DRY_RUN=0 SPOOL_JOIN_TOKEN="$SECRET"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "useradd" "$T/root.log" \
  && grep -qx "ARGS --cli claude --fleet --env prd --tenant t9 --box lap-a" "$T/inst.log" \
  && grep -qx "TOKEN $SECRET" "$T/inst.log" && grep -qx "TF_LEFT no" "$T/inst.log" \
  && ! grep -q "$SECRET" "$T/root.log" "$T/o" && ! grep -q "ARGS.*$SECRET" "$T/inst.log" \
  && [[ -z "$(grep -rl --exclude=inst.log -- "$SECRET" "$T")" ]]; then pass "5 real run: root plan, install as user, token by file only"
else fail "5 real run: rc=$rc"; cat "$T/o" "$T/inst.log"; fi

# 6
run_install "${OK[@]}" DRY_RUN=0 SPOOL_JOIN_TOKEN= </dev/null; rc=$?
[[ $rc -eq 2 && ! -s "$T/root.log" ]] && pass "6 no token: exit 2, nothing as root" || fail "6 no token: rc=$rc"

# 7
run_install "${OK[@]}" DRY_RUN=0 SPOOL_JOIN_TOKEN="$SECRET" INST_RC=5; rc=$?
[[ $rc -eq 1 && -z "$(grep -rl --exclude=inst.log -- "$SECRET" "$T")" ]] && pass "7 install fails: exit 1, token file gone" || fail "7 install fails: rc=$rc"

echo "=== spl-laptop-box-install: $fails failure(s) ==="
(( fails == 0 ))
