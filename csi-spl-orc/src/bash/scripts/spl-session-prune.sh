#!/usr/bin/env bash
# spl-session-prune.sh - remove OLD Claude Code session transcripts of dead,
# unrestorable sessions (owner, HUM-10 t1 a5aeaef8, 2026-10-08: "remove also
# some old AI session data which is older than 3 days").
#
# Claude Code keeps one transcript per session under the user's
# ~/.claude/projects/<project-slug>/: <session-uuid>.jsonl, and beside it an
# optional <session-uuid>/ dir (subagent transcripts, tool results). Rotation
# and restore resume a seat from that file, so a session is removed only when
# ALL hold:
#   - its name is a session uuid, the file / dir is ours and no symlink;
#   - no agent record names it: $SPOOL_ROOT/agents/*.json "session_id" (the
#     sessions a restore starts again; retired/ records are not read);
#   - no live session claims it: a pid in <sessions>/*.json that still runs,
#     or a running process whose command line names the uuid (a --resume);
#   - nothing of it (the .jsonl, or anything under the dir) changed in the
#     last AGE_DAYS days;
#   - in a HUMAN user's tree (SESSION_PRUNE_HUMAN_USERS, default EVERY user
#     pruned), its project dir is an agent worktree's
#     (SESSION_PRUNE_AGENT_SLUG_ERE: <repo>-wt-<agent id>). The owner's
#     interactive sessions (any other project dir) are never removed: on a PC,
#     2026-10-08, both the box user's and the agent user's -opt trees held
#     the owner's own chats (sessions moved between the users on 2026-10-01);
#   - when its project dir is an agent worktree's, that agent is no role seat
#     (SESSION_PRUNE_KEEP_RE, wt-dead-sweep's) and its agent record does not
#     say alive: a seat's earlier rotations stay with the seat.
# An agents dir or sessions dir that cannot be read decides nothing (exit 2).
# Nothing else under the projects root (memory/, other files) is touched.
#
# Mistral Vibe (spec 110, seat 2) keeps one dir per session under
# $VIBE_HOME/logs/session: session_<YYYYMMDD_HHMMSS>_<short id>/ with a
# meta.json (session_id, environment.working_directory) and messages.jsonl.
# The same rules decide it: the agent worktree is its working directory (as
# a Claude slug), live = its session id or short id on a running command
# line. The session dir is kept at mode 0700 (DRY_RUN=1 plans the chmod).
#
# Users: SESSION_PRUNE_USERS (space-separated), default the box user (owner of
# the checkout), SPOOL_AGENT_USER and the spool-agents group. Each user's
# tree is pruned AS that user (sudo -n -u when it is not us). A test names
# its tree with SESSION_PRUNE_ROOT instead (then no user is consulted).
#
#   DRY_RUN=1 (default) | 0
#   AGE_DAYS                default 3
#   SESSION_PRUNE_USERS     see above
#   SESSION_PRUNE_HUMAN_USERS  default every user ("" = none): agent slugs only
#   SESSION_PRUNE_AGENT_ONLY   1: this tree is a human's (set by the outer run)
#   SESSION_PRUNE_AGENT_SLUG_ERE  default: -wt<N>-<agent id> at the slug's end
#   SESSION_PRUNE_KEEP_RE   default ^(c-00[1-3]|CLE-00[1-3])$
#   SESSION_PRUNE_ROOT      one projects root, pruned as the current user
#   SESSION_PRUNE_SESSIONS  default <home>/.claude/sessions
#   SESSION_PRUNE_VIBE_DIR  one Vibe session dir; the outer run passes
#                           <home>/.vibe/logs/session ($VIBE_HOME for us);
#                           unset in an inner run = no Vibe pruning
#   SPOOL_ROOT              default /var/spool-hub (its agents/ records)
#
# One PLAN|REMOVE / KEEP line per session, a DONE line per user.
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
age_d="${AGE_DAYS:-3}"
spool="${SPOOL_ROOT:-/var/spool-hub}"
uuid_ere='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
agent_only="${SESSION_PRUNE_AGENT_ONLY:-0}"
slug_ere='-wt[0-9]*-([acgmq]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+)$'
slug_ere="${SESSION_PRUNE_AGENT_SLUG_ERE:-$slug_ere}"
keep_re="${SESSION_PRUNE_KEEP_RE:-^(c-00[1-3]|CLE-00[1-3])\$}"
self="$(readlink -f "${BASH_SOURCE[0]}")"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }

