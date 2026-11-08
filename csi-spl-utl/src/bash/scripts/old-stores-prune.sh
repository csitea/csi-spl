#!/usr/bin/env bash
# old-stores-prune.sh - remove old grok session dirs or old retired-agent dirs
# (SPL-5064). One target per run, as the user that owns the tree; a dir owned
# by another user is KEEP not-ours, so each owner runs it once.
#
# OLD_STORE_TARGET=grok: <GROK_SESSIONS>/<url-encoded cwd>/<session id>/. Stays
# when: the cwd is no agent worktree (human), the agent is a role seat or its
# record says alive, an agent record names the session (restorable), grok's
# active_sessions.json or a running command line names it (live), a process
# holds a file in it (open), or anything changed in AGE_DAYS (recent).
#
# OLD_STORE_TARGET=retired: <SPOOL_ROOT>/.retired/<id>.<utc>[.n]/. Stays when:
# the id is a role seat or back in registry.tsv (reused), a process holds a
# file in it (open), or anything changed in AGE_DAYS (recent). The lane issue
# and the push orphan check read young retired dirs: AGE_DAYS keeps those.
# Each removed dir's inbox/*.json count is reported: mail nobody acked.
#
# OLD_STORE_TARGET=transcripts: Claude Code sessions, <OLD_PROJECTS>/<slug>/
# <uuid>.jsonl and its <uuid>/ dir, the two sets do_spl_session_prune keeps for
# good. OLD_TRANSCRIPT_SET picks one: human (project dir is no agent worktree;
# can hold the owner's own chats) or role-seat (earlier rotations of a role
# seat). Each needs the owner's yes for that set (SPL-5064, poll b1f4285d). A
# seat's record says alive for as long as it serves, so alive keeps nothing
# here. Stays when: outside the set, an agent record names it (restorable), a
# running session or command line names it (live), a process holds a file of
# it (open), or anything changed in AGE_DAYS (recent).
#
# Exit: 0 done; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
age_d="${AGE_DAYS:-7}"
target="${OLD_STORE_TARGET:-}"
spool="${SPOOL_ROOT:-/var/spool-hub}"
grok_root="${GROK_SESSIONS:-$HOME/.grok/sessions}"
projects="${OLD_PROJECTS:-$HOME/.claude/projects}"
sessions="${OLD_SESSIONS:-$HOME/.claude/sessions}"
tset="${OLD_TRANSCRIPT_SET:-}"
active="${GROK_ACTIVE:-$(dirname "$grok_root")/active_sessions.json}"
self="$(readlink -f "${BASH_SOURCE[0]}")"
# shellcheck source=../../../../csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh
. "$(dirname "$self")/../../../../csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
id_ere='[acgmoqu]-[0-9]{3}|(CLE|GRK|AGY|QWN)-[0-9]+'
uuid_ere='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
role_re="^(${SPL_ROLE_SEAT_RX}|CLE-00[1-3])\$"
n_rm=0 kb_rm=0 n_keep=0 n_mail=0
declare -A keep=() alive=() held=() registry=()

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }

# Every process's open files and cwd. Another user's are only readable with
# sudo; a test sees its own processes.
proc_links() {
  local scan='find /proc/[0-9]*/fd /proc/[0-9]*/cwd -maxdepth 1 -printf "%l\n" 2>/dev/null'
  if [[ "${SPOOL_TEST:-0}" == 1 ]]; then bash -c "$scan"; else sudo -n bash -c "$scan"; fi
  return 0
}

