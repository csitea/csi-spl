#!/bin/bash
#------------------------------------------------------------------------------
# @description How often a lane session reads the same file, directory listing
# @description or git history again, and what the repeats cost (SPL-2216, item
# @description 7 of the "Grok burns 3-4x" hypotheses of t1 bd5579e7).
# @description A read is a file read tool (claude Read, grok read_file), a
# @description search tool (Grep / Glob, grok grep) or a shell command that only
# @description reads (cat, sed -n, head, tail, ls, find, tree, git log / show /
# @description diff / status, grep, rg). A REPEAT is a call with the same input
# @description as an earlier one of the same session since the last compaction
# @description (after a compaction the model no longer holds the first result)
# @description and the last edit of its file. An OVERLAP read is a file read
# @description (file tool, plain cat / nl / head / sed -n A,Bp) of lines already
# @description read in that span; its tokens are its share of those lines.
# @description CARRIED tokens weigh each result by the model calls after it in
# @description its span: a result is re-sent on every later call, so that is
# @description its share of the session's input.
# @description Tokens are the result's bytes / 4, an estimate: neither harness
# @description records tokens per tool result.
# @description   claude: ~/.claude/projects/*-wt-c-*/<session>.jsonl
# @description   grok:   ~/.grok/sessions/*wt%2Fg-*/<id>/updates.jsonl, result
# @description           size from rawOutput (output_for_prompt, FileContent,
# @description           stdout), input total from usage.json
# @description Prints one row per session, then per vendor: sessions, reads,
# @description repeats and overlaps with their tokens and share of all
# @description tool-result tokens, the repeats per class, and the carried
# @description tokens of repeats, overlaps and all tool results as a share of
# @description the input. Read only; transcripts are read as their agent user
# @description (sudo -n -u).
# @param TOKEN_REREAD_SINCE (optional) - sessions started after this date (default 2 days ago)
# @param TOKEN_REREAD_UNTIL (optional) - and before this date (default now)
# @param TOKEN_REREAD_HOMES (optional, tests) - space-separated homes, read as the current user
# @param TOKEN_REREAD_ROWS (optional) - 0 prints the summary only
# @param TOKEN_REREAD_MIN_READS (optional) - leave out sessions with fewer reads (default 1)
# @example ./run -a do_spl_token_reread
# @example TOKEN_REREAD_SINCE=2026-10-05 TOKEN_REREAD_UNTIL=2026-10-12 TOKEN_REREAD_ROWS=0 ./run -a do_spl_token_reread
#------------------------------------------------------------------------------
do_spl_token_reread() {
  local since="${TOKEN_REREAD_SINCE:-$(date -u -d '2 days ago' +%Y-%m-%dT%H:%M)}"
  local until="${TOKEN_REREAD_UNTIL:-$(date -u -d '+1 minute' +%Y-%m-%dT%H:%M)}"
  local rows u h fns
  declare -F spl_cost_agent_users >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"
  fns="$(declare -f spl_token_reread_read spl_token_reread_session); $(declare -p SPL_REREAD_JQ_CLAUDE SPL_REREAD_JQ_GROK SPL_REREAD_AWK)"
  rows="$(
    if [[ -n "${TOKEN_REREAD_HOMES:-}" ]]; then
      for h in $TOKEN_REREAD_HOMES; do spl_token_reread_read "$h" "$since" "$until"; done
    else
      for u in $(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}"); do
        h="$(getent passwd "$u" | cut -d: -f6)"
        [[ -n "$h" ]] && spl_cost_as "$u" bash -c "$fns; spl_token_reread_read \"\$@\"" _ "$h" "$since" "$until"
      done
    fi | awk -F'\t' -v m="${TOKEN_REREAD_MIN_READS:-1}" '$6 >= m' | sort -t$'\t' -k1,1 -k4,4
  )"
  if [[ "${TOKEN_REREAD_ROWS:-1}" != 0 && -n "$rows" ]]; then
    printf 'vendor\tlane\tsession\tstart\tinput_tok\treads\tunique\trepeats\trepeat_tok\toverlap_reads\toverlap_tok\ttool_tok\trepeat_share\tby_class\tcalls\trepeat_input\toverlap_input\ttool_input\n'
    printf '%s\n' "$rows"
  fi
  printf '%s\n' "$rows" | awk -F'\t' -v since="$since" -v until="$until" '
    NF >= 18 {
      v = $1; n[v]++; rd[v] += $6; rp[v] += $8; rt[v] += $9; pp[v] += $10; pt[v] += $11; tt[v] += $12; it[v] += $5
      sh[v] = sh[v] " " $9 / ($12 > 0 ? $12 : 1)
      wr[v] += $16; wo[v] += $17; wt[v] += $18
      m = split($14, c, ","); for (i = 1; i <= m; i++) if (split(c[i], kv, "=") == 2) cls[v, kv[1]] += kv[2]
    }
    END {
      printf "re-reads, sessions started %s .. %s (tokens = result bytes / 4)\n", since, until
      for (v in n) {
        k = split(substr(sh[v], 2), a, " ")
        for (i = 2; i <= k; i++) { x = a[i]; for (j = i - 1; j >= 1 && a[j] + 0 > x + 0; j--) a[j + 1] = a[j]; a[j + 1] = x }
        by = ""; split("file grep tree cat git", cn, " ")
        for (i = 1; i <= 5; i++) by = by sprintf("%s%s=%d", i > 1 ? "," : "", cn[i], cls[v, cn[i]])
        printf "%s sessions=%d reads=%d repeats=%d repeat_tok=%d share=%.1f%% session_p50=%.1f%% session_max=%.1f%% overlap_reads=%d overlap_tok=%d overlap_share=%.1f%% tool_tok=%d by_class=%s\n",
          v, n[v], rd[v], rp[v], rt[v], 100 * rt[v] / (tt[v] > 0 ? tt[v] : 1), 100 * a[int((k + 1) / 2)], 100 * a[k],
          pp[v], pt[v], 100 * pt[v] / (tt[v] > 0 ? tt[v] : 1), tt[v], by
        printf "%s input_tok=%d carried: repeats=%d (%.2f%% of input) overlaps=%d (%.2f%% of input) all tool results=%d (%.1f%% of input)\n",
          v, it[v], wr[v], 100 * wr[v] / (it[v] > 0 ? it[v] : 1), wo[v], 100 * wo[v] / (it[v] > 0 ? it[v] : 1), wt[v], 100 * wt[v] / (it[v] > 0 ? it[v] : 1)
      }
      if (length(n) == 0) print "no lane session in the window"
    }'
}

