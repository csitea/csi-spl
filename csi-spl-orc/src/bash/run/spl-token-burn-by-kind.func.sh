#!/bin/bash
#------------------------------------------------------------------------------
# @description Tokens per finished lane BY TASK KIND (spec 115 kinds), Grok
# @description against Claude (SPL-2577, item 3 of the "Grok burns 3-4x"
# @description hypotheses of t1 bd5579e7: route to Grok only the kinds where it
# @description does not cost more). Read only, from the hub's token record:
# @description   tokens   fleet_token_burn_events (spec 140), one lane = one
# @description            (box, agent id, vendor) over the window; role seats
# @description            001..003 and unattributed rows left out
# @description   kind     the lane's branch (fleet_lanes) names its brief slug;
# @description            the brief's "Kind:" (spl_lane_mix_brief_kind, the
# @description            picker's own read) under $SPOOL_ROOT/dispatch/briefs,
# @description            else the kind its queue ask names (fleet_asks
# @description            placement <vendor>:<slug>, "lane_mix <kind>" /
# @description            "kind <kind>"), else `unkinded` (the picker routes
# @description            that one as simple_coding)
# @description A lane counts once FINISHED: its last minute is over
# @description TOKEN_KIND_IDLE_MIN old, and its first minute is over
# @description TOKEN_KIND_IDLE_MIN after both the window start and its
# @description vendor's first minute in the whole record (claude's collector
# @description began 2026-10-16: a lane already running then is cut).
# @description total = in + out + cache read + cache write; uncached = total
# @description minus cache read. Prints one row per lane (TOKEN_KIND_LANES=1),
# @description then per kind and vendor: n, median total and uncached tokens,
# @description and the median ratio of grok to claude. A kind is over when both
# @description cells hold n >= TOKEN_KIND_MIN_N and the ratio is over
# @description TOKEN_KIND_OVER: the last line is `grok_over=<kinds>|none`.
# @param ENV (optional) - the hub to read, default prd
# @param TOKEN_KIND_DAYS (optional) - the window, default 7
# @param TOKEN_KIND_IDLE_MIN (optional) - default 60
# @param TOKEN_KIND_MIN_N (optional) - default 3
# @param TOKEN_KIND_OVER (optional) - default 2 (grok > 2x claude)
# @param TOKEN_KIND_LANES (optional) - 1 prints the per-lane rows too
# @param TOKEN_KIND_ROWS (optional, tests) - a file of the query's rows instead of the hub
# @param TOKEN_KIND_BRIEFS (optional) - the briefs dir, default $SPOOL_ROOT/dispatch/briefs
# @example ENV=prd ./run -a do_spl_token_burn_by_kind
# @example ENV=prd TOKEN_KIND_DAYS=14 TOKEN_KIND_LANES=1 ./run -a do_spl_token_burn_by_kind
#------------------------------------------------------------------------------
TOKEN_KIND_KINDS="specs_and_docs tests simple_coding complex_coding i18n secret orchestration"

do_spl_token_burn_by_kind() {
  local days="${TOKEN_KIND_DAYS:-7}" rows kinds
  local briefs="${TOKEN_KIND_BRIEFS:-${SPOOL_ROOT:-/var/spool-hub}/dispatch/briefs}"
  [[ "$days" =~ ^[1-9][0-9]?$ ]] || { do_log "FATAL TOKEN_KIND_DAYS must be 1..99, got '$days'"; return 1; }
  declare -F spl_lane_mix_brief_kind >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-mix.func.sh"
  if [[ -n "${TOKEN_KIND_ROWS:-}" ]]; then
    rows="$(cat "$TOKEN_KIND_ROWS")" || return 1
  else
    rows="$(ENV="${ENV:-prd}" SQL="$(spl_token_kind_sql "$days")" do_spl_db_query)" || return 1
  fi
  rows="$(sed -nE 's/^ *([TLANF]) @@ /\1\t/p' <<<"$rows" | sed 's/ @@ /\t/g')"
  [[ -n "$rows" ]] || { do_log "FATAL no rows from the token record"; return 1; }
  kinds="$(spl_token_kind_slugs "$rows" "$briefs")"
  spl_token_kind_table "$rows" "$kinds"
}

