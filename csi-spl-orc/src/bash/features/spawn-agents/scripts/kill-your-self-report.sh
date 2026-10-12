#!/usr/bin/env bash
# kill-your-self-report.sh — read-only discovery for /exit-clean and
# /kill-your-self (ported from the frozen box engine, specs/048 SPL-1160):
# which agent this is, what is still unread in its spool inbox, what git
# holds unpushed, and the candidate spec tasks.md files to tick. Edits nothing;
# the agent owns the checkboxes, the commit and the /exit.
#
# Usage: kill-your-self-report.sh [WORKDIR]      (default: $PWD)
#        kill-your-self-report.sh --result --outcome "<one line>" [--sha <sha>]...
#          [--numbers "<text>"] [--detail <file>|-] [--detail-path <doc>] [WORKDIR]
#        kill-your-self-report.sh --reporter [--no-gate] [WORKDIR]
#        kill-your-self-report.sh --gate [WORKDIR]
#
# --result prints ONLY the final report body, at most RESULT_MAX (800) chars:
# the one-line outcome, the numbers, the sha(s) (default: HEAD) and the path to
# the full detail. --detail copies a file (or stdin) to
# ${REPORT_DIR:-$SPOOL_ROOT/reports}/<id>.md; --detail-path names a doc
# instead. Text cut to fit the cap is kept whole in that file. The report
# file is never left empty (m-897 sent a 0-byte one, 2026-10-10): a --detail
# that cannot be read is refused, and an empty one, or none, gets the outcome,
# numbers and sha(s) written into it.
#
# --reporter prints the id the exit-clean report goes to, first match wins:
# $REPORT_TO; the brief's own "Spawner:" / "Reporter:" / "Report to:" line
# naming an id (<spool root>/<id>/lifetime/brief.md); the seed's "your
# spawner: ... --to <id>" (lifetime/prompt.txt); the registry row's requester;
# else "orchestrator". stderr says which source won. It runs --gate first
# (refused: exit 3, nothing on stdout, so the report send has no recipient);
# --no-gate is only for `--rebirth` and `report-only`, which neither close
# nor retire the lane.
#
# --gate: exit 0 only when this lane may exit (m-930 ran /exit-clean after
# c-928's REJECT b26ebbb9, 2026-10-10; a rule in prose did not stop it). It
# reads every message in <spool root>/<id>/{inbox,archive}: the newest one
# whose body starts with ACCEPTED, from the dispatch holder or the spawner (a
# role seat c-001..c-003 or a lease.conf LEASE_* id, any box; the --reporter;
# a HUM- id), must be newer than every REJECT / SEND-BACK the lane received
# (kind reject, or a body starting with one of those words). Else one line
# on stderr names the missing ACCEPTED or the newer REJECT, and exit 3.
# After the ACCEPTED, the lane's issue (li_gate, lib/lane-issue.inc.sh; rule:
# csi-spl-doc/doc/md/lane-issue-and-docs.md): refused while its key is still
# wip with no commit on origin/<trunk> citing it and no end reason
# (lifetime/issue-end), or when those commits change behaviour with no
# csi-spl-doc/ change and no `Docs: none (<why>)` line. A lane with no key
# (placed before the rule) is not checked.
# The two ways out with no ACCEPTED (c-767 cd0d55925):
#   - the rotation: it retires only role seats, and a role seat's id passes;
#   - a human who typed /exit-clean in the pane: EXIT_CLEAN_BY=human plus a
#     non-empty EXIT_CLEAN_REASON. A refusal never names it, and every use
#     appends a line to <spool root>/exit-override.log for the dispatcher.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$_here/../lib/agent-state.inc.sh"
# shellcheck source=../lib/lane-issue.inc.sh
. "$_here/../lib/lane-issue.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

MODE=discovery OUTCOME="" NUMBERS="" DETAIL="" DETAIL_PATH="" SHAS=() GATE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --result) MODE=result ;;
    --reporter) MODE=reporter ;;
    --gate) MODE=gate ;;
    --no-gate) GATE=0 ;;
    --outcome) OUTCOME="${2:-}"; shift ;;
    --numbers) NUMBERS="${2:-}"; shift ;;
    --sha) SHAS+=("${2:-}"); shift ;;
    --detail) DETAIL="${2:-}"; shift ;;
    --detail-path) DETAIL_PATH="${2:-}"; shift ;;
    -*) echo "kill-your-self-report: unknown option $1" >&2; exit 2 ;;
    *) WORKDIR="${WORKDIR:-$1}" ;;
  esac
  shift
