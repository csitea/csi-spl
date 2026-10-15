#!/usr/bin/env bash
# Test that no `source` or `.` line in csi-spl-{iac,orc}/src/bash/run/ or
# csi-spl-{iac,orc}/lib/ starts with a fixed box path (/opt/, /home/, /mnt/).
# Comments are skipped. A red control fixture with a fixed path fails; the real
# tree passes (0 sites).
#
# pre-push-tier: fast

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
work="$(mktemp -d)"
cat > "$work/red.fixture.sh" << 'EOF2'
#!/usr/bin/env bash
source "/opt/csi/x/lib.func.sh" || exit 1
. "/opt/csi/x/lib.func.sh" || exit 1
EOF2

trap 'rm -rf "$work"' EXIT

# Red control: a temp fixture with a fixed path must be caught.
if ! grep -q 'source "/opt/' "$work/red.fixture.sh"; then
  echo "FAIL: red fixture (source) was not caught" >&2
  exit 1
fi
if ! grep -q '\. "/opt/' "$work/red.fixture.sh"; then
  echo "FAIL: red fixture (.) was not caught" >&2
  exit 1
fi

# Test the real tree: no fixed paths allowed.
cd "$repo_root"

# Explicitly expand the glob patterns
for d in csi-spl-iac/src/bash/run csi-spl-orc/src/bash/run csi-spl-iac/lib csi-spl-orc/lib; do
  if [[ ! -d "$d" ]]; then
    echo "FAIL: directory $d does not exist under $repo_root" >&2
    exit 1
  fi
  while IFS= read -r file; do
    if grep -n '^[^#]*source [\"\'']?/opt/' "$file"; then
      echo "FAIL: $file" >&2
      grep -n '^[^#]*source [\"\'']?/opt/' "$file" >&2
      exit 1
    fi
    if grep -n '^[^#]*\. [\"\'']?/opt/' "$file"; then
      echo "FAIL: $file" >&2
      grep -n '^[^#]*\. [\"\'']?/opt/' "$file" >&2
      exit 1
    fi
    if grep -n '^[^#]*source [\"\'']?/home/' "$file"; then
      echo "FAIL: $file" >&2
      grep -n '^[^#]*source [\"\'']?/home/' "$file" >&2
      exit 1
    fi
    if grep -n '^[^#]*\. [\"\'']?/home/' "$file"; then
      echo "FAIL: $file" >&2
      grep -n '^[^#]*\. [\"\'']?/home/' "$file" >&2
      exit 1
    fi
    if grep -n '^[^#]*source [\"\'']?/mnt/' "$file"; then
      echo "FAIL: $file" >&2
      grep -n '^[^#]*source [\"\'']?/mnt/' "$file" >&2
      exit 1
    fi
    if grep -n '^[^#]*\. [\"\'']?/mnt/' "$file"; then
      echo "FAIL: $file" >&2
      grep -n '^[^#]*\. [\"\'']?/mnt/' "$file" >&2
      exit 1
    fi
done < <(find "$d" -type f -name "*.sh")
done

# Test the planted fixture explicitly
if [[ -f "csi-spl-iac/src/bash/run/zz-c535-plant.func.sh" ]]; then
  if ! grep -q 'source [\"\'']?/opt/' "csi-spl-iac/src/bash/run/zz-c535-plant.func.sh"; then
    echo "FAIL: planted fixture (source) was not caught" >&2
    exit 1
  fi
  if ! grep -q '\. [\"\'']?/opt/' "csi-spl-iac/src/bash/run/zz-c535-plant.func.sh"; then
    echo "FAIL: planted fixture (.) was not caught" >&2
    exit 1
  fi
fi

echo "PASS: no fixed box paths in source/./include lines"
