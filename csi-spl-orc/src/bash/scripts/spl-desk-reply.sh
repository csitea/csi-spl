#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Standalone fast launcher for answering humans from a desk agent pane.
# @description Bypasses framework initialization to deliver sub-150ms execution.
# @description Reads inbox, matches topic/human, and executes spool send directly.
#
# Usage:
#   spl-desk-reply.sh [--env dev|prd] [--tenant <id>] [--agent <id>]
#                     [--to <HUM-id>] [--task <uuid>] [--kind note|result|reject|blocker|msg]
#                     --body "<text>" [--dry-run] [--ack]
#
# Environment variables:
#   ENV         dev | prd (default: prd)
#   TENANT_ID   tenant id (default: t1)
#   DESK_BOX    box id (default: this machine's, spl_desk_box_default: box-desk)
#   DESK_AGENT  agent id (e.g. AGY-3493; defaults to tmux window name)
#   DESK_TO     human id (optional; auto-picked from newest if omitted)
#   DESK_TASK   task uuid (optional; auto-picked from newest if omitted)
#   DESK_KIND   note | result | reject | blocker | msg (default: note)
#   DESK_BODY   reply text (required)
#   DESK_ACK    1 to ack/archive answered message (default: 0)
#   DRY_RUN     1 for dry run, 0 to send (default: 0)
#------------------------------------------------------------------------------
set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^#---/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

ENV="${ENV:-prd}"
TENANT_ID="${TENANT_ID:-t1}"
# shellcheck source=../../../lib/bash/funcs/spl-desk-box.func.sh
. "$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)/lib/bash/funcs/spl-desk-box.func.sh"
DESK_BOX="${DESK_BOX:-$(spl_desk_box_default)}"
DESK_AGENT="${DESK_AGENT:-}"
DESK_TO="${DESK_TO:-}"
DESK_TASK="${DESK_TASK:-}"
DESK_KIND="${DESK_KIND:-note}"
DESK_BODY="${DESK_BODY:-}"
DESK_ACK="${DESK_ACK:-0}"
DRY_RUN="${DRY_RUN:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)       ENV="$2"; shift 2 ;;
    --tenant)    TENANT_ID="$2"; shift 2 ;;
    --box)       DESK_BOX="$2"; shift 2 ;;
    --agent)     DESK_AGENT="$2"; shift 2 ;;
    --to)        DESK_TO="$2"; shift 2 ;;
    --task)      DESK_TASK="$2"; shift 2 ;;
    --kind)      DESK_KIND="$2"; shift 2 ;;
    --body)      DESK_BODY="$2"; shift 2 ;;
    --ack)       DESK_ACK="1"; shift ;;
    --dry-run)   DRY_RUN="1"; shift ;;
    -h|--help)   usage ;;
    *)           echo "Unknown option: $1" >&2; usage ;;
  esac
done

if [[ -z "$DESK_AGENT" ]]; then
  if command -v tmux >/dev/null 2>&1; then
    DESK_AGENT="$(tmux display-message -p '#W' 2>/dev/null || true)"
    DESK_AGENT="${DESK_AGENT%% *}"
  fi
fi

if [[ -z "$DESK_BODY" && "$DRY_RUN" -ne 1 ]]; then
  echo "FATAL: DESK_BODY or --body must carry the answer text" >&2
  exit 1
fi

if [[ -z "$DESK_AGENT" ]]; then
  echo "FATAL: DESK_AGENT or --agent could not be detected" >&2
  exit 1
fi

# Locate desk state directory
d=""
candidate_bases=(
  "${SPL_STATE_DIR:-}"
  "$HOME/.local/share/csi-spl/cloud/$ENV"
)
# If running as another user, also check the home of whoever owns the checkout or /home/*
for base in "${candidate_bases[@]}"; do
  [[ -n "$base" && -d "$base/desk/$TENANT_ID/$DESK_BOX" ]] && { d="$base/desk/$TENANT_ID/$DESK_BOX"; break; }
done

if [[ -z "$d" ]]; then
  # Fallback: scan existing desk state paths
  for p in /home/*/.local/share/csi-spl/cloud/"$ENV"/desk/"$TENANT_ID"/"$DESK_BOX"; do
    if [[ -d "$p" ]]; then d="$p"; break; fi
  done
fi

if [[ -z "$d" || ! -d "$d" ]]; then
  echo "FATAL: cannot find desk state directory for $ENV/$TENANT_ID/$DESK_BOX" >&2
  exit 1
fi

# Locate spool binary
spool_bin="${SPL_SPOOL:-}"
if [[ -z "$spool_bin" || ! -x "$spool_bin" ]]; then
  candidate_spools=(
    "$(dirname "$d")/../../bin/spool"
    "$HOME/.local/share/csi-spl/cloud/$ENV/bin/spool"
    "/home/*/.local/share/csi-spl/cloud/$ENV/bin/spool"
  )
  for s in "${candidate_spools[@]}"; do
    if [[ -x "$s" ]]; then spool_bin="$s"; break; fi
  done
  if [[ -z "$spool_bin" || ! -x "$spool_bin" ]]; then
    spool_bin="$(command -v spool 2>/dev/null || true)"
  fi
fi

if [[ -z "$spool_bin" || ! -x "$spool_bin" ]]; then
  echo "FATAL: cannot find executable spool binary" >&2
  exit 1
fi

# Determine Hub URL: SPOOL_HUB_URL, else the env's api_fqdn from cnf. No
# baked-in host - the domain lives only in csi-spl-cnf (domain-single-source).
hub="${SPOOL_HUB_URL:-}"
if [[ -z "$hub" ]]; then
  cnf_json="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)/csi-spl-cnf/csi-spl/$ENV.env.json"
  api_fqdn="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["env"]["dns"]["api_fqdn"])' "$cnf_json" 2>/dev/null || true)"
  if [[ -z "$api_fqdn" ]]; then
    echo "FATAL: no SPOOL_HUB_URL and no env.dns.api_fqdn in $cnf_json" >&2
    exit 1
  fi
  hub="https://$api_fqdn"
