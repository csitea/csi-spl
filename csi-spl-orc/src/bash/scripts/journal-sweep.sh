#!/usr/bin/env bash
# journal-sweep.sh - vacuum the systemd journal to BOX_SWEEP_JOURNAL_MAX
# (default 500M) with `journalctl --vacuum-size`. Dry run unless DRY_RUN=0.
# Prints the journal size in bytes before, and after a live vacuum.
# A dry run never calls sudo. A live run uses `sudo -n` so cron cannot block
# on a password prompt.
# The vacuum never goes below the box's journald cap (SystemMaxUse, last
# assignment in `systemd-analyze cat-config`): a cap above the max is the size.
# An unreadable or unparsable cap keeps the max and never fails the sweep.

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

# journald_cap - the effective SystemMaxUse as journald reads it, empty if none
# or unreadable. BOX_SWEEP_JOURNALD_CAT replaces the reader (tests).
journald_cap() {
  local reader=(systemd-analyze cat-config systemd/journald.conf) out
  [[ -n "${BOX_SWEEP_JOURNALD_CAT:-}" ]] && reader=("$BOX_SWEEP_JOURNALD_CAT")
  out="$("${reader[@]}" 2>/dev/null)" || return 0
  awk '/^[[:space:]]*SystemMaxUse[[:space:]]*=/ { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v) } END { print v }' <<<"$out" 2>/dev/null
}

# size_above <a> <b> - true when size a is more bytes than size b
size_above() {
  awk -v a="$1" -v b="$2" '
    function bytes(s,   i) { i = index("KMGTPE", substr(s, length(s), 1)); return (s + 0) * (i ? 1024 ^ i : 1) }
    BEGIN { exit !(bytes(a) > bytes(b)) }' 2>/dev/null
}

[[ "$dry" == 0 || "$dry" == 1 ]] || { say "FAIL DRY_RUN must be 0 or 1, got '$dry'"; exit 2; }
[[ "$max" =~ ^[0-9]+[KMGT]?$ ]] || { say "FAIL BOX_SWEEP_JOURNAL_MAX must be a size like 500M, got '$max'"; exit 2; }

cap="$(journald_cap)"
if [[ -n "$cap" && ! "$cap" =~ ^[0-9]+(\.[0-9]+)?[BKMGTPE]?$ ]]; then
  say "WARN journald SystemMaxUse='$cap' is not a size: vacuuming to max=$max"
elif [[ -n "$cap" ]] && size_above "$cap" "$max"; then
  say "INFO journald cap SystemMaxUse=$cap is above max=$max: vacuuming to the cap"
  max="$cap"
fi

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