# judge <slug> <sid> <part>... -> why the session stays (empty = it goes)
judge() {
  local slug="$1" sid="$2" aid x why=""; shift 2
  if [[ "$slug" =~ $slug_ere ]]; then
    aid="${slug##*-wt}"; aid="${aid#*-}"
    if [[ "$aid" =~ $keep_re ]]; then why="role-seat"
    elif [[ -n "${alive_ids[$aid]:-}" ]]; then why="alive"; fi
  elif [[ "$agent_only" == 1 ]]; then why="human"
  fi
  for x; do
    if [[ -L "$x" ]]; then why="symlink"; elif [[ ! -O "$x" ]]; then why="not-ours"; fi
  done
  [[ -z "$why" && -n "$sid" && -n "${keep[$sid]:-}" ]] && why="${keep[$sid]}"
  [[ -z "$why" && -n "$(find "$@" -newermt "-${age_d} days" -print -quit 2>/dev/null)" ]] && why="recent"
  printf '%s' "$why"
}

# settle <stem> <why> <part>... -> one KEEP / PLAN / REMOVE line, the counts
settle() {
  local stem="$1" why="$2" kb; shift 2
  if [[ -n "$why" ]]; then say "KEEP $why $stem"; n_keep=$((n_keep + 1)); return; fi
  kb="$(du -sck -- "$@" 2>/dev/null | tail -1 | cut -f1)"; kb="${kb:-0}"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB $stem"
  else
    rm -rf -- "$@" && say "REMOVE ${kb}KB $stem" || { say "WARN could not remove $stem"; return; }
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
}

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$age_d" =~ ^[0-9]+$ ]] && (( age_d >= 1 )) || refuse "AGE_DAYS must be a whole number >= 1, got '$age_d'"
[[ "$agent_only" == 0 || "$agent_only" == 1 ]] || refuse "SESSION_PRUNE_AGENT_ONLY must be 0 or 1, got '$agent_only'"

# ---- the outer run: one inner run per user, as that user --------------------
if [[ -z "${SESSION_PRUNE_ROOT:-}" ]]; then
  users="${SESSION_PRUNE_USERS:-}"
  if [[ -z "${SESSION_PRUNE_USERS+x}" ]]; then
    [[ "${SPOOL_TEST:-0}" == 1 ]] && refuse "SPOOL_TEST=1 and no SESSION_PRUNE_ROOT / SESSION_PRUNE_USERS: a test names its tree"
    box="${SPOOL_BOX_USER:-}"
    [[ -z "$box" && -n "${PROJ_PATH:-}" ]] && box="$(stat -c %U "$PROJ_PATH" 2>/dev/null || true)"
    members="$(getent group "${SPOOL_ROOT_GROUP:-spool-agents}" 2>/dev/null | awk -F: 'NR==1 { print $4 }' | tr ',' ' ')"
    # shellcheck disable=SC2086 # space-separated user names
    users="$(printf '%s\n' $box ${SPOOL_AGENT_USER:-} $members | awk 'NF && !seen[$0]++' | paste -sd' ' -)"
  fi
  [[ -n "$users" ]] || refuse "no user to prune (set SESSION_PRUNE_USERS)"
  humans=" ${SESSION_PRUNE_HUMAN_USERS-$users} "
  rc=0
  for u in $users; do
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home" ]] || { say "WARN user=$u: no such user, skipped"; rc=2; continue; }
    vibe_home="$home/.vibe"; [[ "$u" == "$(id -un)" ]] && vibe_home="${VIBE_HOME:-$vibe_home}"
    envs=(DRY_RUN="$dry" AGE_DAYS="$age_d" SPOOL_ROOT="$spool" SESSION_PRUNE_ROOT="$home/.claude/projects"
      SESSION_PRUNE_VIBE_DIR="$vibe_home/logs/session"
      SESSION_PRUNE_SESSIONS="$home/.claude/sessions" SESSION_PRUNE_AGENT_SLUG_ERE="$slug_ere" SESSION_PRUNE_KEEP_RE="$keep_re"
      SESSION_PRUNE_AGENT_ONLY="$([[ "$humans" == *" $u "* ]] && echo 1 || echo 0)")
    if [[ "$u" == "$(id -un)" ]]; then
      env "${envs[@]}" bash "$self" || rc=$?
    else
      sudo -n -u "$u" -H env "${envs[@]}" bash "$self" || { r=$?; say "WARN user=$u: prune rc=$r (no sudo -n, or a refusal)"; rc=$r; }
    fi
  done
  exit "$rc"
fi

# ---- the inner run: one projects root, as its owner -------------------------
root="$SESSION_PRUNE_ROOT"
sessions="${SESSION_PRUNE_SESSIONS:-$HOME/.claude/sessions}"
vibe="${SESSION_PRUNE_VIBE_DIR:-}"
[[ -n "$vibe" && -d "$vibe" ]] || vibe=""
if [[ ! -d "$root" || -L "$root" ]]; then
  [[ -n "$vibe" ]] || { say "OK user=$(id -un) no projects root $root: nothing to prune"; exit 0; }
  root=""
fi
[[ -z "$root" || -O "$root" ]] || refuse "$root is not owned by $(id -un)"
[[ -z "$vibe" || ( ! -L "$vibe" && -O "$vibe" ) ]] || refuse "$vibe is not owned by $(id -un) or is a symlink"
[[ -d "$spool/agents" && -r "$spool/agents" && -x "$spool/agents" ]] || refuse "cannot read the agent records in $spool/agents"
[[ -z "$root" || ( -d "$sessions" && -r "$sessions" && -x "$sessions" ) ]] || refuse "cannot read the live sessions in $sessions"

