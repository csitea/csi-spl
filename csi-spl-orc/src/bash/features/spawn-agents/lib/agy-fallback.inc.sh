# shellcheck shell=bash
# agy-fallback.inc.sh: start an agy seat on one of agy's own alternative
# models when agy's Gemini quota is low (spec 184 section 10, SPL-6661; owner
# HUM-10, t1 6a27166d, msg 72c52eaa).
#
# Measured on agy 1.5.18 (spec 184 10.1): `agy --model <id>` takes the ids
# `agy models` prints in its first column; an id it does not know is NOT
# refused (the seat starts silently on the Gemini default), so a model is
# only passed when that list holds it. agy's Claude and GPT models draw on
# their own pool ("Claude and GPT models": buckets 3p-weekly and 3p-5h),
# apart from the Gemini pool (gemini-weekly, gemini-5h).
#
# The switch happens only where a seat starts (spawn-agy.sh, restore-agy.sh),
# never inside a session. It ships off: cnf
# env.box.agent_split.agy_fallback.enabled. Doc and coding lanes only (its
# `kinds`); NEVER a review seat (c-001 847c41a2, rounds rulebook 2.7.3: an
# agy seat on a claude-* model is a claude review, and a claude author's
# review would become same-vendor): a review seat waits, as before.
#
# Env (tests and overrides):
#   SPOOL_AGY_FALLBACK_CNF  the cnf file (default this checkout's all.env.yaml)
#   SPOOL_AGY_QUOTA_CMD     prints the quota lines (default agy-quota-read.py
#                           as the agent user); "<bucket> TAB <fraction> TAB <reset>"
#   SPOOL_AGY_MODELS_CMD    prints `agy models` (default the agent user's agy)
#   SPOOL_AGY_PROBE_DIR     the reading cache (default $SPOOL_ROOT/dispatch/vendor-probe)
#   SPOOL_AGY_READ_TIMEOUT_S  the bound on each agy read (default 60): a
#                           stalled `agy acp` / `agy models` never holds a start
#
# SPAWN_DRY_RUN=1 writes nothing and starts no agy: a fresh cached reading
# decides, else the reading counts as unread (spawn-core.inc.sh "DRY RUN").
#
# Out: spool_agy_fallback_decide sets AGY_FB_MODEL (empty = agy's own default)
# and AGY_FB_WHY (one line), always rc 0: a failed read never stops a start.

_AGY_FB_LIB_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# One key of env.box.agent_split.agy_fallback, a list as one id per line;
# nothing when the file, yq or the key is missing.
spool_agy_fallback_cnf() {  # KEY
  local cnf="${SPOOL_AGY_FALLBACK_CNF:-$_AGY_FB_LIB_DIR/../../../../../../csi-spl-cnf/csi-spl/all.env.yaml}"
  [ -r "$cnf" ] && command -v yq >/dev/null 2>&1 || return 0
  yq -r ".env.box.agent_split.agy_fallback.$1 | select(. != null) | (select(type == \"!!seq\") | .[]) // ." "$cnf" 2>/dev/null
}

# A reading, reused for cache_s seconds: CACHE-FILE then the command to run.
_spool_agy_fb_cached() {  # NAME CMD
  local dir="${SPOOL_AGY_PROBE_DIR:-${SPOOL_ROOT:-/nonexistent}/dispatch/vendor-probe}" ttl f out
  ttl="$(spool_agy_fallback_cnf cache_s)"; [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
  f="$dir/$1"
  if [ -s "$f" ] && (( $(date +%s) - $(stat -c %Y "$f" 2>/dev/null || echo 0) < ttl )); then
    cat "$f"; return 0
  fi
  [ "${SPAWN_DRY_RUN:-0}" != 1 ] || return 4
  # shellcheck disable=SC2086 # a command line, split on purpose
  out="$(eval "$2" 2>/dev/null)" || return 4
  [ -n "$out" ] || return 4
  mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$out" >"$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null
  printf '%s\n' "$out"
}

# The bound in seconds on one agy read (at least 10).
_spool_agy_fb_tmo() {
  local t="${SPOOL_AGY_READ_TIMEOUT_S:-60}"
  [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 10 )) || t=60
  echo "$t"
}

# agy's quota lines (agy-quota-read.py), cached; rc 4 when unread.
spool_agy_quota() {
  local cmd="${SPOOL_AGY_QUOTA_CMD:-}"
  if [ -z "$cmd" ]; then
    declare -F spool_agent_exec >/dev/null || return 4
    cmd="spool_agent_exec \"timeout -k 5 $(_spool_agy_fb_tmo) python3 -I '$_AGY_FB_LIB_DIR/../scripts/agy-quota-read.py'"
    [ -z "${AGY_BIN:-}" ] || cmd+=" --agy '$AGY_BIN'"
    cmd+=" --timeout $(( $(_spool_agy_fb_tmo) - 5 ))"
    cmd+='"'
  fi
  _spool_agy_fb_cached agy-quota.tsv "$cmd"
}