fi

# Dry run inspection
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "DRY_RUN: would answer as $DESK_AGENT on $DESK_BOX in $TENANT_ID ($ENV) via $spool_bin"
  exit 0
fi

# Auto-pick recipient and task if either is missing
ans_to="$DESK_TO"
ans_task="$DESK_TASK"
ans_msg=""
ans_head=""

if [[ -z "$ans_to" || -z "$ans_task" ]]; then
  inbox_dir="$d/spool/$DESK_AGENT/inbox"
  answered_file="$d/answered"
  if [[ ! -d "$inbox_dir" ]]; then
    echo "FATAL: inbox directory not found: $inbox_dir" >&2
    exit 1
  fi

  pick="$(python3 - "$inbox_dir" "$answered_file" "$ans_to" "$ans_task" <<'EOF_PY'
import json, glob, os, sys

inbox_dir, answered_file, req_to, req_task = sys.argv[1:5]
since = ""
try:
    with open(answered_file) as f:
        since = str(json.load(f).get("ts", ""))
except Exception:
    since = ""

files = sorted(glob.glob(os.path.join(inbox_dir, "*.json")))
msgs = []
for fp in files:
    try:
        with open(fp) as f:
            m = json.load(f)
            if isinstance(m, dict) and str(m.get("from", "")).startswith("HUM-"):
                msgs.append(m)
    except Exception:
        continue

if req_to:
    msgs = [m for m in msgs if m.get("from") == req_to]
if req_task:
    msgs = [m for m in msgs if m.get("task_id") == req_task]

msgs.sort(key=lambda m: (str(m.get("ts", "")), str(m.get("msg_id", ""))))

if not req_to or not req_task:
    msgs = [m for m in msgs if not since or str(m.get("ts", "")) > since]

if not msgs:
    if req_to and req_task:
        print(f"{req_to}\t{req_task}\t\t")
        sys.exit(0)
    sys.exit(3)

topics = {}
for m in msgs:
    topics.setdefault((m.get("from", ""), m.get("task_id", "")), []).append(m)

if len(topics) > 1 and not (req_to and req_task):
    for (frm, tsk), ml in sorted(topics.items(), key=lambda kv: str(kv[1][-1].get("ts", ""))):
        head = " ".join(str(ml[-1].get("body", "")).split())[:60]
        print(f"DESK_TO={frm} DESK_TASK={tsk} ({len(ml)} waiting: {head})", file=sys.stderr)
    sys.exit(4)

target = msgs[-1]
to = req_to or target.get("from", "")
tsk = req_task or target.get("task_id", "")
msg_id = target.get("msg_id", "")
head = " ".join(str(target.get("body", "")).split())[:80]
print(f"{to}\t{tsk}\t{msg_id}\t{head}")
EOF_PY
)" || {
    prc=$?
    if [[ $prc -eq 3 ]]; then
      echo "INFO: $DESK_AGENT has nothing newer than its last answer to reply to" >&2
      exit 3
    elif [[ $prc -eq 4 ]]; then
      echo "FATAL: multiple conversations waiting; specify --to and --task" >&2
      exit 4
    else
      echo "FATAL: failed to pick message" >&2
      exit 1
    fi
  }

  IFS=$'\t' read -r ans_to ans_task ans_msg ans_head <<<"$pick"
fi

# Execute direct spool send
sent="$(SPOOL_ROOT="$d/spool" \
  SPOOL_KEYS_DIR="$d/keys" \
  SPOOL_BOX_ID="$DESK_BOX" \
  SPOOL_HUB_URL="$hub" \
  SPOOL_TENANT="$TENANT_ID" \
  "$spool_bin" send \
    --from "$DESK_AGENT" \
    --to "$ans_to" \
    --task "$ans_task" \
    --to-box box-wui \
    --kind "$DESK_KIND" \
    --body "$DESK_BODY")"

# Record watermark in answered
python3 - "$d/answered" "$ans_to" "$ans_task" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" <<'EOF_PY'
import json, sys
answered_file, to, task, ts = sys.argv[1:5]
try:
    with open(answered_file, "w") as f:
        json.dump({"to": to, "task": task, "ts": ts}, f)
except Exception:
    pass
EOF_PY

# Optional archive
if [[ "$DESK_ACK" -eq 1 ]]; then
  SPOOL_ROOT="$d/spool" SPOOL_KEYS_DIR="$d/keys" SPOOL_BOX_ID="$DESK_BOX" \
  SPOOL_HUB_URL="$hub" SPOOL_TENANT="$TENANT_ID" \
  "$spool_bin" recv --as "$DESK_AGENT" --ack >/dev/null 2>&1 || true
fi

# Output JSON result
python3 - "$ENV" "$TENANT_ID" "$DESK_BOX" "$DESK_AGENT" "$DESK_KIND" "$ans_to" "$ans_task" "$ans_msg" "$ans_head" "$sent" <<'EOF_PY'
import json, sys
env, tenant, box, agent, kind, to, task, in_msg, head, sent_raw = sys.argv[1:11]
try:
    sent = json.loads(sent_raw)
except Exception:
    sent = sent_raw
print(json.dumps({
    "agent": agent,
    "answered_head": head,
    "answered_msg_id": in_msg,
    "box": box,
    "env": env,
    "kind": kind,
    "send": sent,
    "task_id": task,
    "tenant": tenant,
    "to": to
}, sort_keys=True))
EOF_PY