# load_held <root> <depth>: the first <depth> path parts under root are held.
load_held() {
  local root="$1" depth="$2" link key
  while IFS= read -r link; do
    key="$(cut -d/ -f"1-$depth" <<<"${link#"$root"/}")"
    held["$key"]=1
  done < <(proc_links | grep -F -- "$root/")
}

load_agents() {
  local why val
  while read -r why val; do
    [[ "$why" == alive ]] && alive["$val"]=1 || keep["$val"]="$why"
  done < <(python3 - "$spool/agents" "$active" <<'PY'
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    if isinstance(d, dict) and d.get("session_id"):
        print("restorable", d["session_id"])
    if isinstance(d, dict) and d.get("alive") is True:
        print("alive", os.path.basename(f)[:-5])
try:
    for s in json.load(open(sys.argv[2])):
        print("live", s["session_id"])
except Exception:
    pass
PY
)
  local sid
  while IFS= read -r sid; do keep["$sid"]=live; done \
    < <(cat /proc/[0-9]*/cmdline 2>/dev/null | tr '\0' '\n' | grep -oE "$uuid_ere")
}

# load_claude_live: a session whose registry entry has a running pid is live.
load_claude_live() {
  local sid
  while IFS= read -r sid; do [[ -n "$sid" ]] && keep["$sid"]=live; done < <(python3 - "$sessions" <<'PY2'
import glob, json, os, sys
for f in glob.glob(os.path.join(sys.argv[1], "*.json")):
    try:
        d = json.load(open(f))
        pid = int(d["pid"])
    except Exception:
        continue
    if pid > 0 and os.path.isdir("/proc/%d" % pid):
        print(d.get("sessionId", ""))
PY2
)
}

# settle <path> <why> [more paths of the same item]: one KEEP / PLAN / REMOVE
# line and the counts.
settle() {
  local p="$1" why="$2" kb mail=0 x
  shift 2
  local parts=("$p" "$@")
  for x in "${parts[@]}"; do
    [[ -z "$why" && -L "$x" ]] && why="symlink"
    [[ -z "$why" && ! -O "$x" ]] && why="not-ours"
  done
  [[ -z "$why" && -n "$(find "${parts[@]}" -newermt "-${age_d} days" -print -quit 2>/dev/null)" ]] && why="recent"
  if [[ -n "$why" ]]; then say "KEEP $why $p"; n_keep=$((n_keep + 1)); return; fi
  kb="$(du -sck -- "${parts[@]}" 2>/dev/null | tail -1 | cut -f1)"; kb="${kb:-0}"
  [[ "$target" == retired ]] && mail="$(find "$p/inbox" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)"
  if [[ "$dry" == 1 ]]; then
    say "PLAN remove ${kb}KB unread=$mail $p"
  elif rm -rf -- "${parts[@]}" 2>/dev/null && [[ ! -e "$p" && ! -e "${parts[-1]}" ]]; then
    say "REMOVE ${kb}KB unread=$mail $p"
  else
    say "WARN could not remove $p"; return
  fi
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb)); n_mail=$((n_mail + mail))
}

grok_why() {
  local enc="$1" sid="$2" cwd aid
  cwd="$(printf '%b' "${enc//%/\\x}")"
  [[ "$cwd" =~ /[^/]*-wt[0-9]*/($id_ere)$ ]] || { printf human; return; }
  aid="${BASH_REMATCH[1]}"
  if [[ "$aid" =~ $role_re ]]; then printf role-seat
  elif [[ -n "${alive[$aid]:-}" ]]; then printf alive
  elif [[ -n "${keep[$sid]:-}" ]]; then printf '%s' "${keep[$sid]}"
  elif [[ -n "${held[$enc/$sid]:-}" ]]; then printf open
  fi
}

prune_grok() {
  [[ -d "$grok_root" && ! -L "$grok_root" ]] || { say "OK no grok sessions at $grok_root"; return; }
  [[ -d "$spool/agents" && -r "$spool/agents" && -x "$spool/agents" ]] || refuse "cannot read the agent records in $spool/agents"
  local root p enc sid
  root="$(readlink -f "$grok_root")"
  load_agents; load_held "$root" 2
  while IFS= read -r -d '' p; do
    sid="${p##*/}"; enc="${p%/*}"; enc="${enc##*/}"
    [[ "$sid" =~ ^${uuid_ere}$ ]] || continue
    settle "$p" "$(grok_why "$enc" "$sid")"
  done < <(find "$root" -mindepth 2 -maxdepth 2 -type d -print0)
}

prune_retired() {
  local root="$spool/.retired" p name id
  [[ -d "$root" && ! -L "$root" ]] || { say "OK no retired dirs at $root"; return; }
  [[ -r "$spool/registry.tsv" ]] || refuse "cannot read $spool/registry.tsv"
  root="$(readlink -f "$root")"
  while IFS=$'\t' read -r id _; do registry["${id%%@*}"]=1; done <"$spool/registry.tsv"
  load_held "$root" 1
  while IFS= read -r -d '' p; do
    name="${p##*/}"
    [[ "$name" =~ ^([A-Za-z0-9-]+)\.[0-9]{8}T[0-9]{6}Z(\.[0-9]+)?$ ]] || { say "KEEP name $p"; n_keep=$((n_keep + 1)); continue; }
    id="${BASH_REMATCH[1]}"
    if [[ "$id" =~ $role_re ]]; then settle "$p" role-seat
    elif [[ -n "${registry[$id]:-}" ]]; then settle "$p" reused
    elif [[ -n "${held[$name]:-}" ]]; then settle "$p" open
    else settle "$p" ""; fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0)
}

