#!/bin/bash
# Usage: [GLIBC_TUNABLES=...] bash thpcheck.sh [<checkout>]
# Sources every csi-spl-orc action file (what ./run does) and prints the
# shell's RSS and how much of it sits on transparent huge pages.
root="${1:-$(git rev-parse --show-toplevel)}"
while IFS= read -r f; do
  # shellcheck disable=SC1090
  source "$f" >/dev/null 2>&1
done < <(find "$root/csi-spl-orc/src/bash/run" -name '*.func.sh')
grep -E '^(Rss|AnonHugePages)' "/proc/$$/smaps_rollup" | tr -s ' ' | tr '\n' ' ' >&2
echo >&2
