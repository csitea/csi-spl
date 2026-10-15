#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no `source` or `.` line under csi-spl-{iac,orc}/src/bash/run/ or
#          csi-spl-{iac,orc}/lib/ loads a fixed box path (/opt/, /home/,
#          /mnt/), quoted '...', "..." or bare. Comment lines are skipped. A
#          fixed box path in a source line broke every iac action (r10-05).
#          Red control: the SAME scan() runs first on a temp fixture and must
#          hit each quote form, and must not hit the relative $(dirname ...)
#          form (6535dd26d); then on the tree, where it must find 0 sites.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
fails=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# scan <dir>...: print every non-comment source/. line that loads a box path.
scan() {
  grep -rnE --include='*.sh' \
    '^([^#]*[[:space:];&|(])?(source|\.)[[:space:]]+["'"'"']?/(opt|home|mnt)/' "$@"
}

# Red control, one fixture file per form so each hit is counted on its own.
printf '%s\n' 'source "/opt/csi/x/lib.func.sh" || exit 1' > "$T/dq-source.func.sh"
printf '%s\n' ". '/home/\$USER/lib.func.sh'" > "$T/sq-dot.func.sh"
printf '%s\n' 'source /mnt/x/lib.func.sh' > "$T/bare-source.func.sh"
printf '%s\n' '  [[ -f x ]] && . /opt/x/lib.func.sh' > "$T/bare-dot.func.sh"
# shellcheck disable=SC2016 # the literal line, not expanded
printf '%s\n' 'source "$(dirname "${BASH_SOURCE[0]}")/../lib/x.func.sh" || exit 1' \
  '# source "/opt/csi/x/lib.func.sh"' > "$T/ok.func.sh"
for f in dq-source sq-dot bare-source bare-dot; do
  if scan "$T/$f.func.sh" >/dev/null; then
    echo "ok   red control: scan() hits $f"
  else
    echo "FAIL red control: scan() misses $f: $(cat "$T/$f.func.sh")"; fails=$((fails + 1))
  fi
done
if out=$(scan "$T/ok.func.sh"); then
  echo "FAIL red control: scan() hits a relative or commented line: $out"; fails=$((fails + 1))
else
  echo "ok   red control: relative \$(dirname ...) and comment lines pass"
fi

# The tree: 0 sites.
dirs=()
for d in csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run csi-spl-iac/lib csi-spl-orc/lib; do
  if [[ -d "$REPO_ROOT/$d" ]]; then
    dirs+=("$REPO_ROOT/$d")
  else
    echo "FAIL missing dir: $d"; fails=$((fails + 1))
  fi
done
if (( ${#dirs[@]} )) && out=$(scan "${dirs[@]}"); then
  echo "FAIL a source/. line loads a fixed box path (use a path relative to the script):"
  echo "$out"; fails=$((fails + 1))
else
  echo "ok   tree: no source/. line loads /opt/, /home/ or /mnt/ (${#dirs[@]} dirs)"
fi

if (( fails )); then echo "FAIL: $fails check(s)"; exit 1; fi
echo "PASS: no-box-path-source"
