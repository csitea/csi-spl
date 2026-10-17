#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 142 row B7 -- the do_require_bin hint in EACH of the three
#          copies ({iac,orc,utl}/lib/bash/funcs/require-bin.func.sh) points at
#          do_box_pkg_install and keeps the binary -> apt package map.
#          Every case sources the real copy and runs do_require_bin with an
#          empty PATH (mktemp -d), so the tool is missing and the hint prints;
#          do_log is a stub. Nothing is installed, nothing calls apt or sudo.
#          Per copy:
#          1. jq and an unknown name: the hint names do_box_pkg_install and
#             never `apt-get install`
#          2. pip -> BOX_PKG=python3-pip, xmllint -> BOX_PKG=libxml2-utils
#          3. AGENT_ID empty -> AGENT_ID=<your-agent-id>, never `unknown`;
#             AGENT_ID set -> that id
#          4. two missing tools: the all-at-once line is the action too
#          Then: the three copies are byte-identical (md5).
#
#          CONTROLS: one copy restored from 268157a60^ (old apt hint) -> red,
#          naming that copy; the 268157a60 copy (no package map) -> the pip
#          case red. A check that cannot fail proves nothing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
COPIES=(csi-spl-iac csi-spl-orc csi-spl-utl)
fails=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/empty-path"

fail() { echo "FAIL: $*"; fails=$((fails + 1)); }

# The log lines do_require_bin prints for the missing tools "$2..", sourced
# from copy $1, in a subshell whose PATH holds nothing.
_hint_out() {
  local copy="$1"
  shift
  (
    do_log() { echo "$*"; }
    # shellcheck disable=SC1090
    source "$ROOT/$copy/lib/bash/funcs/require-bin.func.sh" || exit 90
    # shellcheck disable=SC2123 # deliberate: no tool on PATH, so the hint prints
    PATH="$tmp/empty-path"
    do_require_bin "$@"
    echo "rc=$?"
  )
}

_check_copy() {
  local copy="$1" out name
  [[ -r "$ROOT/$copy/lib/bash/funcs/require-bin.func.sh" ]] || { fail "$copy: no require-bin.func.sh"; return; }
  for name in jq zz-no-such-tool-b7; do
    out="$(AGENT_ID=c-test _hint_out "$copy" "$name")"
    [[ "$out" == *"rc=11"* ]] || fail "$copy: $name: do_require_bin did not return 11: $out"
    [[ "$out" == *"do_box_pkg_install"* ]] || fail "$copy: $name: hint does not name do_box_pkg_install: $out"
    [[ "$out" != *"apt-get install"* ]] || fail "$copy: $name: hint still prints apt-get install: $out"
    [[ "$out" == *"BOX_PKG=$name "* ]] || fail "$copy: $name: hint lacks BOX_PKG=$name: $out"
  done
  out="$(AGENT_ID=c-test _hint_out "$copy" pip)"
  [[ "$out" == *"BOX_PKG=python3-pip "* ]] || fail "$copy: pip: hint lacks BOX_PKG=python3-pip: $out"
  out="$(AGENT_ID=c-test _hint_out "$copy" xmllint)"
  [[ "$out" == *"BOX_PKG=libxml2-utils "* ]] || fail "$copy: xmllint: hint lacks BOX_PKG=libxml2-utils: $out"
  [[ "$out" == *"AGENT_ID=c-test"* ]] || fail "$copy: AGENT_ID set: hint lacks AGENT_ID=c-test: $out"
  out="$(AGENT_ID='' _hint_out "$copy" jq)"
  [[ "$out" == *"AGENT_ID=<your-agent-id>"* ]] || fail "$copy: AGENT_ID empty: hint lacks the placeholder: $out"
  [[ "$out" != *"AGENT_ID=unknown"* ]] || fail "$copy: AGENT_ID empty: hint prints AGENT_ID=unknown: $out"
  out="$(AGENT_ID=c-test _hint_out "$copy" jq docker | grep 'all at once' || true)"
  [[ "$out" == *"BOX_PKG='jq docker.io' "*"do_box_pkg_install"* ]] || fail "$copy: all-at-once line is not the action for 'jq docker.io': $out"
}

for copy in "${COPIES[@]}"; do
  before=$fails
  _check_copy "$copy"
  [[ $fails -eq $before ]] && echo "PASS: $copy hint"
done

sums="$(cd "$ROOT" && for copy in "${COPIES[@]}"; do md5sum "$copy/lib/bash/funcs/require-bin.func.sh"; done)"
if [[ "$(awk '{print $1}' <<< "$sums" | sort -u | wc -l)" -eq 1 ]]; then
  echo "PASS: the 3 copies are byte-identical"
else
  fail "the 3 copies differ:"$'\n'"$sums"
fi

if [[ $fails -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "OK: require-bin-hint, ${#COPIES[@]} copies"
