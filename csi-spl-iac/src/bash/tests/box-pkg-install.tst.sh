#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 142 row B4 -- do_box_pkg_install, the recorded install.
#          Hermetic: apt-get, dpkg, dpkg-query, sudo, getent, curl and the
#          spool send (BOX_PKG_SEND) are stubs, the journal and the backup dir
#          are temp paths, SPOOL_TEST=1; nothing on this box is installed,
#          read or written. Every stub appends to one call log, so ORDER is
#          tested, not only presence.
#          1. unflagged real install: the journal intent line exists BEFORE
#             the stubbed install runs (the stub counts it), a result line
#             after, apt-get gets the request with DEBIAN_FRONTEND set, no
#             note, the manifest row, rc 0; drift (B3) reads the journal
#          2. flagged real install (the PC 10-16 simulation): FLAG lines, the
#             note to the orchestrator BEFORE the install, a snapshot (link,
#             nsswitch.conf, dpkg selections, NetworkManager dir) before it,
#             the flags + snapshot dir in the journal
#          3. DRY_RUN unset (default 1) and DRY_RUN=1: the install is never
#             called, no journal, no snapshot; the exact re-run line with
#             DRY_RUN=0 (quotes kept); a flagged dry run notes "dry run"
#          4. empty or unset BOX_PKG_REASON, AGENT_ID or BOX_PKG -> refused,
#             nothing called
#          5. apt-get -s fails (unknown package) -> rc 1, no install
#          6. the auto-undo hook (row B6 wires it): flagged + health red ->
#             called once, rc 6; BOX_PKG_AUTO_UNDO=0 or unflagged -> not called
#
#          CONTROLS: case 1 must go red with the journal write moved after
#          the install (row B4), case 2 with the note sent after it, and cases
#          1 and 3 against a no-op do_box_pkg_install: a check that cannot
#          fail proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUN_DIR="$TEST_DIR/../run"
[[ -r "$RUN_DIR/box-pkg-install.func.sh" && -r "$RUN_DIR/box-pkg-flag.func.sh" ]] ||
  { echo "FAIL: cannot read box-pkg-install.func.sh / box-pkg-flag.func.sh"; exit 1; }
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/stub" "$tmp/root/etc/NetworkManager"
export CALLS="$tmp/calls"
cat > "$tmp/stub/apt-get" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == -s ]]; then
  echo "sim ${*:3}" >>"$CALLS"
  [[ "${STUB_SIM_FAIL:-0}" != 1 ]] || { echo "E: Unable to locate package ${*:3}" >&2; exit 100; }
  cat "$STUB_SIM"; exit 0
fi
[[ "$1" == install ]] || exit 99
n=0
[[ -f "$BOX_PKG_JOURNAL" ]] && n=$(awk -F '\t' '$5 == "install"' "$BOX_PKG_JOURNAL" | wc -l)
snap=0
[[ -d "$BOX_PKG_BACKUP_DIR" ]] && snap=$(find "$BOX_PKG_BACKUP_DIR" -name nsswitch.conf | wc -l)
echo "install ${*:2} frontend=${DEBIAN_FRONTEND:-} intent=$n snapshot=$snap" >>"$CALLS"
exit "${STUB_INSTALL_RC:-0}"
STUB
cat > "$tmp/stub/dpkg" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == --get-selections ]] || exit 2
printf 'jq\t\t\t\t\tinstall\nnetwork-manager\t\t\t\tinstall\n'
STUB
cat > "$tmp/stub/dpkg-query" <<'STUB'
#!/usr/bin/env bash
echo "dpkg-query ${*: -1}" >>"$CALLS"
[[ " ${STUB_MISSING:-} " == *" ${*: -1} "* ]] && exit 1
printf 'install ok installed'
STUB
cat > "$tmp/stub/sudo" <<'STUB'
#!/usr/bin/env bash
exec "$@"
STUB
cat > "$tmp/stub/getent" <<'STUB'
#!/usr/bin/env bash
echo "getent $*" >>"$CALLS"
exit "${STUB_DNS_RC:-0}"
STUB
cat > "$tmp/stub/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl ${*: -1}" >>"$CALLS"
STUB
cat > "$tmp/send" <<'STUB'
#!/usr/bin/env bash
echo "send $*" >>"$CALLS"
STUB
chmod +x "$tmp/stub/"* "$tmp/send"
export PATH="$tmp/stub:$PATH" SPOOL_TEST=1 SPOOL_ROOT="$tmp/spool"
export BOX_PKG_SEND="$tmp/send" BOX_PKG_BOX=box-a BOX_PKG_HUB_HOST=hub.example.com
export BOX_PKG_JOURNAL="$tmp/var/journal.tsv" BOX_PKG_BACKUP_DIR="$tmp/backups"
export BOX_PKG_ROOT="$tmp/root" BOX_CLASS=pc
export BOX_PKG_SERVICES='dns: systemd-resolved libnss-resolve resolvconf
network: network-manager ifupdown'
ln -s /run/NetworkManager/resolv.conf "$tmp/root/etc/resolv.conf"
printf 'hosts: files dns\n' > "$tmp/root/etc/nsswitch.conf"
printf '[main]\n' > "$tmp/root/etc/NetworkManager/NetworkManager.conf"
unset DRY_RUN BOX_PKG BOX_PKG_REASON AGENT_ID BOX_PKG_ISSUE BOX_PKG_AUTO_UNDO

