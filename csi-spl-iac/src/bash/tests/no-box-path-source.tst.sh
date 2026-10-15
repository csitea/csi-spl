#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no `source` or `.` line under csi-spl-{iac,orc}/src/bash/run/,
#          csi-spl-{iac,orc}/lib/ or csi-spl-{api,wui}/src/ (r12-10) loads a
#          fixed box path (/opt/, /home/, /mnt/), quoted '...', "..." or bare.
#          Comment lines are skipped. A fixed box path in a source line broke
#          every iac action (r10-05).
#          Red control: the SAME scan() runs first on a temp fixture and must
#          hit each quote form, and must not hit the relative $(dirname ...)
#          form (6535dd26d); the SAME tree_scan() then runs on a temp fixture
#          tree outside git, where an api and a wui plant must each be hit;
#          then on the tree, where it must find 0 sites.
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

DIRS=(csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run csi-spl-iac/lib csi-spl-orc/lib
  csi-spl-api/src csi-spl-wui/src)

# tree_scan <root>: scan() every DIRS entry under <root>; dirs[] holds those
# found, missing[] the rest.
tree_scan() {
  dirs=() missing=()
  local d
  for d in "${DIRS[@]}"; do
    if [[ -d "$1/$d" ]]; then dirs+=("$1/$d"); else missing+=("$d"); fi
  done
  (( ${#dirs[@]} )) && scan "${dirs[@]}"
}

# Red control: a fixture tree outside git, one /opt/ plant in api and in wui,
# a relative source beside each; tree_scan() must hit both plants, only them.
F="$T/tree"
mkdir -p "$F/csi-spl-api/src/bash" "$F/csi-spl-wui/src/docker"
printf '%s\n' 'source "/opt/csi/x/lib.func.sh" || exit 1' > "$F/csi-spl-api/src/bash/plant.sh"
printf '%s\n' '. /opt/csi/x/lib.func.sh' > "$F/csi-spl-wui/src/docker/plant.sh"
# shellcheck disable=SC2016 # the literal line, not expanded
printf '%s\n' 'source "$(dirname "${BASH_SOURCE[0]}")/lib.func.sh"' \
  | tee "$F/csi-spl-api/src/bash/ok.sh" > "$F/csi-spl-wui/src/docker/ok.sh"
out=$(tree_scan "$F")
for m in csi-spl-api csi-spl-wui; do
  if grep -q "^$F/$m/src/[a-z]*/plant\.sh:" <<<"$out"; then
    echo "ok   red control: tree_scan() hits the $m plant"
  else
    echo "FAIL red control: tree_scan() misses the $m plant"; fails=$((fails + 1))
  fi
done
if grep -q '/ok\.sh:' <<<"$out"; then
  echo "FAIL red control: tree_scan() hits a relative source: $out"; fails=$((fails + 1))
else
  echo "ok   red control: tree_scan() passes the relative sources"
fi

# The tree: 0 sites.
tree_scan "$REPO_ROOT" > "$T/tree.out"; rc=$?
for d in "${missing[@]}"; do echo "FAIL missing dir: $d"; fails=$((fails + 1)); done
if (( rc == 0 )); then
  echo "FAIL a source/. line loads a fixed box path (use a path relative to the script):"
  cat "$T/tree.out"; fails=$((fails + 1))
else
  echo "ok   tree: no source/. line loads /opt/, /home/ or /mnt/ (${#dirs[@]} dirs)"
fi

if (( fails )); then echo "FAIL: $fails check(s)"; exit 1; fi
echo "PASS: no-box-path-source"
