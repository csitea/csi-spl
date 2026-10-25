#!/usr/bin/env bash
# Every variable in variables.tf has a default or a line in marketplace_test.tfvars.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
MOD="$ROOT/csi-spl-iac/src/terraform/marketplace-spool-vm"
fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

check() {
  awk -v tf="$2" '
    function finish(   line, found) {
      if (name == "") return
      if (has_default) {
        name = ""
        return
      }
      found = 0
      while ((getline line < tf) > 0) {
        if (line ~ ("^" name "[[:space:]]*=")) found = 1
      }
      close(tf)
      if (!found) {
        printf "FAIL %s has no default and no tfvars value\n", name > "/dev/stderr"
        bad = 1
      }
      name = ""
    }
    /^variable[[:space:]]+"/ {
      finish()
      name = $2
      gsub(/"/, "", name)
      has_default = 0
      depth = 0
      open = 1
    }
    open {
      if ($0 ~ /^[[:space:]]*default[[:space:]]*=/) has_default = 1
      line = $0
      depth += gsub(/\{/, "{", line)
      depth -= gsub(/\}/, "}", line)
      if (depth == 0) {
        finish()
        open = 0
      }
    }
    END {
      finish()
      if (bad) exit 1
    }
  ' "$1"
}

if check "$MOD/variables.tf" "$MOD/marketplace_test.tfvars"; then
  pass "every variable has a default or a tfvars value"
else
  fail "real variables.tf"
fi

cp "$MOD/variables.tf" "$T/variables.tf"
cp "$MOD/marketplace_test.tfvars" "$T/marketplace_test.tfvars"
cat >>"$T/variables.tf" <<'EOF'
variable "planted_missing" {
  type = string
}
EOF
if check "$T/variables.tf" "$T/marketplace_test.tfvars"; then
  fail "RED planted variable should fail"
else
  pass "RED planted variable with no default and no tfvars value"
fi

[[ "$fails" -eq 0 ]] && printf 'PASS: all %s assertions\n' "$(basename "$0")"
exit "$fails"
