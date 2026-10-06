#!/bin/bash
#------------------------------------------------------------------------------
# @description The orchestrator's load over a SINCE..UNTIL window, from the
# @description local spool root only (spec 101 T005; r1 research E6..E8). Read
# @description only: no hub, no prd, nothing written.
# @description   E6 - messages that reached the orch (<root>/<ORCH_ID>/{inbox,
# @description        archive}/*.json, by ts, one per msg_id): total, per hour
# @description        (median, max), by sender kind and by message kind
# @description   E7 - the asks book (<root>/asks/*.json, by created_at): asks
# @description        raised by a dispatcher, the dead rate, dead by dispatcher
# @description   E8 - the done asks: re-raise share (raised_n >= 1) and the
# @description        wait created_at..updated_at per raised_n (0, 1, 2, 3+)
# @description Sender kind: orch = c-001 / CLE-001, dispatcher = c-002, c-003 /
# @description CLE-002, CLE-003 (any @box), lane = any other agent id
# @description ([acgq]-NNN, CLE-/GRK-/AGY-/QWN-N), other = the rest.
# @param SINCE (optional) - window start, inclusive: YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z; default UNTIL - 24 h
# @param UNTIL (optional) - window end, exclusive, same forms; default now
# @param ORCH_ID (optional) - the orch's spool dir, default c-001
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @example ./run -a do_spl_orch_load_report
# @example SINCE=2026-10-04 UNTIL=2026-10-06 ./run -a do_spl_orch_load_report
#------------------------------------------------------------------------------
do_spl_orch_load_report() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" orch="${ORCH_ID:-c-001}" since until s_ep u_ep
  do_require_bin jq || return 1
  [[ "$orch" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || { do_log "FATAL ORCH_ID is not an agent id: '$orch'"; return 1; }
  [[ -d "$root/$orch" ]] || { do_log "FATAL no orch spool dir: $root/$orch"; return 1; }
  until="$(spl_orch_load_ts "${UNTIL:-now}")" || return 1
  if [[ -n "${SINCE:-}" ]]; then since="$(spl_orch_load_ts "$SINCE")" || return 1
  else since="$(date -u -d "$until - 24 hours" +%Y-%m-%dT%H:%M:%SZ)"; fi
  s_ep="$(date -u -d "$since" +%s)"; u_ep="$(date -u -d "$until" +%s)"
  (( s_ep < u_ep )) || { do_log "FATAL SINCE ($since) must be before UNTIL ($until)"; return 1; }
  echo "ORCH_LOAD window=$since..$until orch=$orch root=$root"
  spl_orch_load_msgs "$root/$orch" "$since" "$until" | spl_orch_load_msgs_lines "$s_ep" "$u_ep" || return 1
  spl_orch_load_asks "$root/asks" "$since" "$until" | spl_orch_load_asks_lines || return 1
}

# spl_orch_load_ts <when> - "now", YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS]Z ->
# YYYY-MM-DDTHH:MM:SSZ (UTC). Anything else is refused, so no free text
# reaches date(1).
spl_orch_load_ts() {
  local v="$1"
  [[ "$v" == now || "$v" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z)?$ ]] \
    || { do_log "FATAL not a date or UTC timestamp (YYYY-MM-DD[THH:MM[:SS]Z]): '$v'"; return 1; }
  [[ ${#v} -eq 10 ]] && v="${v}T00:00:00Z"
  date -u -d "$v" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || { do_log "FATAL not a valid date: '$1'"; return 1; }
}

# spl_orch_load_msgs <orch dir> <since> <until> - one "<epoch> <sender kind>
# <msg kind>" line per message in the window, each msg_id once.
spl_orch_load_msgs() {
  local d dirs=()
  for d in "$1/inbox" "$1/archive"; do [[ -d "$d" ]] && dirs+=("$d/"); done
  (( ${#dirs[@]} )) || return 0
  find "${dirs[@]}" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null \
    | xargs -0 -r cat | jq -n -r --arg s "$2" --arg u "$3" '
      def kind_of: if test("^(c|CLE)-001(@|$)") then "orch"
        elif test("^(c|CLE)-00[23](@|$)") then "dispatcher"
        elif test("^([acgq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)(@|$)") then "lane"
        else "other" end;
      [inputs | objects | select((.ts // "") >= $s and (.ts // "") < $u)]
      | unique_by(.msg_id // tostring) | .[]
      | "\(.ts | sub("\\.[0-9]+"; "") | fromdateiso8601) \(.from // "" | kind_of) \(.kind // "none")"'
}

# spl_orch_load_msgs_lines <since epoch> <until epoch> - the E6 lines from
# spl_orch_load_msgs rows; an hour with no message counts as 0. POSIX awk
# (CI's is mawk: no asort).
spl_orch_load_msgs_lines() {
  awk -v s="$1" -v u="$2" '
    function pct(a) { return n ? sprintf("%.1f%%", 100 * a / n) : "0.0%" }
    { n++; h[int(($1 - s) / 3600)]++; snd[$2]++; if (!($3 in k)) ks[++nk] = $3; k[$3]++ }
    END {
      hours = int((u - s + 3599) / 3600); max = 0
      for (i = 1; i <= hours; i++) {
        x = h[i - 1] + 0; if (x > max) max = x
        for (j = i - 1; j >= 1 && v[j] > x; j--) v[j + 1] = v[j]
        v[j + 1] = x
      }
      med = hours % 2 ? v[(hours + 1) / 2] : (v[hours / 2] + v[hours / 2 + 1]) / 2
      printf "E6 msgs total=%d hours=%d per_hour_median=%.1f per_hour_max=%d\n", n, hours, med, max
      printf "E6 sender lane=%d (%s) dispatcher=%d (%s) orch=%d (%s) other=%d (%s)\n", \
        snd["lane"], pct(snd["lane"]), snd["dispatcher"], pct(snd["dispatcher"]), \
        snd["orch"], pct(snd["orch"]), snd["other"], pct(snd["other"])
      for (i = 2; i <= nk; i++) for (j = i; j > 1 && ks[j - 1] > ks[j]; j--) { t = ks[j]; ks[j] = ks[j - 1]; ks[j - 1] = t }
      line = "E6 kind"
      for (i = 1; i <= nk; i++) line = line " " ks[i] "=" k[ks[i]]
      print line (nk ? "" : " none")
    }'
}

# spl_orch_load_asks <asks dir> <since> <until> - one "<state> <dispatcher
# 0|1> <raised_n, 3 = 3+> <wait minutes|-1>" line per ask created in the window.
spl_orch_load_asks() {
  [[ -d "$1" ]] || return 0
  find "$1/" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null \
    | xargs -0 -r cat | jq -n -r --arg s "$2" --arg u "$3" '
      def ep: sub("\\.[0-9]+"; "") | fromdateiso8601;
      [inputs | objects | select((.created_at // "") >= $s and (.created_at // "") < $u)]
      | unique_by(.ask_id // tostring) | .[]
      | "\(.state // "none") \(if (.from // "") | test("^(c|CLE)-00[23](@|$)") then 1 else 0 end) \(
          [(.raised_n // 0), 3] | min) \(
          if (.updated_at // "") != "" then ((.updated_at | ep) - (.created_at | ep)) / 60 else -1 end)"'
}

# spl_orch_load_asks_lines - the E7 and E8 lines from spl_orch_load_asks rows
# (sorted by bucket, then wait, so the k-th row of a bucket is its k-th wait).
spl_orch_load_asks_lines() {
  sort -k3,3n -k4,4g | awk '
    function pct(a, b) { return b ? sprintf("%.1f%%", 100 * a / b) : "0.0%" }
    { n++; disp += $2; if ($1 == "dead") { dead++; dd += $2 } }
    $1 == "done" { done++; if ($3 >= 1) rr++; c[$3]++; w[$3, c[$3]] = $4 }
    END {
      printf "E7 asks total=%d dispatcher=%d (%s) dead=%d (%s) dead_dispatcher=%d\n", \
        n, disp, pct(disp, n), dead, pct(dead, n), dd
      printf "E8 done=%d reraised=%d (%s)\n", done, rr, pct(rr, done)
      for (b = 0; b <= 3; b++) {
        m = c[b] + 0; lab = b == 3 ? "3+" : b
        if (!m) { printf "E8 wait raised_n=%s n=0 median_min=- p90_min=-\n", lab; continue }
        med = m % 2 ? w[b, (m + 1) / 2] : (w[b, m / 2] + w[b, m / 2 + 1]) / 2
        p = int(0.9 * m); if (p < 0.9 * m) p++
        printf "E8 wait raised_n=%s n=%d median_min=%.1f p90_min=%.1f\n", lab, m, med, w[b, p]
      }
    }'
}
