#!/bin/bash
#------------------------------------------------------------------------------
# @description Fleet tokens of one UTC day (spec 123 section 4.3), read-only:
# @description sums every lane transcript's .message.usage per agent id,
# @description vendor, model, service_tier and kind (input, output,
# @description cache_read, cache_creation), deduped per message.id with the
# @description MAX of each field (a message is written on several rows; a
# @description per-row sum about doubles it). <synthetic> zero-usage rows are
# @description skipped; ids listed in COST_METERED_IDS (the hub's metered
# @description turns, spec 121 usage_events, not built yet) are skipped.
# @description Other vendors' agents seen that day get one "unmetered" row,
# @description never 0. Writes <COST_DAY_DIR>/tokens-<DAY>.tsv; the hub ingest
# @description (spec 123 lane 4) is not built, so nothing is posted.
# @param DAY (optional) - UTC day YYYY-MM-DD, default yesterday
# @param COST_AGENT_USERS (optional) - users whose ~/.claude/projects are
# @param   read, default SPOOL_AGENT_USER (else $USER); COST_TRANSCRIPT_DIRS
# @param   (space-separated dirs) replaces them, read as the current user
# @param COST_DAY_DIR (optional) - default $SPOOL_ROOT/cost
# @param COST_METERED_IDS (optional) - file, one metered message id per line
# @example DAY=2026-10-09 ./run -a do_spl_cost_tokens_read
#------------------------------------------------------------------------------
do_spl_cost_tokens_read() {
  local day="${DAY:-$(date -u -d yesterday +%F)}" root="${SPOOL_ROOT:-/var/spool-hub}" dir out rows
  spl_cost_day_ok "$day" || return 2
  dir="${COST_DAY_DIR:-$root/cost}"
  mkdir -p "$dir" || { echo "FATAL cannot create $dir" >&2; return 1; }
  out="$dir/tokens-$day.tsv"
  rows="$(spl_cost_tokens_rows "$day" "$root")" || return 1
  {
    printf '%s\n' "$rows" | grep '^#'
    printf 'day\tagent_id\tvendor\tmodel\tservice_tier\tkind\tunits\torigin\n'
    printf '%s\n' "$rows" | grep -v '^#' | grep . || true
    spl_cost_tokens_unmetered "$day" "$root"
  } > "$out.$$" && mv -f "$out.$$" "$out" || return 1
  grep '^#' "$out"
  echo "OK wrote $out ($(grep -vc '^#' "$out") lines incl. header); hub ingest not built (spec 123 lane 4): file only"
}

spl_cost_day_ok() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && [[ "$(date -u -d "$1" +%F 2>/dev/null)" == "$1" ]] && return 0
  echo "FATAL DAY must be a UTC day YYYY-MM-DD, got '$1'" >&2
  return 1
}

# spl_cost_tokens_rows DAY ROOT: the "# " stats lines, then the deduped day
# rows (tab-separated, the header's columns).
spl_cost_tokens_rows() {
  local day="$1" root="$2" metered="${COST_METERED_IDS:-/dev/null}" list
  [[ -r "$metered" ]] || { echo "FATAL COST_METERED_IDS $metered is unreadable" >&2; return 1; }
  list="$(spl_cost_tokens_files "$day")"
  printf '%s\n' "$list" | grep . | while IFS=$'\t' read -r u f; do
    spl_cost_tokens_extract "$day" "$u" "$f" "$(spl_cost_tokens_agent "$root" "$f")"
  done | spl_cost_tokens_sum "$day" "$(printf '%s\n' "$list" | grep -c . || true)" "$metered"
}

# The per-id MAX, then the sums per agent, model, tier and kind. Stats: rows
# read, distinct ids, skips, and per kind the per-row vs per-id totals.
spl_cost_tokens_sum() {
  awk -F'\t' -v OFS='\t' -v day="$1" -v files="$2" -v mfile="$3" '
    BEGIN { while ((getline l < mfile) > 0) if (l != "") metered[l] = 1 }
    { rows++; for (k = 5; k <= 8; k++) perrow[k] += $k }
    $2 == "<synthetic>" && $5 + $6 + $7 + $8 == 0 { syn++; next }
    $4 in metered { if (!($4 in mseen)) { mseen[$4] = 1; met++ }; next }
    !($4 in key) { key[$4] = $1 OFS $2 OFS $3; ids++ }
    { for (k = 5; k <= 8; k++) if ($k > mx[$4, k]) mx[$4, k] = $k }
    END {
      split("input output cache_read cache_creation", kind, " ")
      for (id in key) for (k = 5; k <= 8; k++) { sum[key[id] OFS kind[k - 4]] += mx[id, k]; perid[k] += mx[id, k] }
      printf "# cost-tokens v1 day=%s files=%d rows=%d ids=%d synthetic_skipped=%d metered_skipped=%d\n", day, files, rows, ids, syn, met
      for (k = 5; k <= 8; k++) printf "# %s per_row=%.0f per_id=%.0f\n", kind[k - 4], perrow[k], perid[k]
      fflush()
      for (s in sum) { split(s, p, OFS); print day, p[1], "claude", p[2], p[3], p[4], sum[s], "transcript" | "sort" }
    }'
}