# The kept session ids: every agent record's session_id, a registry entry
# whose pid still runs, and any uuid on a running process's command line.
declare -A keep=()
while read -r why sid; do
  [[ "$sid" =~ ^${uuid_ere}$ ]] && keep["$sid"]="$why"
done < <(python3 - "$spool/agents" "$sessions" <<'PY'
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if isinstance(d, dict) and d.get("session_id"):
        print("restorable", d["session_id"])
for f in glob.glob(os.path.join(sys.argv[2], "*.json")):
    try:
        d = json.load(open(f))
        pid = int(d["pid"])
    except Exception:
        continue
    if pid > 0 and os.path.isdir("/proc/%d" % pid):
        print("live", d.get("sessionId", "-"))
PY
)
# The agents whose record says alive: their worktree sessions stay.
declare -A alive_ids=()
while read -r aid; do [[ -n "$aid" ]] && alive_ids["$aid"]=1; done < <(python3 - "$spool/agents" <<'PY'
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if isinstance(d, dict) and d.get("alive") is True:
        print(os.path.basename(f)[:-5])
PY
)
procs=""
for c in /proc/[0-9]*/cmdline; do
  line="$(tr '\0' ' ' 2>/dev/null <"$c")"
  procs+="$line"$'\n'
  while IFS= read -r sid; do
    [[ -n "$sid" ]] && keep["$sid"]=live
  done < <(grep -oE "$uuid_ere" <<<"$line")
done

say "START user=$(id -un) root=${root:--} vibe=${vibe:--} dry_run=$dry age_days=$age_d agent_only=$agent_only kept_ids=${#keep[@]}"
n_rm=0 kb_rm=0 n_keep=0
[[ -n "$root" ]] && while IFS= read -r -d '' p; do
  base="${p##*/}"; sid="${base%.jsonl}"
  [[ "$sid" =~ ^${uuid_ere}$ ]] || continue
  # A session with both a .jsonl and a dir is decided once, from the .jsonl.
  [[ "$base" != *.jsonl && -e "$p.jsonl" ]] && continue
  stem="${p%.jsonl}"
  parts=()
  for x in "$stem.jsonl" "$stem"; do [[ -e "$x" || -L "$x" ]] && parts+=("$x"); done
  # Gone already: its dir, listed by find, went with its .jsonl a moment ago.
  (( ${#parts[@]} )) || continue
  slug="${stem%/*}"; slug="${slug##*/}"
  settle "$stem" "$(judge "$slug" "$sid" "${parts[@]}")" "${parts[@]}"
done < <(find "$root" -mindepth 2 -maxdepth 2 \( -name '*.jsonl' -o -type d \) -print0)

# ---- Vibe: <vibe>/session_<date>_<time>_<short id>/, kept at mode 0700 -------
if [[ -n "$vibe" ]]; then
  mode="$(stat -c %a "$vibe")"
  if [[ "$mode" != 700 ]]; then
    if [[ "$dry" == 1 ]]; then say "PLAN chmod 0700 (was $mode) $vibe"
    else chmod 0700 "$vibe" && say "MODE 0700 (was $mode) $vibe" || say "WARN could not chmod 0700 $vibe"; fi
  fi
  while IFS=$'\t' read -r name sid cwd; do
    p="$vibe/$name"
    [[ "$name" =~ ^[A-Za-z0-9-]+_[0-9]{8}_[0-9]{6}_([A-Za-z0-9-]+)$ ]] || continue
    short="${BASH_REMATCH[1]}"
    [[ "$sid" == - ]] && sid=""
    slug=""; [[ "$cwd" == /* ]] && slug="${cwd//[^A-Za-z0-9]/-}"
    why="$(judge "$slug" "$sid" "$p")"
    [[ -z "$why" && ( ( -n "$sid" && "$procs" == *"$sid"* ) || "$procs" == *"$short"* ) ]] && why="live"
    settle "$p" "$why" "$p"
  done < <(python3 - "$vibe" <<'PY2'
import json, os, sys
for n in sorted(os.listdir(sys.argv[1])):
    p = os.path.join(sys.argv[1], n)
    if os.path.islink(p) or not os.path.isdir(p):
        continue
    sid, cwd = "-", "-"
    try:
        d = json.load(open(os.path.join(p, "meta.json")))
        sid = str(d.get("session_id") or "-")
        cwd = str((d.get("environment") or {}).get("working_directory") or d.get("origin_directory") or "-")
    except Exception:
        pass
    print("\t".join(x.replace("\t", " ").replace("\n", " ") for x in (n, sid, cwd)))
PY2
)
fi
say "DONE user=$(id -un) $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep"
