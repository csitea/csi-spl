#!/usr/bin/env bash
# tmp-wt-reap.sh - remove the git worktrees an agent left directly under the
# box's tmp root (a review seat's checkout, its red-control copy), only when
# that agent is PROVEN to have made them (SPL-6347). Why: review seats (mostly
# grok) leave worktrees of the main checkout under /tmp, 11-32k inodes each;
# one box's /tmp tmpfs reached 80% inodes three times in three days and 99%
# once (ENOSPC for every seat), and 18 of its 31 such trees were DIRTY red
# copies of seats already gone. tmp-stale-sweep.sh keeps every worktree,
# wt-dead-sweep.sh keeps every dirty one, and a red copy is dirty by design.
#
# Two modes:
#   --agent <ID>  the retire (agent-id-retire.sh step 8b): <ID>'s own trees.
#   --orphans     the backlog: trees of ids already retired on this box
#                 (registry.retired.tsv or $SPOOL_ROOT/.retired/<ID>.*) that
#                 no live agent holds on ANY box (registry.tsv, the box's tmux
#                 window names, the fleet lane map with the hub answering), and
#                 idle TMP_WT_IDLE_H hours. Run by hand
#                 (csi-spl-utl do_sweep_tmp_worktrees), no cron.
# Without --apply it plans only (PLAN lines) and writes nothing.
#
# A tree is a candidate only when it is a linked worktree of TMP_WT_REPO
# (`git worktree list --porcelain`), sits DIRECTLY under TMP_WT_ROOT, and is
# no symlink. Its owner <ID> is proven by one of (never by its name alone,
# SPL-4761):
#   marker  its git dir holds `spl-owner` naming <ID>: hooks/post-checkout
#           writes it at `git worktree add`, from the creating agent's
#           SPOOL_AGENT_ID (from 2026-11-24 on; older trees have none);
#   outbox  its dir name carries <ID> (g-489-x, g489-x) AND a message <ID>
#           itself SENT (its spool outbox, live or under .retired/) names the
#           exact path. A name alone, or a path only another agent named (a
#           reviewer quotes the author's copy), is KEEP name-only.
# A marker naming another id is that id's tree, whatever its name.
# Kept, whatever the proof: a locked tree, a mount at or under it (findmnt), a
# process with its cwd or an open fd under it (every /proc via sudo -n; a scan
# that cannot read them all removes nothing), a tree owned by another user
# than the main checkout. A clean tree goes by `git worktree remove`; a dirty
# one by `git worktree remove --force` ONLY when its name says it is a red
# control or parent copy (a `red` / `parent` word: g-244-red, g274-r93-01-parent);
# any other dirty tree is KEEP dirty, never forced. The branch stays.
# Never rm -rf: git removes the tree, and only a path git lists.
#
#   --unproven    (SPL-6431) the trees with no proof at all, directly under the
#                 root, idle TMP_WT_IDLE_H (default 24) hours by the newest
#                 mtime AND ctime in the tree (a cp -a / rsync -a / tar -x
#                 copy keeps old mtimes, its ctime is new), two classes (on
#                 one box, 2026-11-24: 59 such id trees held 313931 inodes,
#                 16 round dirs ~136k):
#     agent-id    <prefix><id>-* (g164-r7, g-215-r92-02-red: a dash after the
#                 id, so a mktemp hex name is no id) holding a git repo or
#                 worktree anywhere in it (a plain clone, a worktree, nested
#                 worktrees); kept while the id (or its spl-owner marker's id)
#                 is live on any box. A dir with no git in it is not listed.
#     round       r<N>-* / rc<N>-* or a bare r<N> (r86-base01, rc01-scratch,
#                 r93; r76lib is none), git or a
#                 plain copy; kept while a live lane's branch or brief title,
#                 or a window name, names round N (round-86, r86, b86, rc86).
#   Kept, besides the --orphans guards (live sources answering, mount, a
#   process, owner = the main checkout's user or the box's agent user):
#   unpushed: a repo or worktree anywhere in the tree whose HEAD, branch,
#   tag, stash or a worktree's detached HEAD is on no origin ref of the main
#   checkout (`rev-list <tips> --not --remotes=origin`; by sha, so a
#   rebased copy is kept too); a bare repo anywhere in the tree (HEAD, objects/
#   and refs/ outside any .git: remote.git, a bare dir of any name), whatever
#   its refs; a clone with a worktree outside the tree; a dirty repo unless its
#   path has a red / parent word. Removal: each linked worktree by `git
#   worktree remove` from its own repo, then what is left of that ONE path,
#   as its owner (rm -rf --one-file-system, never a glob). Top dirs that are
#   worktrees go first, so a clone with a worktree in another top dir goes in
#   the same run, after it (the idle check skips the mtime of a .git or
#   .git/worktrees dir itself, not the files in it).
#
# Usage: tmp-wt-reap.sh [--apply] (--agent <ID> | --orphans | --unproven)
# Env: TMP_WT_REPO (default: this script's main checkout), TMP_WT_ROOT
#   (default /tmp), TMP_WT_IDLE_H (default 2, --orphans; 24, --unproven),
#   TMP_WT_SUDO=1|0 (0: this user's processes only; tests), TMP_WT_LIVE_IDS
#   (tests: the live ids, space separated; unset = registry.tsv + tmux + lane
#   map), TMP_WT_LIVE_LANES (tests, with TMP_WT_LIVE_IDS: the live lanes'
#   text, a line each), TMP_WT_LANE_MAP (default lane-map.sh here),
#   TMP_WT_NOW (tests, with TMP_WT_SUDO=0 only: the epoch --unproven's idle
#   check counts back from; a test cannot age a ctime), SPOOL_ROOT.
# One PLAN|DO remove / KEEP line per tree, a DONE line.
# Exit 0 done (kept trees included); 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"