# The transcripts that may hold DAY: "<user> TAB <path>" for every *.jsonl
# (subagent files too) changed at or after DAY 00:00 UTC.
spl_cost_tokens_files() {
  local u d
  if [[ -n "${COST_TRANSCRIPT_DIRS:-}" ]]; then
    for d in $COST_TRANSCRIPT_DIRS; do
      find "$d" -name '*.jsonl' -newermt "$1 00:00:00 UTC" -printf "$(id -un)\t%p\n" 2>/dev/null
    done
    return 0
  fi
  for u in ${COST_AGENT_USERS:-${SPOOL_AGENT_USER:-$USER}}; do
    d="$(getent passwd "$u" | cut -d: -f6)/.claude/projects"
    spl_cost_as "$u" find "$d" -name '*.jsonl' -newermt "$1 00:00:00 UTC" -printf "$u\t%p\n" 2>/dev/null
  done
}

# Run a read as <user>: transcripts are mode 600, owned by the agent user.
spl_cost_as() {
  local u="$1"; shift
  if [[ "$u" == "$(id -un)" ]]; then "$@"; else sudo -n -u "$u" "$@"; fi
}

# The agent a transcript belongs to: the spool agent record naming its
# session id, else the -wt-<id> suffix of its project dir, else unattributed.
spl_cost_tokens_agent() {
  local f="$2" sid slug rec
  sid="$(basename "$f" .jsonl)"
  [[ "$f" == */subagents/* ]] && sid="$(basename "$(dirname "$(dirname "$f")")")"
  rec="$(grep -lsF "\"session_id\": \"$sid\"" "$1"/agents/*.json 2>/dev/null | sed -n 1p)"
  [[ -n "$rec" ]] && { basename "$rec" .json; return 0; }
  slug="${f%/"$sid"*}"; slug="${slug##*/}"
  if [[ "$slug" =~ -wt[0-9]*-([A-Za-z]+-[0-9]+)$ ]]; then echo "${BASH_REMATCH[1]}"; else echo unattributed; fi
}

# The DAY assistant rows of one transcript: agent, model, tier, message id,
# input, output, cache_read, cache_creation. Counts and ids only, no text.
spl_cost_tokens_extract() {
  spl_cost_as "$2" grep -hF "\"timestamp\":\"$1" "$3" 2>/dev/null | grep -F '"assistant"' |
    jq -r --arg d "$1" --arg a "$4" 'select(.type == "assistant" and (.timestamp // "" | startswith($d))
        and (.message.usage | type) == "object") | .message as $m | $m.usage as $u |
      [$a, ($m.model // "unknown"), ($u.service_tier // "unknown"), ($m.id // ("uuid:" + (.uuid // "?"))),
       ($u.input_tokens // 0), ($u.output_tokens // 0), ($u.cache_read_input_tokens // 0),
       ($u.cache_creation_input_tokens // 0)] | @tsv' 2>/dev/null || true
}

# One row per agent of another vendor (agy, grok, mistral, qwen) seen on
# DAY: in the lease tick's day log, or its spool record updated that day.
# Their CLIs' usage records are not measured yet: "unmetered", never 0.
spl_cost_tokens_unmetered() {
  local day="$1" root="$2" id kind
  {
    awk '{print $2}' "$root/dispatch/agent-run-$day.log" 2>/dev/null
    grep -lsF "\"updated_at\": \"$day" "$root"/agents/*.json 2>/dev/null | xargs -r -n1 basename | sed 's/\.json$//'
  } | sort -u | while IFS= read -r id; do
    kind="$(jq -r '.kind // empty' "$root/agents/$id.json" 2>/dev/null || true)"
    [[ -n "$kind" ]] || case "$id" in
      a-*|AGY-*) kind=agy ;; g-*|GRK-*) kind=grok ;; m-*) kind=mistral ;; q-*|QWN-*) kind=qwen ;; *) kind=claude ;;
    esac
    [[ "$kind" == claude ]] || printf '%s\t%s\t%s\t-\t-\ttokens\tunmetered\ttranscript\n' "$day" "$id" "$kind"
  done
}
