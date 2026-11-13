#!/bin/bash
# Usage: bash forkbash.sh <0|1> [<checkout>] [<forks>]
#   1 = source every csi-spl-orc/src/bash/run/*.func.sh first (what ./run does),
#   0 = plain bash. Prints RSS, page tables and wall per $( ) fork to stderr.
#   Run under rus.py for CPU: python3 -I rus.py sys bash forkbash.sh 1 <checkout>
mode="${1:?0 or 1}"; root="${2:-$(git rev-parse --show-toplevel)}"; forks="${3:-500}"
if [ "$mode" = 1 ]; then
  while IFS= read -r f; do
    # shellcheck disable=SC1090
    source "$f" >/dev/null 2>&1
  done < <(find "$root/csi-spl-orc/src/bash/run" -name '*.func.sh')
fi
grep -E 'VmRSS|VmPTE' "/proc/$$/status" | tr '\n' ' ' >&2
s=$(date +%s%N)
for ((i = 0; i < forks; i++)); do x=$(:); done
e=$(date +%s%N)
[ "$forks" -gt 0 ] && echo " forks=$forks wall_per_fork_us=$(( (e - s) / forks / 1000 ))${x:-}" >&2
true