printf 'Inst jq (1.7.1-6 Debian:13.1/stable [amd64])\nConf jq (1.7.1-6 Debian:13.1/stable [amd64])\n' > "$tmp/sim-jq"
cat > "$tmp/sim-pc" <<'SIM'
NOTE: This is only a simulation!
Inst systemd-resolved (257.9-1~deb13u1 Debian:13.1/stable [amd64])
Inst libnss-resolve (257.9-1~deb13u1 Debian:13.1/stable [amd64])
Conf systemd-resolved (257.9-1~deb13u1 Debian:13.1/stable [amd64])
SIM
OWNERS_PC=$'dns NetworkManager\nnetwork network-manager\nnsswitch-hosts files dns'

# run_install: one action run in a fresh shell, from a clean slate
run_install() {
  : >"$CALLS"
  rm -rf "${tmp:?}/var" "${tmp:?}/backups"
  # shellcheck disable=SC1090,SC1091  # the files under test (FUNC: a control copy)
  ( source "$RUN_DIR/box-pkg-flag.func.sh"; source "${FUNC:-$RUN_DIR/box-pkg-install.func.sh}"
    do_box_pkg_install ) 2>&1
}

# case_unflagged: 1, the intent line is journaled before the install runs
case_unflagged() {
  local out rc=0
  out=$(DRY_RUN=0 STUB_SIM="$tmp/sim-jq" BOX_PKG=jq BOX_PKG_REASON='json in the probes' \
    AGENT_ID=c-900 BOX_PKG_ISSUE=SPL-1 run_install) || rc=$?
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  grep -qx 'install -y jq frontend=noninteractive intent=1 snapshot=0' "$CALLS" || { cat "$CALLS"; return 1; }
  ! grep -q '^send ' "$CALLS" || { echo "a note on an unflagged install"; return 1; }
  [[ "$(cut -f5 "$BOX_PKG_JOURNAL" | tr '\n' ' ')" == "install install-ok " ]] || { cat "$BOX_PKG_JOURNAL"; return 1; }
  awk -F '\t' 'NR == 1 && NF == 10 && $2 == "box-a" && $3 == "c-900" && $4 == "SPL-1" && $6 == "jq" &&
    $7 == "jq" && $8 == "" && $10 == "json in the probes" { ok = 1 } END { exit !ok }' "$BOX_PKG_JOURNAL" ||
    { cat "$BOX_PKG_JOURNAL"; return 1; }
  grep -q $'^apt\tjq\t\tdo_box_pkg_install\tlane SPL-1\t\t[0-9-]* SPL-1$' <<<"$out" || { echo "$out"; return 1; }
  grep -qx 'HEALTH green: hub.example.com resolves and serves /version' <<<"$out" || { echo "$out"; return 1; }
}
if case_unflagged; then pass "1. unflagged: intent journaled before the install, result after, manifest row, rc 0"
else fail "1. unflagged install"; fi
# shellcheck disable=SC1091
if [[ "$(source "$RUN_DIR/box-pkg-drift.func.sh"; _box_pkg_drift_journal "$BOX_PKG_JOURNAL")" == $'jq\tc-900\tSPL-1\tjson in the probes' ]]; then
  pass "1. drift (B3) reads the journal line: agent, issue, reason"
