#!/bin/bash
# exported-doc-lint.sh: Fail on exported identifiers without doc comments in non-test Go files.
# Only new identifiers (not in the allow-list) are flagged.
set -euo pipefail

ALLOWLIST="csi-spl-api/src/bash/tests/exported-doc-allowlist.txt"

# Check if a line has a doc comment (preceding line starts with // or /*).
has_doc_comment() {
  local file="$1"
  local line_num="$2"
  if [ "$line_num" -eq 1 ]; then
    return 1  # No preceding line.
  fi
  local prev_line
  prev_line=$(sed -n "$((line_num - 1))p" "$file")
  [[ "$prev_line" =~ ^[[:space:]]*//|^[[:space:]]*/\* ]]
}

# Find all non-test Go files in the csi-spl-api directory.
find csi-spl-api/src/go -name '*.go' -not -name '*_test.go' -print0 | while IFS= read -r -d '' file; do
  # Check for exported functions without doc comments.
  grep -n '^func \+[A-Z]' "$file" | while read -r line; do
    line_num="${line%%:*}"
    if ! has_doc_comment "$file" "$line_num" && ! grep -qF "origin/master:$file:$line_num:${line#*:}" "$ALLOWLIST"; then
      echo "ERROR: Exported function without doc comment in $file:"
      echo "$line"
      exit 1
    fi
  done
  # Check for exported types without doc comments.
  grep -n '^type \+[A-Z]' "$file" | while read -r line; do
    line_num="${line%%:*}"
    if ! has_doc_comment "$file" "$line_num" && ! grep -qF "origin/master:$file:$line_num:${line#*:}" "$ALLOWLIST"; then
      echo "ERROR: Exported type without doc comment in $file:"
      echo "$line"
      exit 1
    fi
  done
  # Check for exported variables without doc comments.
  grep -n '^var \+[A-Z]' "$file" | while read -r line; do
    line_num="${line%%:*}"
    if ! has_doc_comment "$file" "$line_num" && ! grep -qF "origin/master:$file:$line_num:${line#*:}" "$ALLOWLIST"; then
      echo "ERROR: Exported variable without doc comment in $file:"
      echo "$line"
      exit 1
    fi
  done
  # Check for exported constants without doc comments.
  grep -n '^[[:space:]]*[A-Z][A-Za-z0-9_]*[[:space:]]*=' "$file" | while read -r line; do
    line_num="${line%%:*}"
    if ! has_doc_comment "$file" "$line_num" && ! grep -qF "origin/master:$file:$line_num:${line#*:}" "$ALLOWLIST"; then
      echo "ERROR: Exported constant without doc comment in $file:"
      echo "$line"
      exit 1
    fi
  done
done

echo "PASS: All exported identifiers have doc comments."