APPLY=0 MODE="" ID=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --orphans) MODE=orphans; shift ;;
    --unproven) MODE=unproven; shift ;;
    --agent) [ "$#" -ge 2 ] || { echo "tmp-wt-reap: --agent needs an id" >&2; exit 2; }; MODE=agent; ID="${2%%@*}"; shift 2 ;;
    *) echo "tmp-wt-reap: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "tmp-wt-reap: --agent <ID>, --orphans or --unproven" >&2; exit 2; }
if [ "$MODE" = agent ]; then
  [[ "$ID" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || { echo "tmp-wt-reap: '$ID' is not an agent id" >&2; exit 2; }
fi
VERB=PLAN; [ "$APPLY" = 1 ] && VERB=DO
say() { printf '%s tmp-wt-reap: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }

repo="${TMP_WT_REPO:-$(git -C "$_here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||')}"
root="${TMP_WT_ROOT:-/tmp}"
idle_h="${TMP_WT_IDLE_H:-2}"; [ "$MODE" = unproven ] && idle_h="${TMP_WT_IDLE_H:-24}"
use_sudo="${TMP_WT_SUDO:-1}"
spool="${SPOOL_ROOT:-/var/spool-hub}"
[[ -n "$repo" && -d "$repo/.git" ]] || refuse "TMP_WT_REPO '$repo' is not a main checkout"
[[ -d "$root" && ! -L "$root" ]] || refuse "no tmp root dir $root"
root="$(readlink -f "$root")"
[[ "$idle_h" =~ ^[0-9]+$ ]] && (( idle_h >= 1 )) || refuse "TMP_WT_IDLE_H must be a whole number >= 1, got '$idle_h'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "TMP_WT_SUDO must be 0 or 1, got '$use_sudo'"
now="${TMP_WT_NOW:-}"
if [ -n "$now" ]; then
  [[ "$use_sudo" == 0 && "$now" =~ ^[0-9]+$ ]] || refuse "TMP_WT_NOW is for tests: an epoch, with TMP_WT_SUDO=0"
else now="$(date +%s)"; fi
idle_since="@$(( now - idle_h * 3600 ))"

as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }
repo_user="$(stat -c %U -- "$repo")"
# g ARGS...: git as the main checkout's owner, as every lane's git runs
g() {
  if [[ "$repo_user" == "$(id -un)" ]]; then GIT_TERMINAL_PROMPT=0 timeout 120 git -c safe.directory='*' "$@"
  else timeout 120 sudo -n -u "$repo_user" env GIT_TERMINAL_PROMPT=0 git -c safe.directory='*' "$@"; fi
}

# lane_id NAME: the normalised agent id a dir name starts with (g273-x -> g-273)
lane_id() {
  [[ "${1,,}" =~ ^([acgmoqu])-?([0-9]{3})([^0-9]|$) ]] && printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# marker_of WT: the id in the spl-owner file of WT's git dir, or empty
marker_of() {
  local gd
  gd="$(as_root sed -n 's/^gitdir: //p;T;q' "$1/.git" 2>/dev/null)"
  [ -n "$gd" ] && as_root head -1 "$gd/spl-owner" 2>/dev/null | cut -f1
}
# sent_names ID WT: a message ID itself sent names WT exactly: no path
# character on either side (/var/tmp/x and /tmp/x-old are not /tmp/x)
sent_names() {
  local re d dirs=()
  re="(^|[^A-Za-z0-9._/-])$(printf '%s' "$2" | sed 's/[.[\*^$()+?{}|]/\\&/g')([^A-Za-z0-9._/-]|\$)"
  for d in "$spool/$1/outbox" "$spool/$1"@*/outbox "$spool/.retired/$1".*/outbox; do
    [ -d "$d" ] && dirs+=("$d")
  done
  [ "${#dirs[@]}" -gt 0 ] && as_root grep -rqE -- "$re" "${dirs[@]}" 2>/dev/null
}
retired_id() {
  awk -F'\t' -v id="$1" '{ k = $1; sub(/^.*: /, "", k); sub(/@.*/, "", k) } k == id { f = 1 } END { exit !f }' \
    "$spool/registry.retired.tsv" 2>/dev/null && return 0
  compgen -G "$spool/.retired/$1.*" >/dev/null
}

# The live ids (--orphans, --unproven) and, for --unproven's rounds, the live
# lanes' text (branch, brief title, window names): every source must answer,
# or nothing is removed.
declare -A live=()
add_live() { local w x; for w in "$@"; do x="$(lane_id "${w##*: }")"; [ -n "$x" ] && live["$x"]=1; done; return 0; }
lanes_txt=""
if [ "$MODE" != agent ]; then
  if [[ -n "${TMP_WT_LIVE_IDS+set}" ]]; then
    # shellcheck disable=SC2086
    add_live $TMP_WT_LIVE_IDS
    lanes_txt="${TMP_WT_LIVE_LANES:-}"
  else
    reg="$spool/registry.tsv"
    [ -r "$reg" ] || refuse "cannot read $reg: no live-lane guard"
    # shellcheck disable=SC2046
    add_live $(cut -f1 "$reg" | sed 's/@.*//')
    wins="$(tmux -S "${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(stat -c %u "$reg")/default}" list-windows -a -F '#{window_name}' 2>/dev/null)" \
      || refuse "cannot list the box's tmux windows: no live-lane guard"
    # shellcheck disable=SC2046
    add_live $(tr -c 'A-Za-z0-9-\n' ' ' <<<"$wins")
    lm="$(timeout 120 bash "${TMP_WT_LANE_MAP:-$_here/lane-map.sh}" list --all --json 2>/dev/null)" || refuse "the fleet lane map did not answer: other boxes unread"
    # line 1: the live ids; then one line per live lane: its branch and title
    lmo="$(python3 -c '
import json, sys
d = json.loads(sys.stdin.read())
if d.get("hub") != "ok": sys.exit(3)
lanes = [l for l in d.get("lanes") or [] if l.get("state") == "live"]
out = [l.get("agent_id", "") for l in lanes]
for b in d.get("load") or []: out += (b.get("busy_ids") or []) + (b.get("seat_ids") or [])
print(" ".join(out))
for l in lanes: print(" ".join(str(l.get(k) or "") for k in ("branch", "scope")).replace("\n", " "))' <<<"$lm")" || refuse "the hub did not answer the lane map: other boxes unread"
    # shellcheck disable=SC2046
    add_live $(head -1 <<<"$lmo")
    lanes_txt="$(tail -n +2 <<<"$lmo")"$'\n'"$wins"
  fi
fi

# Every path a process holds (cwd, open fds), and every mount point.
[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: cannot read every process's cwd and fds"
held="$(as_root find /proc -mindepth 2 -maxdepth 3 \( -path '/proc/[0-9]*/cwd' -o -path '/proc/[0-9]*/fd/*' \) -printf '%l\n' 2>/dev/null | grep "^$root/" | sort -u)"
mounts="$(findmnt -rn -o TARGET 2>/dev/null | grep "^$root/")"

# --unproven (SPL-6431): the trees with no proof, see the header.
# id_of NAME: the id a <prefix><id>-* name starts with (g164-r7 -> g-164)
id_of() { [[ "${1,,}" =~ ^([acgmoqu])-?([0-9]{3})- ]] && printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; }
# round_of NAME: the round an r<N>-* / rc<N>-* name carries (r086-x -> 86)
round_of() { [[ "${1,,}" =~ ^rc?([0-9]+)(-|$) ]] && printf '%d' "$((10#${BASH_REMATCH[1]}))"; }
# round_live N: a live lane's branch or title, or a window name, names round N
round_live() { grep -Eiq "(^|[^a-z0-9])(round|rc|r|b)[-_ ]?0*$1([^0-9]|\$)" <<<"$lanes_txt"; }
# git_as DIR ARGS...: git as DIR's owner (a seat's clone is its own user's)
git_as() {
  local u; u="$(stat -c %U -- "$1")"; shift
  if [[ "$u" == "$(id -un)" ]]; then GIT_TERMINAL_PROMPT=0 timeout 120 git -c safe.directory='*' "$@"
  else timeout 120 sudo -n -u "$u" env GIT_TERMINAL_PROMPT=0 git -c safe.directory='*' "$@"; fi
}
# first_unpushed TIP...: the first commit reachable from the tips that no
# origin ref of the main checkout holds (a tip it lacks counts), or nothing;
# one rev-list walk (for-each-ref --contains took ~60 s a tree on a box)
first_unpushed() {
  local t
  [ "$#" -gt 0 ] || return 0
  for t in "$@"; do g -C "$repo" cat-file -e "$t^{commit}" 2>/dev/null || { echo "$t"; return; }; done
  g -C "$repo" rev-list --max-count=1 "$@" --not --remotes=origin 2>/dev/null || echo "$1"
}
# clone_tips R: every commit a clone R holds outside its remote refs: HEAD,
# branches, tags (peeled), the stash, each worktree's detached HEAD
clone_tips() {
  local h
  git_as "$1" -C "$1" rev-parse -q --verify HEAD
  git_as "$1" -C "$1" for-each-ref --format='%(if)%(*objectname)%(then)%(*objectname)%(else)%(objectname)%(end)' \
    refs/heads refs/tags refs/stash || return 1
  for h in "$1"/.git/worktrees/*/HEAD; do
    [ -f "$h" ] && as_root sed -n '/^[0-9a-f]\{40,\}$/p' "$h"
  done
  return 0
}
# repo_why TREE R: why repo / worktree R (the dir of a .git) in TREE is
# kept, or nothing; sets dirty=1 for a dirty red / parent copy
repo_why() {
  local t r="$2" rel="${2#"$root"/}" tips st w
  if [ -f "$r/.git" ]; then
    tips="$(git_as "$r" -C "$r" rev-parse -q --verify HEAD 2>/dev/null)" || { echo "git-failed $rel"; return; }
    w="$(git_as "$r" -C "$r" rev-parse --absolute-git-dir 2>/dev/null)"
    as_root test -f "$w/locked" && { echo "locked $rel"; return; }
  else
    tips="$(clone_tips "$r" 2>/dev/null)" || { echo "git-failed $rel"; return; }
    for w in "$r"/.git/worktrees/*/gitdir; do
      [ -f "$w" ] || continue
      w="$(as_root cat "$w")"; w="${w%/.git}"
      [[ "$w" == "$1"/* ]] || { echo "worktree-outside $w (of $rel)"; return; }
    done
  fi
  # shellcheck disable=SC2046
  t="$(first_unpushed $(sort -u <<<"$tips"))"
  [ -n "$t" ] && { echo "unpushed ${t:0:9} in $rel (on no origin ref)"; return; }
  st="$(git_as "$r" --no-optional-locks -C "$r" status --porcelain 2>/dev/null)" || { echo "git-status-failed $rel"; return; }
  [ -z "$st" ] && return
  [[ "${rel,,}" =~ (^|[-_./])(red|parent)([-_./]|$) ]] || { echo "dirty $rel (not a red-control or parent copy)"; return; }
  echo dirty-red
}
# rm_tree P FORCE(0|1): each linked worktree in P by `git worktree remove`
# from its own repo, then what is left of P, as its owner; 0 when P is gone
rm_tree() {
  local p="$1" g1 r cd u force=()
  [ "$2" = 1 ] && force=(--force)
  [[ "${p%/*}" == "$root" && ! -L "$p" && -d "$p" ]] || return 1
  while IFS= read -r g1; do
    [ -f "$g1" ] || continue
    r="${g1%/.git}"
    cd="$(git_as "$r" -C "$r" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    git_as "$cd" --git-dir="$cd" worktree remove "${force[@]}" "$r" >/dev/null 2>&1 || return 1
  done <<<"$gits"
  [ -e "$p" ] || return 0
  [ -z "$(as_root find "$p" -name .git -type f -print -quit 2>/dev/null)" ] || return 1
  u="$(stat -c %U -- "$p")"
  if [ "$u" = "$(id -un)" ]; then { chmod -R u+w -- "$p"; rm -rf --one-file-system -- "$p"; } 2>/dev/null
  else { sudo -n -u "$u" chmod -R u+w -- "$p"; sudo -n -u "$u" rm -rf --one-file-system -- "$p"; } 2>/dev/null; fi
  [ ! -e "$p" ]
}
# unproven_why P CLS KEY: why tree P is kept, `dirty-red` when it goes by
# --force (a dirty red / parent copy), or nothing; reads $gits and $bares
unproven_why() {
  local p="$1" u mk w g1 young d=0
  u="$(stat -c %U -- "$p")" mk="$(marker_of "$p")"
  if [[ " $users " != *" $u "* ]]; then echo "owner-$u"
  elif [ "$2" = agent-id ] && [ -n "${live[$3]:-}" ]; then echo "live-id $3"
  elif [ -n "$mk" ] && [ -n "${live[$mk]:-}" ]; then echo "live-id $mk (its spl-owner marker)"
  elif [ "$2" = round ] && round_live "$3"; then echo "live-round $3 (a live lane or window names it)"
  elif grep -qxF -e "$p" <<<"$mounts" || grep -qF -e "$p/" <<<"$mounts"; then echo mounted
  elif grep -qxF -e "$p" <<<"$held" || grep -qF -e "$p/" <<<"$held"; then echo "in-use (a process has its cwd or an open file under it)"
  else
    # a .git or .git/worktrees DIR's own mtime is left out: removing a
    # worktree of a clone touches them, and every file in them still counts
    young="$(as_root find "$p" \( -newermt "$idle_since" -o -newerct "$idle_since" \) ! \( -type d \( -name .git -o -path '*/.git/worktrees' \) \) -print -quit 2>/dev/null)" \
      || { echo unreadable; return; }
    [ -n "$young" ] && { echo "recent (changed in the last ${idle_h} h)"; return; }
    [ -n "$bares" ] && { echo "bare-repo ${bares%%$'\n'*} (never removed)"; return; }
    while IFS= read -r g1; do
      [ -n "$g1" ] || continue
      w="$(repo_why "$p" "${g1%/.git}")"
      case "$w" in '') ;; dirty-red) d=1 ;; *) echo "$w"; return ;; esac
    done <<<"$gits"
    [ "$d" = 1 ] && echo dirty-red
  fi
  return 0
}
# unproven_one P: one KEEP or PLAN|DO line for top dir P, if it is of a class
unproven_one() {
  local p="$1" name="${1##*/}" cls key why n kb dirty=0 what scan b
  if key="$(id_of "$name")"; then cls=agent-id
  elif key="$(round_of "$name")"; then cls=round
  else return 0; fi
  # one walk: each .git (pruned), and each objects/ dir outside them whose
  # parent has a HEAD file and a refs/ dir: a bare repo
  scan="$(as_root find "$p" -name .git -prune -printf 'G %p\n' -o -type d -name objects -printf 'O %h\n' 2>/dev/null)" || scan="?"
  gits="$(sed -n 's/^G //p' <<<"$scan")" bares=""
  while IFS= read -r b; do
    as_root test -f "$b/HEAD" && as_root test -d "$b/refs" && bares+="${bares:+$'\n'}${b#"$root"/}"
  done < <(sed -n 's/^O //p' <<<"$scan")
  [ "$scan" = "?" ] && gits="?"
  [ "$cls" = agent-id ] && [ -z "$gits" ] && [ -z "$bares" ] && return 0
  n="$(as_root find "$p" -printf x 2>/dev/null | wc -c)"
  if [ "$gits" = "?" ]; then why=unreadable
  else why="$(unproven_why "$p" "$cls" "$key")"; fi
  [ "$why" = dirty-red ] && dirty=1 why=""
  what="class=$cls $([ "$cls" = round ] && echo round || echo id)=$key inodes=$n $p"
  if [ -n "$why" ]; then
    say "KEEP $why $what"; ucnt["$cls.keep"]=$(( ${ucnt["$cls.keep"]:-0} + 1 )); ucnt["$cls.keep_i"]=$(( ${ucnt["$cls.keep_i"]:-0} + n ))
    return 0
  fi
  kb="$(as_root du -sk -- "$p" 2>/dev/null | cut -f1)"
  if [ "$APPLY" = 1 ] && ! rm_tree "$p" "$dirty"; then
    say "KEEP remove-failed (git or rm left it) $what"; ucnt["$cls.keep"]=$(( ${ucnt["$cls.keep"]:-0} + 1 )); return 0
  fi
  say "$VERB remove ${kb:-0}KB$([ "$dirty" = 1 ] && echo ' dirty red-copy --force') $what"
  ucnt["$cls.rm"]=$(( ${ucnt["$cls.rm"]:-0} + 1 )); ucnt["$cls.rm_i"]=$(( ${ucnt["$cls.rm_i"]:-0} + n ))
}
# unproven_sweep: every top dir, linked worktrees first (a clone in /tmp
# keeps while a worktree of it is there), then a DONE line per class
unproven_sweep() {
  local p list c
  SPOOL_ROOT="$spool" _spool_box_env_load
  users="$repo_user ${SPOOL_AGENT_USER:-}"
  declare -gA ucnt=()
  list="$(find "$root" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print 2>/dev/null | LC_ALL=C sort)"
  say "START mode=unproven repo=$repo root=$root apply=$APPLY live_ids=${#live[@]} idle_h=$idle_h users=$users"
  while IFS= read -r p; do [ -n "$p" ] && [ -f "$p/.git" ] && unproven_one "$p"; done <<<"$list"
  while IFS= read -r p; do [ -n "$p" ] && [ ! -f "$p/.git" ] && unproven_one "$p"; done <<<"$list"
  for c in agent-id round; do
    say "DONE class=$c $([ "$APPLY" = 1 ] && echo removed || echo would-remove)=${ucnt[$c.rm]:-0} inodes=${ucnt[$c.rm_i]:-0} kept=${ucnt[$c.keep]:-0} kept_inodes=${ucnt[$c.keep_i]:-0}"
  done
  return 0
}
[ "$MODE" = unproven ] && { unproven_sweep; exit $?; }

# The linked worktrees directly under the root: "path<TAB>locked(0|1)"
wts="$(g -C "$repo" worktree list --porcelain 2>/dev/null | awk '
  /^worktree / { if (p != "") print p "\t" l; p = substr($0, 10); l = 0 }
  /^locked/ { l = 1 }
  END { if (p != "") print p "\t" l }' | awk -F'\t' -v r="$root/" 'index($1, r) == 1')" \
  || refuse "git worktree list failed in $repo"

say "START mode=$MODE${ID:+ agent=$ID} repo=$repo root=$root apply=$APPLY live_ids=${#live[@]} idle_h=$idle_h"
n_rm=0 kb_rm=0 n_keep=0
keep() { say "KEEP $1 $2"; n_keep=$((n_keep + 1)); }
while IFS=$'\t' read -r wt locked; do
  [ -n "$wt" ] || continue
  name="${wt##*/}"
  [[ "${wt%/*}" == "$root" && ! -L "$wt" && -d "$wt" ]] || continue
  mk="$(marker_of "$wt")" nid="$(lane_id "$name")"
  if [ "$MODE" = agent ]; then who="$ID"
  else who="${mk:-$nid}"; fi
  [ -n "$who" ] || continue
  if [ -n "$mk" ] && [ "$mk" != "$who" ]; then
    [ "$nid" = "$who" ] && keep "marker-other ($mk)" "$wt"
    continue
  fi
  if [ "$mk" = "$who" ]; then proof=marker
  elif [ "$nid" != "$who" ]; then continue
  elif sent_names "$who" "$wt"; then proof=outbox
  else keep "name-only (no spl-owner marker, no message of $who names it)" "$wt"; continue
  fi
  if [ "$MODE" = orphans ]; then
    if ! retired_id "$who"; then keep "not-retired $who" "$wt"; continue; fi
    if [ -n "${live[$who]:-}" ]; then keep "live-id $who" "$wt"; continue; fi
  fi
  if [ "$locked" = 1 ]; then keep locked "$wt"; continue; fi
  if grep -qxF -e "$wt" <<<"$mounts" || grep -qF -e "$wt/" <<<"$mounts"; then keep mounted "$wt"; continue; fi
  if grep -qxF -e "$wt" <<<"$held" || grep -qF -e "$wt/" <<<"$held"; then keep "in-use (a process has its cwd or an open file under it)" "$wt"; continue; fi
  if [ "$(stat -c %U -- "$wt" 2>/dev/null)" != "$repo_user" ]; then keep "owner-not-$repo_user" "$wt"; continue; fi
  if [ "$MODE" = orphans ]; then
    young="$(as_root find "$wt" -newermt "-${idle_h} hours" -print -quit 2>/dev/null)"; frc=$?
    if [ -n "$young" ]; then keep "recent (changed in the last ${idle_h} h)" "$wt"; continue; fi
    if [ "$frc" != 0 ]; then keep unreadable "$wt"; continue; fi
  fi
  st="$(g -C "$wt" status --porcelain 2>/dev/null)" || { keep "git-status-failed" "$wt"; continue; }
  force=()
  if [ -n "$st" ]; then
    if [[ "${name,,}" =~ (^|[-_.])(red|parent)([-_.]|$) ]]; then force=(--force)
    else keep "dirty (not a red-control or parent copy: never forced)" "$wt"; continue; fi
  fi
  kb="$(as_root du -sk -- "$wt" 2>/dev/null | cut -f1)"; kb="${kb:-0}"
  what="remove ${kb}KB proof=$proof${force:+ dirty red-copy --force} $wt"
  if [ "$APPLY" = 1 ]; then
    g -C "$repo" worktree remove "${force[@]}" "$wt" 2>/dev/null || { keep "git-refused" "$wt"; continue; }
  fi
  say "$VERB $what"
  n_rm=$((n_rm + 1)); kb_rm=$((kb_rm + kb))
done <<<"$wts"
say "DONE $([ "$APPLY" = 1 ] && echo removed || echo would-remove)=$n_rm ($((kb_rm / 1024)) MB) kept=$n_keep"
