# shellcheck shell=bash
#------------------------------------------------------------------------------
# The shared reads of the situation scripts (spec 093 section 6). Not a
# situation itself: do_spl_watchdog runs s[1-8].sh only.
#
# A situation script is called as `sN.sh ID PID PANE` ("-" for no pid / no
# pane) with WD_CTX naming the agent's context dir, which the watchdog fills
# once per tick (the script reads files only, never acts):
#   now          the tick's epoch
#   pane         the visible screen of its tmux pane (absent: no pane)
#   tree         the comm of every process under the pane, one per line
#   fg           the pane's foreground command
#   input        its input box (spl_rotate_input); input_age: s it held this text
#   spin_age     s since the spinner's "(...)" last changed (absent: no spinner)
#   client_age   s since an attached client of its session was active
#   transcript   the last lines of its transcript (jsonl)
#   heartbeat    a copy of <spool root>/<id>/heartbeat.json (spec 5.2)
#   held         a copy of <spool root>/peer/<id>/held (seats only)
#   seat         present when <id> is a seat of <spool root>/peer/seats
#   inbox        "<mtime epoch> <file>" per <spool root>/<id>/inbox/*.json
#   rundir_gone  the registry workdir of a lane that no longer exists
#   proc_age     s since the harness process started; user: its OS user
# It prints one line `HIT <code> <evidence>` or nothing, and exits 0.
#------------------------------------------------------------------------------
# shellcheck disable=SC2034 # WD_ID is read by the scripts
WD_ID="${1:-}" WD_PID="${2:-}" WD_PANE="${3:-}"
[[ "$WD_PID" == - ]] && WD_PID=""
[[ "$WD_PANE" == - ]] && WD_PANE=""
WD_HB_FRESH="${WD_HB_FRESH:-120}"
# The banners of a seat that cannot act (the lease's LEASE_STALL_RE, plus the
# org lock-out of spec 6.1 S2).
WD_STALL_RE="${WD_STALL_RE:-usage limit reached|limit reached[[:space:]]*·|limit resets|please run /login|login expired|invalid api key|oauth token (has )?expired|organization has disabled}"

wd_f() { cat "$WD_CTX/$1" 2>/dev/null; }
wd_has() { [[ -s "$WD_CTX/$1" ]]; }
WD_NOW="$(wd_f now)"
[[ "$WD_NOW" =~ ^[0-9]+$ ]] || WD_NOW="$(date +%s)"

# An ISO time as an epoch; nothing when it is empty or unreadable.
wd_epoch() { [[ -n "$1" && "$1" != null ]] && date -u -d "$1" +%s 2>/dev/null; return 0; }

# One heartbeat field as text; nothing when absent or null.
wd_hb() {
  wd_has heartbeat || return 0
  jq -r --arg k "$1" '.[$k] // empty | if type == "string" then . else tojson end' "$WD_CTX/heartbeat" 2>/dev/null
  return 0
}

# The pane's last non-blank lines (its footer).
wd_foot() { wd_f pane | grep -v '^[[:space:]]*$' | tail -n "${WD_PANE_TAIL:-12}"; }

# 0 while the spinner's timer moved within WD_SPIN_MOVED s (45).
wd_spin_moving() {
  local a
  a="$(wd_f spin_age)"
  [[ "$a" =~ ^[0-9]+$ ]] && (( a < ${WD_SPIN_MOVED:-45} ))
}

# The epoch of the newest transcript entry that proves the model produced
# something: a reply that is not an API error, or a tool result (the same rule
# as spl_lease_activity, with no fallback). Nothing when there is none.
wd_transcript_progress() {
  wd_has transcript || return 0
  jq -Rrn '
    def ts: (.timestamp // "") | sub("\\.[0-9]+"; "") | (try fromdateiso8601 catch null);
    [inputs | fromjson? // empty | select(type == "object")
      | select((.type == "assistant" and .isApiErrorMessage != true)
        or (.type == "user" and (.message.content | type) == "array"
            and any(.message.content[]; type == "object" and .type == "tool_result")))
      | ts | select(. != null)] | max // empty | floor' "$WD_CTX/transcript" 2>/dev/null
  return 0
}

# The last progress epoch: the heartbeat's progress_ts or the transcript's,
# whichever is newer (spec 6.1 S8: a silent hook is backed by the transcript).
# Nothing when neither is known.
wd_progress() {
  local a b
  a="$(wd_epoch "$(wd_hb progress_ts)")"
  b="$(wd_transcript_progress)"
  [[ "$a" =~ ^[0-9]+$ ]] || a=0
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  (( a > b )) || a="$b"
  (( a > 0 )) && echo "$a"
  return 0
}

# "ok" when the transcript's last assistant entry is a real reply,
# "error<TAB><its text>" for an isApiErrorMessage one, nothing when unknown.
wd_last_turn() {
  wd_has transcript || return 0
  jq -Rrn '
    [inputs | fromjson? // empty | select(type == "object" and .type == "assistant")] | last
    | if . == null then empty
      elif .isApiErrorMessage == true then
        "error\t" + ([.message.content[]? | select(type == "object") | .text // empty] | join(" ") | .[0:120])
      else "ok" end' "$WD_CTX/transcript" 2>/dev/null
  return 0
}

# The S4 cap of <tool> in seconds: WD_TOOL_MAX ("Tool=sec,Tool=sec") first,
# then the spec's defaults (Bash and anything else 15 min; Agent, Monitor,
# Workflow 60 min; WebFetch, WebSearch 5 min).
wd_tool_cap() {
  local t="$1" kv
  for kv in ${WD_TOOL_MAX//,/ }; do
    [[ "${kv%%=*}" == "$t" && "${kv#*=}" =~ ^[0-9]+$ ]] && { echo "${kv#*=}"; return 0; }
  done
  case "$t" in
    Agent|Task|Monitor|Workflow) echo 3600 ;;
    WebFetch|WebSearch) echo 300 ;;
    *) echo 900 ;;
  esac
}

# 0 when the agent is FRESH (spec 5.3): no api_error, and progress within
# WD_HB_FRESH, or a tool call within its cap, or a long turn whose spinner
# moves (claude) within 2 x WD_HB_FRESH of the last progress. With no
# heartbeat at all (hooks not installed yet) a moving spinner is fresh: a
# long tool call and a long turn look alike from the pane.
wd_fresh() {
  local p st since
  [[ -n "$(wd_hb api_error)" ]] && return 1
  p="$(wd_progress)"
  [[ -n "$p" ]] && (( WD_NOW - p <= WD_HB_FRESH )) && return 0
  if ! wd_has heartbeat; then
    wd_spin_moving && return 0
    return 1
  fi
  st="$(wd_hb state)"
  if [[ "$st" == in-tool ]]; then
    since="$(wd_epoch "$(wd_hb tool_since)")"
    [[ -n "$since" ]] && (( WD_NOW - since <= $(wd_tool_cap "$(wd_hb tool)") )) && return 0
  fi
  [[ "$st" == working && -n "$p" ]] && wd_spin_moving && (( WD_NOW - p <= 2 * WD_HB_FRESH )) && return 0
  return 1
}

# The text cut to one short line for an evidence field.
wd_short() { tr '\n\t' '  ' | cut -c1-"${1:-100}"; }