# The model ids agy offers (`agy models`, column 1), cached; rc 4 when unread.
spool_agy_model_ids() {
  local cmd="${SPOOL_AGY_MODELS_CMD:-}"
  if [ -z "$cmd" ]; then
    declare -F spool_agent_exec >/dev/null || return 4
    cmd="spool_agent_exec \"timeout -k 5 $(_spool_agy_fb_tmo) '${AGY_BIN:-agy}' models </dev/null\""
  fi
  _spool_agy_fb_cached agy-models.tsv "$cmd" | awk -F'\t' 'NF >= 1 && $1 ~ /^[A-Za-z0-9._:\/-]+$/ { print $1 }'
}

# The fraction of BUCKET in the quota lines QUOTA, else nothing.
_spool_agy_fb_frac() {  # QUOTA BUCKET
  awk -F'\t' -v b="$2" '$1 == b && $2 ~ /^[0-9.]+$/ { print $2; exit }' <<<"$1"
}

# 0 when A < B (decimal fractions).
_spool_agy_fb_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }

# 0 when the BRIEF files mark a review seat, wherever the brief sits (a
# watchdog restart or rotation seed nests the task brief under its own
# heading, so every heading is read, not the first): Kind: review; "review",
# "reviewer", "R7" or "panel" in a file name or any heading; or any Author:
# line (a seat that names an author reviews that author's work). Errs toward
# review: a doc lane barred by mistake only keeps waiting, as before.
_spool_agy_fb_is_review() {  # BRIEF...
  local f
  for f in "$@"; do
    [ -n "$f" ] || continue
    grep -qiE '\b(review(er|s)?|R7|panel)\b' <<<"$(basename "$f")" && return 0
    [ -r "$f" ] || continue
    grep -qiE '^[*_ ]*Kind:[*_ ]*review\b' "$f" && return 0
    grep -qiE '^[*_ ]*Author:' "$f" && return 0
    grep -E '^#+ ' "$f" | grep -qiE '\b(review(er|s|ing)?|R7|panel)\b' && return 0
  done
  return 1
}

# Why a seat of the BRIEF files may not leave agy's default, else nothing:
# not on, a review seat (with its claude author named), or a kind not in the
# list. The kind is the first Kind: line of the files, in order.
spool_agy_fallback_barred() {  # BRIEF...
  local kind="" au="" id kinds f
  [ "$(spool_agy_fallback_cnf enabled)" = true ] || { echo "the switch is off (cnf env.box.agent_split.agy_fallback.enabled)"; return 0; }
  if _spool_agy_fb_is_review "$@"; then
    while read -r id; do
      [ -n "$id" ] && [ "$(spl_kind_of_agent_id "$id" 2>/dev/null)" = claude ] && au+=" $id"
    done < <(for f in "$@"; do [ -r "$f" ] && grep -iE '^[*_ ]*Author:' "$f"; done 2>/dev/null | grep -oE '\b[acgmoq]-[0-9]{3}\b|\bCLE-[0-9]+\b' | sort -u)
    if [ -n "$au" ]; then echo "a review seat of a claude author (${au# }) stays on Gemini: a claude-* model would make it a claude review (rounds rulebook 2.7.3)"
    else echo "a review seat: no fallback until the owner rules (c-001 847c41a2)"; fi
    return 0
  fi
  for f in "$@"; do
    [ -n "$kind" ] || kind="$(grep -m1 -oE 'Kind:[*_ ]*[A-Za-z0-9_]+' "$f" 2>/dev/null | sed -E 's/^Kind:[*_ ]*//' | tr '[:upper:]' '[:lower:]')"
  done
  kinds=" $(spool_agy_fallback_cnf kinds | tr '\n' ' ')"
  [ -n "$kind" ] && [[ "$kinds" == *" $kind "* ]] || echo "kind '${kind:-none}' is not in agy_fallback.kinds"
}

