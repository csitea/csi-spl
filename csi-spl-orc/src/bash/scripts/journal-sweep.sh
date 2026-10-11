#!/usr/bin/env bash
# journal-sweep.sh - vacuum the systemd journal to BOX_SWEEP_JOURNAL_MAX
# (default 500M) with `journalctl --vacuum-size`. Dry run unless DRY_RUN=0.
# Prints the journal size in bytes before, and after a live vacuum.
# A dry run never calls sudo. A live run uses `sudo -n` so cron cannot block
# on a password prompt.

set -uo pipefail

dry="${DRY_RUN:-1}"
max="${BOX_SWEEP_JOURNAL_MAX:-500M}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# journal_bytes - integer bytes from `journalctl --disk-usage`, or unmeasured.
# Real line: "Archived and active journals take up 40M in the file system."
# A lone size token such as 300B (a test stub) is accepted too.
journal_bytes() {
  local line
  if ! command -v journalctl >/dev/null 2>&1; then
    printf '%s\n' unmeasured
    return 0
  fi
  line="$(journalctl --disk-usage 2>/dev/null || true)"
  printf '%s\n' "$line" | awk '
    function scale(tok,   n, u, m) {
      if (match(tok, /^[0-9]+(\.[0-9]+)?/)) {
        n = substr(tok, RSTART, RLENGTH) + 0
        u = substr(tok, RSTART + RLENGTH, 1)
        m = 1
        if (u == "K") m = 1024
        else if (u == "M") m = 1048576
        else if (u == "G") m = 1073741824
        else if (u == "T") m = 1099511627776
        return int(n * m)
      }
      return -1
    }
    {
      line_tok = ""
      for (i = 1; i <= NF; i++)
        if ($i ~ /^[0-9]+(\.[0-9]+)?[KMGT]?B?$/) line_tok = $i
      if (line_tok == "") next
      if ($0 ~ /take up/) { tok = line_tok; locked = 1 }
      else if (!locked) tok = line_tok
    }
    END {
      if (tok == "") { print "unmeasured"; exit }
      v = scale(tok)
      if (v < 0) print "unmeasured"
      else print v
    }
  '
}

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
[[ "$max" =~ ^[0-9]+[KMGT]?$ ]] || { say "FAIL BOX_SWEEP_JOURNAL_MAX must be a size like 500M, got '$max'"; exit 2; }

before="$(journal_bytes)"
say "START journal sweep dry_run=$dry max=$max before=$before"

if [[ "$dry" == 1 ]]; then
  say "PLAN journalctl --vacuum-size=$max"
  say "DONE journal sweep (dry run)"
  exit 0
fi

if ! command -v journalctl >/dev/null 2>&1; then
  say "FAIL journalctl not found"
  exit 1
fi

sudo -n journalctl --vacuum-size="$max"
rc=$?
after="$(journal_bytes)"
say "DONE journalctl --vacuum-size=$max rc=$rc after=$after"
exit "$rc"