# spl_token_reread_read HOME SINCE UNTIL: one row per lane session of HOME
# started in the window. Runs as HOME's user.
spl_token_reread_read() {
  local home="$1" since="$2" until="$3" f d lane ts sid input
  {
  while IFS= read -r f; do
    d="${f%/updates.jsonl}" lane="${d%/*}" lane="${lane##*%2F}" sid="${d##*/}"
    ts="$(date -u -r "$d/system_prompt.txt" +%Y-%m-%dT%H:%M 2>/dev/null)" || continue
    [[ "$ts" < "$since" || ! "$ts" < "$until" ]] && continue
    input="$(jq -r '.session.inputTokens // 0' "$d/usage.json" 2>/dev/null)"
    jq -rn "$SPL_REREAD_JQ_GROK" <"$f" 2>/dev/null | spl_token_reread_session grok "$lane" "$sid" "$ts" "${input:-0}"
  done < <(find "$home/.grok/sessions" -mindepth 3 -maxdepth 3 -path '*wt%2Fg-*' -name updates.jsonl \
    -newermt "$since" 2>/dev/null)
  while IFS= read -r f; do
    lane="${f%/*}" lane="${lane##*-wt-}" sid="$(basename "$f" .jsonl)"
    ts="$(grep -m1 -o '"timestamp":"[^"]*"' "$f" | cut -d'"' -f4 | cut -c1-16)"
    [[ -z "$ts" || "$ts" < "$since" || ! "$ts" < "$until" ]] && continue
    jq -rn "$SPL_REREAD_JQ_CLAUDE" <"$f" 2>/dev/null | spl_token_reread_session claude "$lane" "$sid" "$ts" 0
  done < <(find "$home/.claude/projects" -mindepth 2 -maxdepth 2 -path '*-wt-c-*' -name '*.jsonl' \
    -newermt "$since" 2>/dev/null)
  } 2>/dev/null
}

# spl_token_reread_session VENDOR LANE SESSION START INPUT: the event stream of
# one session (stdin, from a SPL_REREAD_JQ_* filter) to its row.
spl_token_reread_session() {
  awk -F'\t' -v OFS='\t' -v vendor="$1" -v lane="$2" -v sid="$3" -v ts="$4" -v input="$5" "$SPL_REREAD_AWK"
}

# Each filter prints, in transcript order: "C" at a compaction, "I<TAB>tokens"
# per model call (claude), "E<TAB>path" per file edit tool call, and per
# finished tool call "T<TAB>class<TAB>bytes<TAB>key<TAB>path<TAB>first
# line<TAB>lines" (class "-" for a call that is not a read; path "" when the
# call reads no one known range of one file).
SPL_REREAD_JQ_CLASSIFY='
  def shstrip:
    gsub("\\s+"; " ") | sub("^ "; "")
    | sub("^sudo -u \\S+ bash -c [\"'\'']"; "")
    | sub("^((cd [^ ;&]+|exec 2>&1|set -[a-z]+) ?(&&|;) ?)+"; "");
  def shclass:
    shstrip
    | if test("^(cat|head|tail|nl|less) ") or test("^sed -n ") then "cat"
      elif test("^(ls|find|tree|du)( |$)") then "tree"
      elif test("^git (-C \\S+ )?(--no-pager )?(log|show|diff|status|ls-files|blame|grep)( |$)") then "git"
      elif test("^(grep|rg|ugrep|ag) ") then "grep"
      else "-" end;
  # The one file a plain cat / nl / head / sed -n A,Bp reads and its first
  # line, else ["", 0] (tail: its first line is unknown).
  def shread:
    shstrip | sub("[\"'\'']$"; "") as $c
    | if ($c | test("[;|&<>]")) or ($c | shclass) != "cat" or ($c | test("^(tail|less) ")) then ["", 0]
      else [($c | split(" ") | last | gsub("[\"'\'']"; "")),
            ($c | (capture("^sed -n [\"'\'']?(?<a>[0-9]+)") | .a | tonumber) // 1)] end;
  def nlines: if type == "string" then (split("\n") | length) else 0 end;
  def key($tool; $in): ($in | if type == "object" then del(.description) else . end | tojson | gsub("\t"; " ")) as $j | "\($tool) \($j)";
  def trow($cl; $bytes; $key; $rd; $lines): "T\t\($cl)\t\($bytes)\t\($key)\t\($rd[0])\t\($rd[1])\t\($lines)";'
SPL_REREAD_JQ_CLAUDE="$SPL_REREAD_JQ_CLASSIFY"'
  def ctext: if type == "string" then . elif type == "array" then (map(.text // "") | join("\n")) else "" end;
  foreach inputs as $r ({calls: {}, seen: {}, out: []};
    .out = []
    | if $r.type == "system" and $r.subtype == "compact_boundary" then .out = ["C"]
      elif $r.type == "assistant" then
        (if ($r.message.id // "") != "" and (.seen[$r.message.id] | not) and $r.message.usage != null then
           .seen[$r.message.id] = true
           | .out += [ "I\t\($r.message.usage | (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))" ]
         else . end)
        | reduce ($r.message.content // [] | if type == "array" then .[] else empty end | select(.type == "tool_use")) as $u (.;
            .calls[$u.id] = {name: $u.name, input: $u.input})
      elif $r.type == "user" then
        reduce ($r.message.content // [] | if type == "array" then .[] else empty end | select(.type == "tool_result")) as $t (.;
          (.calls[$t.tool_use_id] // {name: "?", input: {}}) as $c | ($t.content | ctext) as $x
          | ($c.name | if . == "Read" then "file" elif . == "Grep" then "grep" elif . == "Glob" then "tree"
              elif . == "Bash" then ($c.input.command // "" | shclass) else "-" end) as $cl
          | (if $cl == "file" then [$c.input.file_path // "", ($c.input.offset // 1)]
             elif $cl == "cat" then ($c.input.command | shread) else ["", 0] end) as $rd
          | .out += [ trow($cl; $x | length; key($c.name; $c.input); $rd; $x | nlines) ]
          | if ($c.name | test("^(Edit|Write|MultiEdit|NotebookEdit)$")) then .out += [ "E\t\($c.input.file_path // $c.input.notebook_path // "")" ] else . end
          | del(.calls[$t.tool_use_id]))
      else . end;
    .out[]) | gsub("\n"; " ")'
SPL_REREAD_JQ_GROK="$SPL_REREAD_JQ_CLASSIFY"'
  foreach inputs as $r ({calls: {}, call: null, out: []};
    .out = [] | ($r.params.update // {}) as $u
    | ($r.params._meta.streamStartMs // .call) as $m
    | (if $m != .call then .out = ["I\t0"] | .call = $m else . end)
    | if $u.sessionUpdate == "auto_compact_completed" then .out += ["C"]
      elif $u.sessionUpdate == "tool_call" then .calls[$u.toolCallId] = {name: $u.title, input: ($u.rawInput // {})}
      elif $u.sessionUpdate == "tool_call_update" and $u.status == "completed" and .calls[$u.toolCallId] != null then
        .calls[$u.toolCallId] as $c | ($u.rawOutput // {}) as $o
        | ($c.name | if . == "read_file" then "file" elif . == "grep" then "grep"
            elif . == "run_terminal_command" then ($c.input.command // "" | shclass) else "-" end) as $cl
        | ($o | if .type == "ReadFile" then .FileContent.content elif .type == "Bash" then (.output_for_prompt // "")
            elif .type == "GrepSearch" then .stdout else tostring end
            | if type == "array" then (implode? // "") elif type == "string" then . else "" end) as $x
        | (if $cl == "file" then [$c.input.target_file // "", ($c.input.offset // 1)]
           elif $cl == "cat" then ($c.input.command | shread) else ["", 0] end) as $rd
        | .out += [ trow($cl; $x | length; key($c.name; $c.input); $rd; $x | nlines) ]
        | if ($c.name | test("^(search_replace|write)$")) then .out += [ "E\t\($c.input.file_path // "")" ] else . end
        | del(.calls[$u.toolCallId])
      else . end;
    .out[]) | gsub("\n"; " ")'
# Row: vendor lane session start input_tok reads unique repeats repeat_tok
# overlap_reads overlap_tok tool_tok repeat_share by_class. input_tok: claude
# sums its calls' usage, grok takes usage.json. A repeat: the same call input
# since the last compaction and the last edit of its file. An overlap read: a file read whose lines were
# already read since the last compaction and the last edit of that file (file
# tools, plain cat / nl / head / sed -n); its tokens are its share of lines
# already read.
SPL_REREAD_AWK='
  # covered PATH A B: lines of [A, B) already read; adds them to cov[PATH].
  function covered(p, a0, b0,    n, i, iv, s, e, o, a, b, ns, list) {
    n = split(cov[p], list, " "); o = 0; a = a0; b = b0
    for (i = 1; i <= n; i++) {
      split(list[i], iv, "-"); s = iv[1] + 0; e = iv[2] + 0
      if (e < a0 || s > b0) { ns = ns " " list[i]; continue }
      if (e > a0 && s < b0) o += (e < b0 ? e : b0) - (s > a0 ? s : a0)
      if (s < a) a = s; if (e > b) b = e
    }
    cov[p] = ns " " a "-" b
    return o
  }
  # A result stays in the context of every later call of its segment (up to
  # the next compaction): its input cost is tok x the calls after it.
  function carry(k, t) { st[k] += t; sti[k] += t * calls }
  function flush(   k) { for (k in st) { w[k] += st[k] * calls - sti[k] }; delete st; delete sti }
  $1 == "C" { flush(); delete seen; delete cov; next }
  $1 == "E" { delete cov[$2]; for (k in seen) if (seenp[k] == $2) delete seen[k]; next }
  $1 == "I" { in_sum += $2; calls++; next }
  $1 == "T" {
    tok = int(($3 + 3) / 4); tool += tok; carry("tool", tok)
    if ($2 == "-") next
    reads++
    if (!(($4) in ever)) { ever[$4] = 1; uniq++ }
    if (($4) in seen) { rep++; rtok += tok; rc[$2]++; carry("rep", tok) } else { seen[$4] = 1; seenp[$4] = $5 }
    if ($5 != "" && $7 > 0) {
      o = covered($5, $6 + 0, $6 + $7)
      if (o > 0) { orep++; otok += tok * o / $7; carry("ovl", tok * o / $7) }
    }
  }
  END {
    flush()
    if (input == 0) input = in_sum
    by = ""; split("file grep tree cat git", cn, " ")
    for (i = 1; i <= 5; i++) by = by sprintf("%s%s=%d", i > 1 ? "," : "", cn[i], rc[cn[i]])
    printf "%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%.1f%%\t%s\t%d\t%d\t%d\t%d\n", vendor, lane, sid, ts, input, reads, uniq, rep, rtok,
      orep, otok, tool, 100 * rtok / (tool > 0 ? tool : 1), by, calls, w["rep"], w["ovl"], w["tool"]
  }'
