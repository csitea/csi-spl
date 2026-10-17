#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 142 row B3 -- do_box_pkg_drift, the read-only drift report.
#          Hermetic: stubbed apt-mark and dpkg-query, a temp manifest dir, a
#          temp journal and temp bin dirs; nothing is read from this box.
#          1. drift: unlisted packages and a bin -> NOT-IN-MANIFEST, the
#             journal's agent id on the one it names (newest line wins); a
#             manifest package not on the box (none, or dpkg `rc`) and a bin
#             path row that is not there -> MISSING-FROM-BOX; base packages,
#             listed bins (path or bare name), a deb row, a pip row, an
#             installed package marked auto (SPL-2339: it was MISSING) and a
#             bin path row outside the bin dirs are not reported; an auto
#             package no row names is not drift either; rc 0
#          2. DRIFT_STRICT=1 -> rc 2, the same report
#          3. DRIFT_STRICT=1 with only MISSING-FROM-BOX -> rc 0
#          4. BOX_CLASS read from the box config (SPOOL_BOX_ENV)
#          5. no journal -> the same lines without agent ids, rc 0
#          6. missing BOX_CLASS / manifest / base list, apt-mark or dpkg-query
#             failing -> rc 1
#
#          CONTROLS: case 1 must go red when the journal join is dropped (row
#          B3: the agent id is lost), when the dpkg-query probe is dropped
#          (SPL-2339: the auto-marked package is MISSING again), and cases 1
#          and 2 must go red against a no-op do_box_pkg_drift: a check that
#          cannot fail proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$TEST_DIR/../run/box-pkg-drift.func.sh" || { echo "FAIL: cannot source box-pkg-drift.func.sh"; exit 1; }
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/stub" "$tmp/cnf" "$tmp/bin1" "$tmp/bin2" "$tmp/home" "$tmp/opt"
cat > "$tmp/stub/apt-mark" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == showmanual && "${STUB_APT_FAIL:-0}" != 1 ]] || exit 100
printf '%s\n' jq base-tool dnsutils htop local-deb
STUB
# dpkg-query: the manual set, fonts-auto and libdns1 installed but marked
# auto, postgresql-client removed with its config left (rc)
cat > "$tmp/stub/dpkg-query" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == -W && "${STUB_DPKG_FAIL:-0}" != 1 ]] || exit 2
printf 'ii \t%s\n' jq base-tool dnsutils htop local-deb fonts-auto libdns1
printf 'rc \t%s\n' postgresql-client
STUB
chmod +x "$tmp/stub/apt-mark" "$tmp/stub/dpkg-query"
export PATH="$tmp/stub:$PATH" HOME="$tmp/home"
export SPOOL_BOX_ENV="$tmp/no-box.env"
unset BOX_CLASS DRIFT_STRICT BOX_PKG_MANIFEST_DIR BOX_PKG_JOURNAL BOX_PKG_BIN_DIRS

printf '#!/bin/sh\n' | tee "$tmp/bin1/tool1" "$tmp/bin1/tool3" "$tmp/bin2/tool2" "$tmp/bin1/data.txt" >/dev/null
printf '#!/bin/sh\n' > "$tmp/opt/go"
chmod +x "$tmp/bin1/tool1" "$tmp/bin1/tool3" "$tmp/bin2/tool2" "$tmp/opt/go"