else fail "1. drift (B3) does not read the journal line"; fi

# case_flagged: 2, the note and the snapshot come before the install
case_flagged() {
  local out rc=0 first_send first_install
  out=$(DRY_RUN=0 STUB_SIM="$tmp/sim-pc" BOX_PKG_OWNERS="$OWNERS_PC" BOX_PKG=systemd-resolved \
    BOX_PKG_REASON='man pages' AGENT_ID=c-901 run_install) || rc=$?
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  grep -qx 'FLAG dns systemd-resolved NetworkManager -> systemd-resolved' <<<"$out" || { echo "$out"; return 1; }
  grep -qx 'FLAG dns libnss-resolve nsswitch:dns -> resolve' <<<"$out" || { echo "$out"; return 1; }
  first_send=$(grep -n -m1 '^send ' "$CALLS" | cut -d: -f1)
  first_install=$(grep -n -m1 '^install ' "$CALLS" | cut -d: -f1)
  [[ -n "$first_send" && -n "$first_install" && "$first_send" -lt "$first_install" ]] || { cat "$CALLS"; return 1; }
  [[ "$(grep -c '^send ' "$CALLS")" == 1 ]] || { cat "$CALLS"; return 1; }
  grep -q -- '--to orchestrator --kind note --task box-pkg --body box-pkg (install): c-901 installs systemd-resolved' "$CALLS" || { cat "$CALLS"; return 1; }
  grep -q 'intent=1 snapshot=1$' "$CALLS" || { cat "$CALLS"; return 1; }
  local snap
  snap=$(awk -F '\t' 'NR == 1 { print $9 }' "$BOX_PKG_JOURNAL")
  [[ "$snap" == "$BOX_PKG_BACKUP_DIR/"*-c-901 ]] || { cat "$BOX_PKG_JOURNAL"; return 1; }
  [[ "$(cat "$snap/resolv.conf.link")" == /run/NetworkManager/resolv.conf ]] || return 1
  if ! grep -qx 'hosts: files dns' "$snap/nsswitch.conf" || [[ ! -s "$snap/dpkg-selections" ]] ||
    [[ ! -f "$snap/etc/NetworkManager/NetworkManager.conf" ]]; then find "$snap"; return 1; fi
  awk -F '\t' -v f="FLAG dns systemd-resolved NetworkManager -> systemd-resolved; FLAG dns libnss-resolve nsswitch:dns -> resolve" \
    'NR == 1 && $7 == "systemd-resolved libnss-resolve" && $8 == f { ok = 1 } END { exit !ok }' "$BOX_PKG_JOURNAL" ||
    { cat "$BOX_PKG_JOURNAL"; return 1; }
}
if case_flagged; then pass "2. flagged: FLAG lines, note then snapshot then install, flags + snapshot journaled"
else fail "2. flagged install"; fi

