#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The one baseline compare of the four count gates (r5-05):
# @description do_sec_eslint, do_sec_gosec, do_sec_semgrep and do_sec_shellcheck
# @description each turn their tool output into counts per (rule, path) and hand
# @description them here. A count ABOVE its baseline line fails (a new
# @description finding). A count BELOW it fails too: a fixed finding left in the
# @description baseline would let a regression back up to the old count, so the
# @description commit that fixes it lowers the line.
# @description Counts and baseline lines: <rule>|<path>|<count>; # is a comment.
#------------------------------------------------------------------------------

# _sec_baseline_diff <counts> <baseline> [<scope>...]
# Prints a NEW line per (rule, path) counted above its baseline and a LOWER line
# per baseline entry counted below it. Only entries whose path is a <scope> or
# under one are held below (a scan of touched files says nothing about the
# rest); no <scope> holds them all. Exit 2: an unreadable file.
_sec_baseline_diff() {
  python3 - "$@" <<'PY'
import collections, sys
counts, bl, scope = sys.argv[1], sys.argv[2], [s.rstrip("/") for s in sys.argv[3:] if s]
def read(path):
    c = collections.Counter()
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#"):
            rule, p, n = line.rsplit("|", 2)
            c[(rule, p)] += int(n)
    return c
try:
    base, cur = read(bl), read(counts)
except (OSError, ValueError) as e:
    print(f"unreadable: {e}", file=sys.stderr)
    sys.exit(2)
held = lambda p: not scope or any(p == s or p.startswith(s + "/") for s in scope)
for (r, p), n in sorted(cur.items()):
    if n > base.get((r, p), 0):
        print(f"NEW {r} {p}: {n} found, {base.get((r, p), 0)} baselined")
for (r, p), n in sorted(base.items()):
    if held(p) and cur.get((r, p), 0) < n:
        print(f"LOWER {r} {p}: {n} baselined, {cur.get((r, p), 0)} found")
PY
}

# _sec_baseline_gate <tool> <counts> <baseline> [<scope>...]
# Logs the verdict of _sec_baseline_diff; returns 0 only when no line is NEW
# and none is LOWER.
_sec_baseline_gate() {
  local tool="$1" counts="$2" bl="$3" verdict line new="" low="" rc=0
  shift 3
  verdict=$(_sec_baseline_diff "$counts" "$bl" "$@") || rc=$?
  [[ "$rc" -eq 0 ]] || { do_log "FATAL $tool: could not compare against $bl (exit $rc)"; return 1; }
  while IFS= read -r line; do
    case "$line" in
      NEW\ *) new+="  $line"$'\n' ;;
      LOWER\ *) low+="  $line"$'\n' ;;
    esac
  done <<<"$verdict"
  if [[ -n "$new" ]]; then
    do_log "FATAL $tool: NEW finding(s) beyond $bl (fix it, or add a line with the reason):"
    printf '%s' "$new"
    rc=1
  fi
  if [[ -n "$low" ]]; then
    do_log "FATAL $tool: fewer findings than baselined -- lower this line in $bl (delete it at 0 found):"
    printf '%s' "$low"
    rc=1
  fi
  [[ "$rc" -eq 0 ]] && do_log "INFO $tool: no new findings (baseline holds)"
  return "$rc"
}

# _sec_baseline_write <counts> <baseline>
# Rewrites the baseline to the counts, keeping its # lines on top.
_sec_baseline_write() {
  python3 - "$1" "$2" <<'PY'
import sys
counts, bl = sys.argv[1], sys.argv[2]
head = [l for l in open(bl) if l.startswith("#")]
rows = sorted(l.strip() for l in open(counts) if l.strip())
with open(bl, "w") as f:
    f.writelines(head)
    f.writelines(r + "\n" for r in rows)
print("wrote baseline:", sum(int(r.rsplit("|", 1)[1]) for r in rows), "findings")
PY
}
