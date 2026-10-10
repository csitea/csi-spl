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
#        kill-your-self-report.sh --reporter [WORKDIR]
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
# else "orchestrator". stderr says which source won.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
# shellcheck source=../lib/agent-state.inc.sh
. "$_here/../lib/agent-state.inc.sh"
SPOOL_ENV_NO_BINS=1 spool_env_resolve

MODE=discovery OUTCOME="" NUMBERS="" DETAIL="" DETAIL_PATH="" SHAS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --result) MODE=result ;;
    --reporter) MODE=reporter ;;
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
# brief named.
if [ "$MODE" = reporter ]; then
  life="$SPOOL_ROOT/${ID:-none}/lifetime" to="" from=""
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
  echo "reporter: $to (from $from)" >&2
  printf '%s\n' "$to"
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