done
WORKDIR="${WORKDIR:-$PWD}"

# The id: the session's own env first, then the worktree path, then the window.
ID="${SPOOL_AGENT_ID:-${MCP_BOT_AGENT_ID:-}}" SRC=env
if [ -z "$ID" ] && [[ "$WORKDIR" =~ (^|[^A-Za-z0-9])${SPOOL_AGENT_ID_RX}([^0-9]|$) ]]; then ID="${BASH_REMATCH[2]}" SRC=path; fi
wname=""
if [ -n "${TMUX_PANE:-}" ]; then
  spool_tmux_argv
  wname="$("${SPOOL_TM[@]}" list-panes -a -F '#{pane_id}	#{window_name}' 2>/dev/null | awk -F '\t' -v p="$TMUX_PANE" '$1 == p { print $2; exit }')"
  if [ -z "$ID" ]; then ID="$(an_strip "$wname" | grep -oE "^${SPOOL_AGENT_ID_RX}" || true)"; SRC=window; fi
fi

# The lane's named reporter (c-894 finding 2): the skill's {{ORCHESTRATOR_ID}}
# rendered as "orchestrator", so m-897's report skipped c-894, the spawner its
# brief named. Sets REP_TO and REP_FROM.
ksr_reporter() {
  local life="$SPOOL_ROOT/${ID:-none}/lifetime" to="" from=""
  if [ -n "${REPORT_TO:-}" ]; then to="$REPORT_TO" from=env; fi
  if [ -z "$to" ] && [ -r "$life/brief.md" ]; then
    to="$(sed -nE "s/^[-*_ ]*(spawner|reporter|report to)[*_ ]*:[*_\` ]*(${SPOOL_AGENT_ID_RX}(@[A-Za-z0-9._-]+)?)([^A-Za-z0-9@._-].*)?\$/\2/Ip" "$life/brief.md" | sed -n 1p)"
    [ -n "$to" ] && from=brief
  fi
  if [ -z "$to" ] && [ -r "$life/prompt.txt" ]; then
    to="$(grep -oE "your spawner: spool-send\.sh --to ${SPOOL_AGENT_ID_RX}(@[A-Za-z0-9._-]+)?" "$life/prompt.txt" | sed -n 1p | sed 's/.* --to //')"
    [ -n "$to" ] && from=seed
  fi
  if [ -z "$to" ] && [ -n "$ID" ] && [ -r "$SPOOL_ROOT/registry.tsv" ]; then
    to="$(awk -F '\t' -v id="$ID" '$1 == id && $6 != "" && $6 != "-" { r = $6 } END { print r }' "$SPOOL_ROOT/registry.tsv")"
    [ -n "$to" ] && { [[ "$to" == *@* ]] || to="$(spool_decorate "$to")"; from=registry; }
  fi
  [ -n "$to" ] || { to=orchestrator from=fallback; }
  REP_TO="$to" REP_FROM="$from"
}

# A role seat: the rotation (spec 060) retires it with `/exit-clean no-close`
# and hands the same id to the successor; no reviewer ACCEPTs a seat.
ksr_is_seat() {  # ID (bare)
  [[ "$1" =~ ^[A-Za-z]+-00[1-3]$ ]] && return 0
  grep -qxE "LEASE_(MASTER|FAILOVER|ORCH)=$1" "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null
}

# The exit gate (see the header). 0 = may exit; 3 = refused, one line on stderr.
ksr_gate() {
  local reason ts from kind task body id up bare rep_bare
  local acc_ts="" acc_id="" acc_task="" rej_ts="" rej_id="" rej_from=""
  if [ -z "$ID" ]; then
    echo "exit-clean refused: no agent id (SPOOL_AGENT_ID, worktree path or window); nothing retired, closed or reported" >&2
    return 3
  fi
  if ksr_is_seat "${ID%@*}"; then
    echo "exit gate: $ID is a role seat (the rotation retires it); no ACCEPTED needed" >&2
    return 0
  fi
  if [ "${EXIT_CLEAN_BY:-}" = human ]; then
    reason="$(printf '%s' "${EXIT_CLEAN_REASON:-}" | tr '\t\n\r' ' ' | sed 's/^ *//; s/ *$//' | cut -c1-200)"
    if [ -n "$reason" ]; then
      printf '%s\t%s\thuman\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$reason" >>"$SPOOL_ROOT/exit-override.log" 2>/dev/null || true
      echo "exit gate: $ID exits on a human's /exit-clean ($reason); logged in $SPOOL_ROOT/exit-override.log" >&2
      return 0
    fi
  fi
  ksr_reporter
  rep_bare="${REP_TO%@*}"
  while IFS=$'\t' read -r ts from kind task body id; do
    [ -n "$ts" ] || continue
    body="$(printf '%s' "$body" | sed -E 's/^([[:space:]]|\\[nt]|[*_#>`])+//')"
    up="${body^^}" bare="${from%@*}"
    if [ "$kind" = reject ] || [[ "$up" =~ ^(REJECT|SEND[-\ ]?BACK) ]]; then
      if [[ "$ts" > "$rej_ts" ]]; then rej_ts="$ts" rej_id="${id:0:8}" rej_from="$from"; fi
    elif [[ "$body" == ACCEPTED* ]] && { ksr_is_seat "$bare" || [ "$bare" = "$rep_bare" ] || [[ "$bare" =~ ^HUM-[0-9]+$ ]]; }; then
      if [[ "$ts" > "$acc_ts" ]]; then acc_ts="$ts" acc_id="${id:0:8}" acc_task="$task"; fi
    fi
  done < <(find "$SPOOL_ROOT/$ID/inbox" "$SPOOL_ROOT/$ID/archive" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null |
    xargs -0 -r jq -r 'select(type == "object") | [(.ts // ""), (.from // ""), (.kind // ""), (.task_id // ""), ((.body // "") | .[0:120]), (.msg_id // "")] | @tsv' 2>/dev/null)
  if [ -n "$rej_ts" ] && { [ -z "$acc_ts" ] || ! [[ "$acc_ts" > "$rej_ts" ]]; }; then
    echo "exit-clean refused: REJECT $rej_id from $rej_from at $rej_ts is newer than any ACCEPTED; fix it, send your result, wait for an ACCEPTED (nothing retired, closed or reported)" >&2
    return 3
  fi
  if [ -z "$acc_ts" ]; then
    echo "exit-clean refused: no ACCEPTED on your task from the dispatch holder or your spawner ($REP_TO) in $SPOOL_ROOT/$ID/{inbox,archive}; send your result and stay idle (nothing retired, closed or reported)" >&2
    return 3
  fi
  echo "exit gate: ACCEPTED $acc_id at $acc_ts on task $acc_task" >&2
  # The lane's issue and docs (lib/lane-issue.inc.sh li_gate).
  li_gate "$SPOOL_ROOT" "$ID" "$WORKDIR" || return 3
  return 0
}