# case_dry <DRY_RUN value or empty>: 3, nothing installed, the re-run line
case_dry() {
  local out rc=0 want got
  want=$(cat <<'LINE'
DRY_RUN=0 BOX_PKG='jq tree' BOX_PKG_REASON='it'\''s for json' AGENT_ID='c-902' BOX_PKG_ISSUE='SPL-7' ./run -a do_box_pkg_install
LINE
)
  if [[ -n "$1" ]]; then
    out=$(DRY_RUN="$1" STUB_SIM="$tmp/sim-jq" BOX_PKG='jq tree' BOX_PKG_REASON="it's for json" AGENT_ID=c-902 BOX_PKG_ISSUE=SPL-7 run_install) || rc=$?
  else
    out=$(STUB_SIM="$tmp/sim-jq" BOX_PKG='jq tree' BOX_PKG_REASON="it's for json" AGENT_ID=c-902 BOX_PKG_ISSUE=SPL-7 run_install) || rc=$?
  fi
  [[ "$rc" == 0 ]] || { echo "rc $rc: $out"; return 1; }
  ! grep -q '^install ' "$CALLS" || { cat "$CALLS"; return 1; }
  grep -q '^sim jq tree$' "$CALLS" || { cat "$CALLS"; return 1; }
  [[ ! -e "$BOX_PKG_JOURNAL" && ! -e "$BOX_PKG_BACKUP_DIR" ]] || { echo "dry run wrote the journal or a snapshot"; return 1; }
  got=$(tail -1 <<<"$out")
  [[ "$got" == "$want" ]] || { printf 'want: %s\ngot:  %s\n' "$want" "$got"; return 1; }
  # the printed line, read back by a shell, gives the same inputs
  [[ "$( (eval "${got% ./run -a do_box_pkg_install}"; printf '%s|%s|%s' "$BOX_PKG" "$BOX_PKG_REASON" "$DRY_RUN") )" == "jq tree|it's for json|0" ]]
}
if case_dry ""; then pass "3. DRY_RUN unset: no install, no journal, the exact DRY_RUN=0 re-run line"
else fail "3. DRY_RUN unset"; fi
if case_dry 1; then pass "3. DRY_RUN=1: no install, no journal, the exact DRY_RUN=0 re-run line"
else fail "3. DRY_RUN=1"; fi
out=$(STUB_SIM="$tmp/sim-pc" BOX_PKG_OWNERS="$OWNERS_PC" BOX_PKG=systemd-resolved BOX_PKG_REASON=x AGENT_ID=c-903 run_install)
if grep -q -- '--body box-pkg (dry run): c-903 installs systemd-resolved' "$CALLS" && ! grep -q '^install ' "$CALLS" &&
  grep -q '^would snapshot to ' <<<"$out"; then
  pass "3. flagged dry run: the note says dry run, no install"
else fail "3. flagged dry run: $(cat "$CALLS")"; fi

# 4: a missing required input -> refused before any command
: >"$CALLS"
for spec in "BOX_PKG_REASON=" "AGENT_ID=" "BOX_PKG=" "-u BOX_PKG_REASON" "-u AGENT_ID"; do
  rc=0
  # shellcheck disable=SC2086,SC2016  # spec is an env argument list; $1 $2 are the inner shell's
  out=$(env DRY_RUN=0 STUB_SIM="$tmp/sim-jq" BOX_PKG=jq BOX_PKG_REASON=why AGENT_ID=c-904 env $spec \
    bash -c 'source "$1"; source "$2"; do_box_pkg_install' _ "$RUN_DIR/box-pkg-flag.func.sh" "$RUN_DIR/box-pkg-install.func.sh" 2>&1) || rc=$?
  if [[ "$rc" != 0 && ! -s "$CALLS" && "$out" == *"must be set"* ]]; then pass "4. $spec: refused, nothing called"
  else fail "4. $spec: rc $rc, calls: $(cat "$CALLS")"; fi
  : >"$CALLS"
done

# 5: the simulation fails -> nothing installed
rc=0
out=$(DRY_RUN=0 STUB_SIM_FAIL=1 STUB_SIM="$tmp/sim-jq" BOX_PKG=no-such-pkg BOX_PKG_REASON=why AGENT_ID=c-905 run_install) || rc=$?
if [[ "$rc" == 1 ]] && ! grep -q '^install ' "$CALLS" && [[ ! -e "$BOX_PKG_JOURNAL" ]] && [[ "$out" == *"Unable to locate"* ]]; then
  pass "5. apt-get -s fails: rc 1, nothing installed or journaled"
else fail "5. apt-get -s fails: rc $rc $out"; fi