# Decide the model for an agy seat of BRIEF: AGY_FB_MODEL (empty = agy's own
# Gemini default) and AGY_FB_WHY. Gemini stays while both its windows hold at
# least their mark (weekly_min, five_hour_min). Below either, the first
# `models` entry that `agy models` lists and whose pool holds alt_min of both
# windows wins (claude-* and gpt-* read the 3p pool); none: Gemini stays.
spool_agy_fallback_decide() {  # BRIEF...
  local q ids m wk fh wmin fmin amin aw a5
  AGY_FB_MODEL="" AGY_FB_WHY="$(spool_agy_fallback_barred "$@")"
  [ -z "$AGY_FB_WHY" ] || return 0
  q="$(spool_agy_quota)" || { AGY_FB_WHY="agy quota unread: stays on its default"; return 0; }
  wk="$(_spool_agy_fb_frac "$q" gemini-weekly)" fh="$(_spool_agy_fb_frac "$q" gemini-5h)"
  wmin="$(spool_agy_fallback_cnf weekly_min)" fmin="$(spool_agy_fallback_cnf five_hour_min)" amin="$(spool_agy_fallback_cnf alt_min)"
  if [ -z "$wk" ] || [ -z "$fh" ]; then AGY_FB_WHY="no gemini-weekly / gemini-5h bucket in agy's quota: stays on its default"; return 0; fi
  if ! _spool_agy_fb_lt "$wk" "${wmin:-0.05}" && ! _spool_agy_fb_lt "$fh" "${fmin:-0.05}"; then
    AGY_FB_WHY="Gemini weekly $wk, 5h $fh: at or above the marks (${wmin:-0.05}, ${fmin:-0.05}), stays on Gemini"; return 0
  fi
  ids="$(spool_agy_model_ids)" || { AGY_FB_WHY="Gemini weekly $wk, 5h $fh is low, but agy models is unread: stays on its default"; return 0; }
  aw="$(_spool_agy_fb_frac "$q" 3p-weekly)" a5="$(_spool_agy_fb_frac "$q" 3p-5h)"
  while read -r m; do
    [ -n "$m" ] || continue
    grep -qxF -- "$m" <<<"$ids" || continue
    case "$m" in claude-*|gpt-*) ;; *) continue ;; esac
    if [ -z "$aw" ] || [ -z "$a5" ] || _spool_agy_fb_lt "$aw" "${amin:-0.10}" || _spool_agy_fb_lt "$a5" "${amin:-0.10}"; then
      continue
    fi
    AGY_FB_MODEL="$m"
    AGY_FB_WHY="Gemini weekly $wk, 5h $fh is below its mark (${wmin:-0.05}, ${fmin:-0.05}): $m (3p weekly $aw, 5h $a5)"
    return 0
  done < <(spool_agy_fallback_cnf models)
  AGY_FB_WHY="Gemini weekly $wk, 5h $fh is low and no alternative is listed with room (3p weekly ${aw:-?}, 5h ${a5:-?}): stays on its default"
}

# The vendor a seat on MODEL counts as for reviews and the lane map: claude
# for claude-* (rounds rulebook 2.7.3), else agy (gpt-oss is an open-weight
# model agy hosts; no fleet vendor runs it).
spool_agy_effective_vendor() {  # MODEL
  case "${1:-}" in claude-*) echo claude ;; *) echo agy ;; esac
}

# Record the decision for SEAT: <spool>/<seat>/lifetime/agy-fallback.json
# {"at","model","effective_vendor","why"}, and one line to stderr. Best effort.
spool_agy_fallback_record() {  # SEAT
  local d="${SPOOL_ROOT:-/nonexistent}/$1/lifetime" v
  v="$(spool_agy_effective_vendor "$AGY_FB_MODEL")"
  echo "agy fallback: ${AGY_FB_MODEL:-default}: $AGY_FB_WHY" >&2
  [ "${SPAWN_DRY_RUN:-0}" != 1 ] || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  jq -nc --arg at "$(date -u +%FT%TZ)" --arg m "$AGY_FB_MODEL" --arg v "$v" --arg w "$AGY_FB_WHY" \
    '{at: $at, model: $m, effective_vendor: $v, why: $w}' >"$d/agy-fallback.json" 2>/dev/null || true
}

# The words to add to an agy launch line for SEAT of BRIEF: "--model '<id>'"
# or nothing. Decides, records, prints. With the switch off nothing is read,
# written or printed: the launch stays as it was. The seat's own task brief
# (<spool>/<seat>/lifetime/brief.md, kept across rotations and restarts) and
# the brief its seed names are read too, so a restart or rotation seed with
# no Kind: of its own decides by the task's brief.
spool_agy_fallback_flags() {  # SEAT [BRIEF]
  [ "$(spool_agy_fallback_cnf enabled)" = true ] || return 0
  # an adapter calls this before spawn_main / restore_main resolve the box
  # env: resolve it here (the caller's $(...) keeps it from leaking); a preset
  # SPOOL_AGENT_USER is kept by spool_env_resolve, so it never skips it
  declare -F spool_env_resolve >/dev/null || . "$_AGY_FB_LIB_DIR/spool-env.inc.sh" || return 0
  spool_env_resolve
  local own="" seed=""
  [ -z "${1:-}" ] || own="$SPOOL_ROOT/$1/lifetime/brief.md"
  seed="$(spool_agy_fallback_seat_brief "${1:-}")"
  spool_agy_fallback_decide "${2:-}" "$own" "$seed"
  spool_agy_fallback_record "$1"
  [ -z "$AGY_FB_MODEL" ] || printf -- "--model '%s'" "$AGY_FB_MODEL"
}

# The brief a seat's seed names (<spool>/<seat>/lifetime/prompt.txt: "...
# task brief at <path>.md", a briefs/ file or a lifetime/brief.md), else nothing.
spool_agy_fallback_seat_brief() {  # SEAT
  [ -n "${1:-}" ] || return 0
  grep -m1 -oE '/[^ ]*/(briefs/[^ ]*|lifetime/brief)\.md' "${SPOOL_ROOT:-/nonexistent}/$1/lifetime/prompt.txt" 2>/dev/null | sed -n 1p
}
