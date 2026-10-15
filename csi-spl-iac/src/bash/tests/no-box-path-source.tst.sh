#!/usr/bin/env bash
# Test that no `source` or `.` line in csi-spl-{iac,orc}/src/bash/run/ or
# csi-spl-{iac,orc}/lib/ starts with a fixed box path (/opt/, /home/, /mnt/).
# Comments are skipped. A red control fixture with a fixed path fails; the real
# tree passes (0 sites).
#
# pre-push-tier: fast

set -euo pipefail

dir=$(cd "$(dirname "$0")" && pwd)
: "$dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: "$work"

# Red control: a temp fixture with a fixed path fails.
red_fixture="$work/red.fixture.sh"
cat >"$red_fixture" <<'EOF'
#!/usr/bin/env bash
source "/opt/csi/x/lib.func.sh" || exit 1
EOF

# Test the red fixture: it must fail.
if bash "$red_fixture" 2>/dev/null; then
  echo "FAIL: red fixture should have failed (fixed path), but passed" >&2
  exit 1
fi

# Test the real tree: no fixed paths allowed.
while IFS= read -r -d '' file; do
  while read -r line; do
    echo "FAIL: $file:$line" >&2
    exit 1
  done < <(grep -n -E '^[^#]*\s*(source|\.)\s+["\x27](/opt/|/home/|/mnt/)' "$file")
done < <(find csi-spl-iac/src/bash/run/ csi-spl-orc/src/bash/run/ csi-spl-iac/lib/ csi-spl-orc/lib/ -type f -name "*.sh" -print0 2>/dev/null || true)

echo "PASS: no fixed box paths in source/./include lines"