T=$'\t'
cat > "$tmp/cnf/pc.tsv" <<EOF
# kind${T}name${T}pin${T}installed_by${T}needed_by${T}service${T}added
apt${T}fonts-auto${T}${T}do_gh_runner_add${T}do_gh_runner_add${T}${T}2026-10-17 SPL-2339
apt${T}jq${T}${T}play 02_os_binaries${T}do_require_bin jq${T}${T}2026-10-17 SPL-2271
apt${T}postgresql-client${T}${T}play 02_os_binaries${T}do_require_bin psql${T}${T}2026-10-17 SPL-2271
bin${T}$tmp/bin1/tool1${T}${T}do_box_pkg_install${T}lane SPL-1${T}${T}2026-10-17 SPL-2271
bin${T}$tmp/opt/go${T}${T}play 02_os_binaries${T}lane SPL-1${T}${T}2026-10-17 SPL-2339
bin${T}$tmp/opt/no-go${T}${T}play 02_os_binaries${T}lane SPL-1${T}${T}2026-10-17 SPL-2339
bin${T}tool2${T}${T}do_box_pkg_install${T}lane SPL-1${T}${T}2026-10-17 SPL-2271
deb${T}local-deb${T}${T}do_box_pkg_install${T}lane SPL-1${T}${T}2026-10-17 SPL-2271
pip${T}some-pip-pkg${T}${T}do_box_pkg_install${T}lane SPL-1${T}${T}2026-10-17 SPL-2271
EOF
printf '# the image base set\nbase-tool\n' > "$tmp/cnf/base-pc.txt"
cat > "$tmp/journal.tsv" <<EOF
# utc${T}box${T}agent${T}issue${T}op${T}requested${T}closure${T}flag${T}snapshot${T}reason
2026-10-16T08:00:00Z${T}box-a${T}c-900${T}SPL-0${T}install${T}dnsutils${T}dnsutils${T}${T}${T}an older line
2026-10-17T09:00:00Z${T}box-a${T}c-901${T}SPL-1${T}install${T}dnsutils${T}dnsutils libdns1${T}${T}${T}dig for the probes
EOF

WANT="MISSING-FROM-BOX apt postgresql-client
MISSING-FROM-BOX bin $tmp/opt/no-go
NOT-IN-MANIFEST apt dnsutils agent=c-901 issue=SPL-1 reason=dig for the probes
NOT-IN-MANIFEST apt htop
NOT-IN-MANIFEST bin $tmp/bin1/tool3"
WANT_NOJ="MISSING-FROM-BOX apt postgresql-client
MISSING-FROM-BOX bin $tmp/opt/no-go
NOT-IN-MANIFEST apt dnsutils
NOT-IN-MANIFEST apt htop
NOT-IN-MANIFEST bin $tmp/bin1/tool3"

# run_drift <journal> [VAR=value ...]: prints the output, then `rc=<n>`
run_drift() {
  local j="$1" out rc=0
  shift
  # shellcheck disable=SC2016  # $1 expands in the child shell
  out="$(env BOX_CLASS=pc BOX_PKG_MANIFEST_DIR="$tmp/cnf" BOX_PKG_JOURNAL="$j" \
    BOX_PKG_BIN_DIRS="$tmp/bin1 $tmp/bin2 $tmp/no-such-dir" "$@" \
    bash -c 'source "$1"; do_box_pkg_drift' _ "$FUNC" 2>&1)" || rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}
# check <label> <want output> <want rc> <journal> [VAR=value ...]
check() {
  local label="$1" want="$2" wrc="$3" got
  shift 3
  got="$(run_drift "$@")"
  [[ "$got" == "$want"$'\n'"rc=$wrc" ]] && return 0
  printf '  %s: want\n%s\nrc=%s\n  got\n%s\n' "$label" "$want" "$wrc" "$got"
  return 1
}
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

FUNC="$TEST_DIR/../run/box-pkg-drift.func.sh"
case_drift() { check "drift" "$WANT" 0 "$tmp/journal.tsv"; }
case_strict() { check "strict" "$WANT" 2 "$tmp/journal.tsv" DRIFT_STRICT=1; }

if case_drift; then pass "1 drift report, agent id joined from the journal, rc 0"; else fail "1 drift report"; fi
if case_strict; then pass "2 DRIFT_STRICT=1 -> rc 2"; else fail "2 DRIFT_STRICT=1 -> rc 2"; fi

# 3: only MISSING-FROM-BOX is not drift for DRIFT_STRICT
cp "$tmp/cnf/pc.tsv" "$tmp/cnf/full.tsv" && cp "$tmp/cnf/base-pc.txt" "$tmp/cnf/base-full.txt"
printf 'apt\t%s\t\tx\tlane SPL-1\t\t2026-10-17 SPL-2271\n' dnsutils htop >> "$tmp/cnf/full.tsv"
printf 'bin\ttool3\t\tx\tlane SPL-1\t\t2026-10-17 SPL-2271\n' >> "$tmp/cnf/full.tsv"
if check "strict, missing only" "MISSING-FROM-BOX apt postgresql-client"$'\n'"MISSING-FROM-BOX bin $tmp/opt/no-go" 0 "$tmp/journal.tsv" BOX_CLASS=full DRIFT_STRICT=1; then
  pass "3 DRIFT_STRICT=1 with only MISSING-FROM-BOX -> rc 0"