if [ "$MODE" = gate ]; then
  ksr_gate
  exit $?
fi

if [ "$MODE" = reporter ]; then
  if [ "$GATE" = 1 ]; then ksr_gate || exit 3; fi
  ksr_reporter
  echo "reporter: $REP_TO (from $REP_FROM)" >&2
  printf '%s\n' "$REP_TO"
  exit 0
fi

# Practice 07 (agent-token-focus-plan): a short result, the detail in a file.
if [ "$MODE" = result ]; then
  [ -n "$OUTCOME" ] || { echo "kill-your-self-report: --result needs --outcome" >&2; exit 2; }
  max="${RESULT_MAX:-800}"
  [ "${#SHAS[@]}" -gt 0 ] || SHAS=("$(git -C "$WORKDIR" rev-parse --short HEAD 2>/dev/null || echo none)")
  out="${DETAIL_PATH:-${REPORT_DIR:-$SPOOL_ROOT/reports}/${ID:-unknown}.md}"
  if [ -z "$DETAIL_PATH" ]; then
    # Read first, write after: a failed read never truncates the report.
    body=""
    if [ -n "$DETAIL" ]; then
      [ "$DETAIL" = - ] || [ -r "$DETAIL" ] || { echo "kill-your-self-report: cannot read --detail $DETAIL; nothing written" >&2; exit 2; }
      body="$(cat -- "$DETAIL")" || exit 1
    fi
    [ -n "${body//[[:space:]]/}" ] || body="$(printf '# %s report\n\n%s\n%ssha: %s\n' "${ID:-unknown}" "$OUTCOME" "${NUMBERS:+numbers: $NUMBERS$'\n'}" "${SHAS[*]}")"
    mkdir -p "$(dirname "$out")" && printf '%s\n' "$body" >"$out" || exit 1
  fi
  outcome="${OUTCOME//$'\n'/ }" numbers="${NUMBERS//$'\n'/ }"
  tail_="sha: ${SHAS[*]}"$'\n'"detail: $out"
  room=$(( max - ${#tail_} - 2 - (${#numbers} ? 10 : 0) ))
  if [ $(( ${#outcome} + ${#numbers} )) -gt "$room" ]; then
    # The body is cut to fit; the whole text stays in the detail file.
    [ -n "$DETAIL_PATH" ] || { mkdir -p "$(dirname "$out")" && printf '\n## outcome\n%s\n\n## numbers\n%s\n' "$OUTCOME" "$NUMBERS" >>"$out"; }
    (( room < 8 )) && room=8
    keep_n=$(( ${#numbers} < room / 2 ? ${#numbers} : room / 2 ))
    keep_o=$(( room - keep_n ))
    (( ${#outcome} > keep_o )) && outcome="${outcome:0:keep_o-3}..."
    (( ${#numbers} > keep_n )) && numbers="${numbers:0:keep_n-3}..."
  fi
  printf '%s\n%s%s\n' "$outcome" "${numbers:+numbers: $numbers$'\n'}" "$tail_"
  exit 0
fi

echo "=== kill-your-self discovery (read-only) ==="
echo "WORKDIR:  $WORKDIR"
echo "user:     $(id -un)"
echo "date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
kind="$(spl_kind_of_agent_id "$ID")" || kind=unknown
echo "agent id: ${ID:-unknown}${ID:+ (from $SRC)}   kind: $kind"
echo "window:   ${wname:-n/a}"
if [ -n "$ID" ] && [ -d "$SPOOL_ROOT/$ID/inbox" ]; then
  echo "spool:    $(find "$SPOOL_ROOT/$ID/inbox" -maxdepth 1 -type f | wc -l) unread in $SPOOL_ROOT/$ID/inbox (spool recv --as $ID; --ack once acted on)"
fi

echo
echo "=== git ==="
if git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  br="$(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  up="$(git -C "$WORKDIR" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  trunk="$(git -C "$WORKDIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/master)"
  echo "branch:   $br"
  echo "dirty:    $(git -C "$WORKDIR" status --porcelain 2>/dev/null | wc -l) path(s)"
  if git -C "$WORKDIR" rev-parse --verify -q "$trunk" >/dev/null; then
    echo "not on $trunk: $(git -C "$WORKDIR" rev-list --count "$trunk..HEAD" 2>/dev/null) commit(s) (as of the last fetch)"
  fi
  [ -n "$up" ] && echo "upstream: $up"
else
  echo "not a git work tree"
fi

echo
echo "=== candidate specs/*/tasks.md (newest first, cap 20) ==="
find "$WORKDIR" \( -path '*/.git/*' -o -path '*/node_modules/*' -o -path '*/.venv/*' \) -prune -o \
  -type f -path '*/specs/*/tasks.md' -printf '%T@|%p\n' 2>/dev/null | sort -t'|' -k1,1nr | sed -n 1,20p |
while IFS='|' read -r mt path; do
  slug="$(printf '%s' "$path" | sed -n 's|.*/specs/\([^/]*\)/tasks.md|\1|p')"
  open_n="$(grep -cE '^[[:space:]]*- \[ \]' "$path" 2>/dev/null)"; done_n="$(grep -cE '^[[:space:]]*- \[[xX]\]' "$path" 2>/dev/null)"
  echo "  $path"
  echo "    slug=$slug  open=${open_n:-0}  done=${done_n:-0}  mtime=$(date -u -d "@${mt%.*}" +%Y-%m-%dT%H:%M:%SZ)"
done

echo
echo "=== notes ==="
echo "- Open the active feature's tasks.md and tick only the boxes that are truly done."
echo "- Prefer the feature your brief names over the newest mtime."
echo "- This script never edits files and never exits the agent."