transcript_why() {
  local slug="$1" sid="$2" set=human
  if [[ "$slug" =~ -wt[0-9]*-($id_ere)$ ]]; then
    if [[ "${BASH_REMATCH[1]}" =~ $role_re ]]; then set=role-seat; else set=agent; fi
  fi
  if [[ "$set" != "$tset" ]]; then printf 'set-%s' "$set"
  elif [[ -n "${keep[$sid]:-}" ]]; then printf '%s' "${keep[$sid]}"
  elif [[ -n "${held[$slug/$sid]:-}${held[$slug/$sid.jsonl]:-}" ]]; then printf open
  fi
}

prune_transcripts() {
  [[ "$tset" == human || "$tset" == role-seat ]] || refuse "OLD_TRANSCRIPT_SET must be human or role-seat, got '$tset'"
  [[ -d "$projects" && ! -L "$projects" ]] || { say "OK no transcripts at $projects"; return; }
  [[ -d "$spool/agents" && -r "$spool/agents" && -x "$spool/agents" ]] || refuse "cannot read the agent records in $spool/agents"
  [[ -d "$sessions" && -r "$sessions" && -x "$sessions" ]] || refuse "cannot read the live sessions in $sessions"
  local root p base sid stem slug x parts
  root="$(readlink -f "$projects")"
  load_agents; load_claude_live; load_held "$root" 2
  while IFS= read -r -d '' p; do
    base="${p##*/}"; sid="${base%.jsonl}"
    [[ "$sid" =~ ^${uuid_ere}$ ]] || continue
    [[ "$base" != *.jsonl && -e "$p.jsonl" ]] && continue
    stem="${p%.jsonl}"; parts=()
    for x in "$stem.jsonl" "$stem"; do [[ -e "$x" || -L "$x" ]] && parts+=("$x"); done
    (( ${#parts[@]} )) || continue
    slug="${stem%/*}"; slug="${slug##*/}"
    settle "${parts[0]}" "$(transcript_why "$slug" "$sid")" "${parts[@]:1}"
  done < <(find "$root" -mindepth 2 -maxdepth 2 \( -name '*.jsonl' -o -type d \) -print0)
}

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$age_d" =~ ^[0-9]+$ ]] && (( age_d >= 1 )) || refuse "AGE_DAYS must be a whole number >= 1, got '$age_d'"
[[ "$target" == grok || "$target" == retired || "$target" == transcripts ]] || refuse "OLD_STORE_TARGET must be grok, retired or transcripts, got '$target'"
[[ "${SPOOL_TEST:-0}" == 1 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: other users' open files cannot be read"

say "START user=$(id -un) target=$target dry_run=$dry age_days=$age_d"
"prune_$target"
say "DONE user=$(id -un) target=$target $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) unread_mail=$n_mail kept=$n_keep"