# spl_token_kind_sql <days> -> ONE statement, every row "<tag> @@ <field> @@ ...":
# N the hub's now, F each vendor's first minute in the record, T the tokens
# per lane, L the lane branches, A the ask kinds
spl_token_kind_sql() {
  local w="interval '$1 days'" w2="interval '$(( $1 + 5 )) days'"
  local rx="'(?:lane_mix|[Kk]ind|LANE_MIX_KIND=|SPAWN_KIND=)[:= ]*(${TOKEN_KIND_KINDS// /|})'"
  printf '%s' "select concat_ws(' @@ ', 'N', extract(epoch from now())::bigint)
    union all select concat_ws(' @@ ', 'F', vendor, extract(epoch from min(minute_bucket))::bigint)
      from fleet_token_burn_events group by vendor
    union all select concat_ws(' @@ ', 'T', box_tag, agent_id, vendor, sum(tokens_in), sum(tokens_out),
      sum(cache_read), sum(cache_write), extract(epoch from min(minute_bucket))::bigint,
      extract(epoch from max(minute_bucket))::bigint)
      from fleet_token_burn_events where minute_bucket > now() - $w group by box_tag, agent_id, vendor
    union all select concat_ws(' @@ ', 'L', agent_id, agent_box, branch) from (select distinct agent_id,
      agent_box, branch from fleet_lanes where branch <> '' and updated_at > now() - $w2) l
    union all select concat_ws(' @@ ', 'A', split_part(placement, ':', 2), substring(summary from $rx))
      from fleet_asks where placement like '%:%' and created_at > now() - $w2"
}

# spl_token_kind_slugs <rows> <briefs-dir> -> "<agent>\t<box>\t<kind>\t<source>\t<slug>"
# per L row: the brief's Kind first, then the ask's, else unkinded
spl_token_kind_slugs() {
  local tag a box br slug c k f src
  declare -A ask=()
  while IFS=$'\t' read -r tag a k _; do
    [[ "$tag" == A && -n "$k" ]] && ask[$a]="$k"
  done <<<"$1"
  while IFS=$'\t' read -r tag a box br; do
    [[ "$tag" == L ]] || continue
    slug="${br#"$a"-}" k="" src=none
    for c in $(spl_token_kind_variants "$slug"); do
      f="$2/$c.md"
      [[ -r "$f" ]] || continue
      k="$(spl_token_kind_norm "$(spl_lane_mix_brief_kind "$f")")"
      [[ -n "$k" ]] && { src=brief; break; }
    done
    if [[ -z "$k" ]]; then
      for c in $(spl_token_kind_variants "$slug"); do
        [[ -n "${ask[$c]:-}" ]] && { k="${ask[$c]}" src=ask; break; }
      done
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$box" "${k:-unkinded}" "$src" "$slug"
  done <<<"$1"
}

# spl_token_kind_variants <slug> -> the brief names a branch slug stands for:
# the dispatcher prefixes (c001-, c002-, g001-, g002-) a branch drops, and the
# hand-placed prefixes (<box>hand-, hand-<box>-) it keeps
spl_token_kind_variants() {
  local s="$1" p
  echo "$s"
  for p in c001- c002- g001- g002-; do echo "$p$s"; done
  [[ "$s" =~ ^([a-z0-9]+hand|hand-[a-z0-9]+)-(.+)$ ]] && echo "${BASH_REMATCH[2]}"
  return 0
}

# spl_token_kind_norm <word> -> the spec 115 kind (the picker's aliases), else nothing
spl_token_kind_norm() {
  case "$1" in
    spec|review|code_review) echo specs_and_docs ;;
    hard) echo complex_coding ;;
    *) [[ -n "$1" && " $TOKEN_KIND_KINDS " == *" $1 "* ]] && echo "$1" ;;
  esac
  return 0
}