else fail "3 DRIFT_STRICT=1 with only MISSING-FROM-BOX -> rc 0"; fi

# 4: BOX_CLASS from the box config
printf 'SPOOL_DESK_BOX=box-a\nBOX_CLASS="pc"\n' > "$tmp/box.env"
if check "box.env" "$WANT" 0 "$tmp/journal.tsv" BOX_CLASS= SPOOL_BOX_ENV="$tmp/box.env"; then
  pass "4 BOX_CLASS read from SPOOL_BOX_ENV"
else fail "4 BOX_CLASS read from SPOOL_BOX_ENV"; fi

# 5: no journal on the box yet
if check "no journal" "$WANT_NOJ" 0 "$tmp/no-journal.tsv"; then pass "5 no journal -> no agent ids, rc 0"; else fail "5 no journal"; fi

# 6: missing inputs are refused with rc 1, never an empty (green-looking) report
for c in "BOX_CLASS=" "BOX_CLASS=nope" "BOX_PKG_MANIFEST_DIR=$tmp/home" "STUB_APT_FAIL=1" "STUB_DPKG_FAIL=1"; do
  got="$(run_drift "$tmp/journal.tsv" "$c")"
  if [[ "${got##*$'\n'}" == rc=1 && "$got" == ERROR:* ]]; then pass "6 $c -> rc 1"; else fail "6 $c -> ${got##*$'\n'}"; fi
done
rm "$tmp/cnf/base-full.txt"
got="$(run_drift "$tmp/journal.tsv" BOX_CLASS=full)"
if [[ "${got##*$'\n'}" == rc=1 ]]; then pass "6 no base list -> rc 1"; else fail "6 no base list -> ${got##*$'\n'}"; fi

# CONTROL 1 (row B3): the journal join dropped -> the agent id is lost, case 1 red
sed '/^_box_pkg_drift_journal() {$/a\  return 0 # control: no join' "$TEST_DIR/../run/box-pkg-drift.func.sh" > "$tmp/no-join.func.sh"
if grep -q '^  return 0 # control: no join$' "$tmp/no-join.func.sh" && ! FUNC="$tmp/no-join.func.sh" case_drift >/dev/null; then
  pass "control: case 1 red without the journal join"
else fail "control: case 1 stayed green without the journal join"; fi

# CONTROL 3 (SPL-2339): the dpkg-query probe dropped -> the installed, auto
# marked fonts-auto is MISSING-FROM-BOX again, case 1 red
sed '/^_box_pkg_drift_present() {$/a\  return 0 # control: showmanual only' "$TEST_DIR/../run/box-pkg-drift.func.sh" > "$tmp/no-present.func.sh"
if grep -q '^  return 0 # control: showmanual only$' "$tmp/no-present.func.sh" &&
  grep -qx 'MISSING-FROM-BOX apt fonts-auto' <<<"$(FUNC="$tmp/no-present.func.sh" run_drift "$tmp/journal.tsv")" &&
  ! FUNC="$tmp/no-present.func.sh" case_drift >/dev/null; then
  pass "control: case 1 red without the dpkg-query probe (fonts-auto MISSING)"
else fail "control: case 1 stayed green without the dpkg-query probe"; fi

# CONTROL 2: a no-op do_box_pkg_drift -> cases 1 and 2 red
printf 'do_box_pkg_drift() { :; }\n' > "$tmp/noop.func.sh"
if FUNC="$tmp/noop.func.sh" case_drift >/dev/null || FUNC="$tmp/noop.func.sh" case_strict >/dev/null; then
  fail "control: a no-op do_box_pkg_drift passed case 1 or 2"
else pass "control: no-op do_box_pkg_drift turns cases 1 and 2 red"; fi

if (( fails )); then echo "box-pkg-drift: $fails FAILED"; exit 1; fi
echo "box-pkg-drift: all PASSED"