# 6: the auto-undo hook point
rc=0
out=$(DRY_RUN=0 STUB_DNS_RC=2 STUB_SIM="$tmp/sim-pc" BOX_PKG_OWNERS="$OWNERS_PC" BOX_PKG=systemd-resolved BOX_PKG_REASON=x AGENT_ID=c-906 run_install) || rc=$?
if [[ "$rc" == 6 && "$(grep -c '^AUTO-UNDO ' <<<"$out")" == 1 && "$(grep -c '^send ' "$CALLS")" == 2 ]] &&
  grep -q 'health red after a flagged install by c-906' "$CALLS"; then
  pass "6. flagged + health red: the hook called once, its note sent, rc 6"
else fail "6. flagged + health red: rc $rc $out"; fi
rc=0
out=$(DRY_RUN=0 BOX_PKG_AUTO_UNDO=0 STUB_DNS_RC=2 STUB_SIM="$tmp/sim-pc" BOX_PKG_OWNERS="$OWNERS_PC" BOX_PKG=systemd-resolved BOX_PKG_REASON=x AGENT_ID=c-906 run_install) || rc=$?
if [[ "$rc" == 6 ]] && ! grep -q '^AUTO-UNDO ' <<<"$out" && [[ "$(grep -c '^send ' "$CALLS")" == 1 ]]; then
  pass "6. BOX_PKG_AUTO_UNDO=0: the hook not called"
else fail "6. BOX_PKG_AUTO_UNDO=0: rc $rc $out"; fi
rc=0
out=$(DRY_RUN=0 STUB_DNS_RC=2 STUB_SIM="$tmp/sim-jq" BOX_PKG=jq BOX_PKG_REASON=x AGENT_ID=c-906 run_install) || rc=$?
if [[ "$rc" == 6 ]] && ! grep -q '^AUTO-UNDO ' <<<"$out" && ! grep -q '^send ' "$CALLS" && grep -qx 'HEALTH red: hub.example.com does not resolve' <<<"$out"; then
  pass "6. unflagged + health red: the hook not called, rc 6"
else fail "6. unflagged + health red: rc $rc $out"; fi

# CONTROL 1 (row B4): the intent journal write moved after the install -> case 1 red
awk '/^  _bpi_journal install "\$closure"/ { held = $0; getline; held = held "\n" $0; next }
  { print } /apt-get install -y \$BOX_PKG \|\| rc=\$\?$/ && held != "" { print held }' \
  "$RUN_DIR/box-pkg-install.func.sh" > "$tmp/late-journal.func.sh"
if ! diff -q "$RUN_DIR/box-pkg-install.func.sh" "$tmp/late-journal.func.sh" >/dev/null &&
  ! FUNC="$tmp/late-journal.func.sh" case_unflagged >/dev/null; then
  pass "control: case 1 red with the journal write after the install"
else fail "control: case 1 stayed green with the journal write after the install"; fi

# CONTROL 2: the note sent after the install -> case 2 red
awk '/^    _bpi_send "box-pkg \(\$mode\)/ { held = $0; next } { print }
  /^    _bpi_real "\$closure" "\$flags" \|\| rc=\$\?$/ { print "    [[ -z \"$flags\" ]] || " substr(held, 5) }' \
  "$RUN_DIR/box-pkg-install.func.sh" > "$tmp/late-note.func.sh"
if ! diff -q "$RUN_DIR/box-pkg-install.func.sh" "$tmp/late-note.func.sh" >/dev/null &&
  ! FUNC="$tmp/late-note.func.sh" case_flagged >/dev/null; then
  pass "control: case 2 red with the note sent after the install"
else fail "control: case 2 stayed green with the note sent after the install"; fi

# CONTROL 3: a no-op do_box_pkg_install -> cases 1 and 3 red
printf 'do_box_pkg_install() { :; }\n' > "$tmp/noop.func.sh"
if FUNC="$tmp/noop.func.sh" case_unflagged >/dev/null || FUNC="$tmp/noop.func.sh" case_dry 1 >/dev/null; then
  fail "control: a no-op do_box_pkg_install passed case 1 or 3"
else pass "control: no-op do_box_pkg_install turns cases 1 and 3 red"; fi

if (( fails )); then echo "box-pkg-install: $fails FAILED"; exit 1; fi
echo "box-pkg-install: all PASSED"
