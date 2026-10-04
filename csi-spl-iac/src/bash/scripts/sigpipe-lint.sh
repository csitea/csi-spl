#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: flag an EARLY-EXIT consumer after a producer under `set -o pipefail`
#          (the lint-sigpipe part of do_check_pre_push_lint).
#   `producer | grep -q x` / `| grep -m1` / `| head -1`: the consumer exits on
#   its first match or line, the producer's next write dies of SIGPIPE (141),
#   and pipefail reports the whole pipeline FALSE although the match was there.
#   Five fixes in three days (56336ac6 4d2777b4 590eb23c 980ea596 d1e3f112),
#   each red only under load, so a green run never proved the site safe.
# Scope: .sh files that set pipefail, and every *.func.sh (sourced by ./run,
#   which sets `set -u -o pipefail`). Heredoc bodies, comment lines and
#   quoted text that runs no command are not shell code here and are skipped.
# Fix forms (none exits early, so the producer always finishes):
#   | grep -q x      ->  | grep x >/dev/null   (GNU grep reads to the end)
#   | head -1        ->  | sed -n 1p           (| head -n N -> | sed -n 1,Np)
#   printf/echo "$v" | grep -q x  ->  grep -q x <<<"$v"   (no pipe at all)
#   or capture first:  out="$(producer)"; grep -q x <<<"$out"
# Opt-out: a reviewed safe site carries `# sigpipe-ok: <why>` on that line
#   (or on any line of a continued pipeline). It is listed, never silent.
# Also exempt: the consumer directly followed by `|| true` / `|| :` (the
#   pipeline's status is discarded, so SIGPIPE cannot change anything).
# Usage:   sigpipe-lint.sh [--list-optouts] <file>...
# Exit:    0 clean, 1 findings, 2 usage
#------------------------------------------------------------------------------
set -u

list_optouts=0
[[ "${1:-}" == --list-optouts ]] && { list_optouts=1; shift; }
[[ "$#" -gt 0 ]] || { echo "usage: $0 [--list-optouts] <file>..." >&2; exit 2; }

rc=0
for f in "$@"; do
  [[ -f "$f" ]] || continue
  is_func=0; [[ "$f" == *.func.sh ]] && is_func=1
  awk -v F="$f" -v FUNC="$is_func" -v LIST="$list_optouts" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # The early-exit consumer a pipe segment starts with, or "".
    function consumer(seg,   cmd, n, w, i) {
      seg = trim(seg); sub(/^&[ \t]*/, "", seg); sub(/^command[ \t]+/, "", seg)
      cmd = seg; sub(/[;)<>].*$/, "", cmd); sub(/&&.*$/, "", cmd); sub(/OROR.*$/, "", cmd)
      n = split(cmd, w, /[ \t]+/)
      if (w[1] == "head") {   # head -n -N / --lines=-N reads to the end
        if ((w[2] == "-n" && w[3] ~ /^-/) || w[2] ~ /^(-n-|--lines=-)/) return ""
        return "head"
      }
      if (w[1] != "grep" && w[1] != "egrep" && w[1] != "fgrep") return ""
      for (i = 2; i <= n; i++) {
        if (w[i] == "--") break
        if (w[i] ~ /^--(quiet|silent|max-count)/) return "grep " w[i]
        if (w[i] ~ /^-[A-Za-z0-9]*[qm]/) return "grep " w[i]
      }
      return ""
    }
    # The line with its data blanked: quoted text (but not a $(...) or `...`
    # inside "..."), escaped chars and a trailing comment. Code stays as is.
    function code_only(s,   out, i, n, c, nx, top, sp, stk, j) {
      out = ""; n = length(s); sp = 1; stk[1] = "N"
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1); nx = substr(s, i + 1, 1); top = stk[sp]
        if (c == "\\") { out = out "__"; i++; continue }
        if (top == "D") {
          if (c == "\"") { sp--; out = out c }
          else if (c == "$" && nx == "(") { stk[++sp] = "C"; out = out "$("; i++ }
          else if (c == "`") { stk[++sp] = "B"; out = out c }
          else out = out "_"
          continue
        }
        if (c == "\047") {
          j = index(substr(s, i + 1), "\047"); if (j == 0) j = n - i
          out = out "\047\047"; i += j; continue
        }
        if (c == "\"") { stk[++sp] = "D"; out = out c; continue }
        if (c == "$" && nx == "(") { stk[++sp] = "C"; out = out "$("; i++; continue }
        if (c == "(" && top == "C") { stk[++sp] = "C"; out = out c; continue }
        if (c == ")" && top == "C") { sp--; out = out c; continue }
        if (c == "`") { if (top == "B") sp--; else stk[++sp] = "B"; out = out c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t;]/)) break
        out = out c
      }
      return out
    }
    function check(s, ln,   t, n, seg, i, c, rest) {
      t = code_only(s)
      gsub(/\|\|/, " OROR ", t)
      n = split(t, seg, /\|/)
      for (i = 2; i <= n; i++) {
        c = consumer(seg[i])
        if (c == "") continue
        rest = seg[i]; if (!sub(/^.*OROR/, "OROR", rest)) rest = ""
        if (rest ~ /^OROR[ \t]*(true|:)([ \t;)]|$)/ && seg[i] !~ /&&/) continue
        if (s ~ /#[ \t]*sigpipe-ok/) {
          optouts++
          if (LIST) printf "%s:%d: OPT-OUT %s -- %s\n", F, ln, c, trim(substr(s, index(s, "sigpipe-ok")))
          return
        }
        printf "%s:%d: SIGPIPE `| %s` after a producer under pipefail exits early; the producer dies of SIGPIPE (141) and the pipeline reads FALSE -- use `grep ... >/dev/null`, `sed -n 1p`, a here-string, or mark a reviewed site `# sigpipe-ok: <why>`\n", F, ln, c
        found++
        return
      }
    }
    BEGIN { pf = (FUNC == 1); found = 0; optouts = 0; buf = ""; hd = "" }
    {
      line = $0
      if (hd != "") {                              # inside a heredoc body
        t = line; if (hdstrip) sub(/^\t+/, "", t)
        if (t == hd) hd = ""
        next
      }
      if (buf == "" && line ~ /^[ \t]*#/) next
      if (line ~ /^[ \t]*set[ \t].*pipefail/) pf = 1
      if (buf == "") start = NR
      buf = buf " " line
      # a heredoc opens on this line: skip its body (never <<<)
      t = line; gsub(/<<</, "", t)
      if (t !~ /\(\(/ && match(t, /<<-?[ \t]*[\047"\\]?[A-Za-z_][A-Za-z0-9_]*/)) {
        w = substr(t, RSTART, RLENGTH); hdstrip = (w ~ /^<<-/)
        sub(/^<<-?[ \t]*[\047"\\]?/, "", w); hd = w
      }
      if (hd == "" && line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", buf); next }
      if (hd == "" && line ~ /[^|]\|[ \t]*$/) next
      L[++nl] = buf; S[nl] = start; buf = ""
    }
    END {
      if (buf != "") { L[++nl] = buf; S[nl] = start }
      if (!pf) exit 0
      for (i = 1; i <= nl; i++) check(L[i], S[i])
      exit (found > 0)
    }' "$f" || rc=1
done
exit "$rc"