# spl_token_kind_table <rows> <kinds> -> the per-lane rows, the per kind x
# vendor table and the grok_over verdict
spl_token_kind_table() {
  awk -F'\t' -v kinds="$TOKEN_KIND_KINDS unkinded" -v idle="${TOKEN_KIND_IDLE_MIN:-60}" \
      -v minn="${TOKEN_KIND_MIN_N:-3}" -v over="${TOKEN_KIND_OVER:-2}" -v lanes="${TOKEN_KIND_LANES:-0}" \
      -v days="${TOKEN_KIND_DAYS:-7}" '
    function med(s,   a, n, i, j, x) {
      n = split(substr(s, 2), a, " ")
      for (i = 2; i <= n; i++) { x = a[i] + 0; for (j = i - 1; j >= 1 && a[j] + 0 > x; j--) a[j + 1] = a[j]; a[j + 1] = x }
      return n % 2 ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
    }
    FNR == NR { if (!(($2 SUBSEP $1) in kd)) { kd[$2, $1] = $3; ks[$2, $1] = $4; sl[$2, $1] = $5 }; next }
    $1 == "N" { now = $2; next }
    $1 == "F" { first[$2] = $3; next }
    $1 == "T" && ($4 == "claude" || $4 == "grok") {
      if ($3 !~ /^[cg]-[0-9][0-9][0-9]$/ || $3 ~ /-00[1-9]$/) next
      i = ++m; box[i] = $2; ag[i] = $3; vd[i] = $4; t0[i] = $9; t1[i] = $10
      tot[i] = $5 + $6 + $7 + $8; unc[i] = $5 + $6 + $8
    }
    END {
      if (lanes == 1) print "vendor\tbox\tlane\tkind\tsource\tslug\ttotal\tuncached"
      for (i = 1; i <= m; i++) {
        if (t1[i] > now - idle * 60 || t0[i] < now - days * 86400 + idle * 60 || t0[i] < first[vd[i]] + idle * 60) continue
        b = box[i] SUBSEP ag[i]; k = (b in kd) ? kd[b] : "unkinded"
        c = k SUBSEP vd[i]; n[c]++; T[c] = T[c] " " tot[i]; U[c] = U[c] " " unc[i]
        if (lanes == 1) printf "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%d\n", vd[i], box[i], ag[i], k,
          (b in ks) ? ks[b] : "none", (b in sl) ? sl[b] : "-", tot[i], unc[i]
      }
      print "kind\tclaude_n\tclaude_med_total\tclaude_med_uncached\tgrok_n\tgrok_med_total\tgrok_med_uncached\tratio_total\tratio_uncached\tnote"
      nk = split(kinds, K, " "); hit = ""
      for (j = 1; j <= nk; j++) {
        cc = K[j] SUBSEP "claude"; gg = K[j] SUBSEP "grok"
        ct = n[cc] ? med(T[cc]) : 0; cu = n[cc] ? med(U[cc]) : 0
        gt = n[gg] ? med(T[gg]) : 0; gu = n[gg] ? med(U[gg]) : 0
        rt = (ct > 0 && gt > 0) ? sprintf("%.2f", gt / ct) : "-"
        ru = (cu > 0 && gu > 0) ? sprintf("%.2f", gu / cu) : "-"
        note = (n[cc] + 0 < minn || n[gg] + 0 < minn) ? "n<" minn : (rt + 0 > over + 0 ? "grok over " over "x" : "ok")
        if (note ~ /^grok over/) hit = hit (hit == "" ? "" : ",") K[j]
        printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n", K[j], n[cc], ct, cu, n[gg], gt, gu, rt, ru, note
      }
      printf "grok_over=%s (median total tokens per finished lane, both cells n>=%d, ratio > %s)\n", hit == "" ? "none" : hit, minn, over
    }' <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}
