#!/usr/bin/env bash
# reap-profiles.sh — remove the leaked per-agent Firefox profile clones that
# mcp-start.sh leaves behind, and nothing else.
#
# WHAT LEAKS, AND WHY THE EPHEMERAL CLEANUP PATH IS NOT THE CAUSE
#
# mcp-start.sh clones $MCP_BOT_HOME/ff-profile → ff-profile-<AGENT-ID> on first
# use, per agent. Clones for an agent id with NO id (no MCP_BOT_AGENT_ID, no
# resolvable ancestry) are named ff-profile-pid<PID> and removed by that
# server's EXIT trap. That <PID> is the owning server's, so the name doubles as
# a liveness signal and is treated as one — see the ff-profile-pid case below,
# and note that for such a clone the argv and lock signals can BOTH be silent
# while the server is alive. Clones for a NAMED id are kept on purpose: that agent's
# cookies and logins survive between runs. Nothing ever deletes them when the
# id is retired, and agent ids are minted one per spawn.
#
# Measured on this box 2026-09-10, as the desktop user:
#
#     ls -d ~/.local/mcp-bot/ff-profile-*    | wc -l   ->  468
#     ls -d ~/.local/mcp-bot/ff-profile-pid* | wc -l   ->    0
#     du -sh ~/.local/mcp-bot                         ->   82G
#     du -sh ~/.local/mcp-bot/ff-profile               ->  471M
#
# ff-profile-pid* reading 0 is the evidence that the ephemeral path works. The
# 82G is 468 kept clones at ~167M each, oldest born 2026-08-19. So this script
# reaps RETIRED ids; it is not a fix for a broken trap.
#
# It is also not a fix for the `firefox` MCP CONNECTION_CLOSED failures. "The
# clone is too slow" was measured and rejected 2026-09-09 (clone ~1s, / has
# 264G free). Disk pressure is not the motivation; 82G of dead weight is.
#
# ── TRAP 1: ff-profile (no suffix) IS THE MASTER ────────────────────────────
#
# 471M, and it carries the extensions, prefs, cookies and logins every clone is
# made from. Deleting it breaks the browser MCP for every agent, and no clone
# is a substitute. `rm -rf ff-profile-*` does not match it; `rm -rf ff-profile*`
# does, and that one character is the whole defect. This script therefore
# guards the master by PATH EQUALITY (realpath, after symlink resolution) and
# asserts it again immediately before each removal — never by trusting a glob.
# It also refuses to delete anything at all when the master is missing, because
# at that point the clones are the only copies of those logins.
#
# ── TRAP 2: mtime INSIDE a clone is the MASTER's mtime, not the clone's ─────
#
# The clone is made with `rsync -a`, which preserves timestamps. So every file
# copied in carries the master's mtime, identically across all 468 clones.
# Measured 2026-09-10:
#
#     stat -c %Y ~/.local/mcp-bot/ff-profile                     -> 1786787016
#     find ~/.local/mcp-bot/ff-profile-CLE-01   -printf '%T@\n' | sort -rn | head -1
#                                                                -> 1786789647
#     find ~/.local/mcp-bot/ff-profile-ORC-hsk  -printf '%T@\n' | sort -rn | head -1
#                                                                -> 1786789647
#
# Two clones born 14 days apart, byte-identical newest mtime, both 2026-08-15 —
# the master's. A reaper that asks "when was this tree last modified?" therefore
# gets the master's provisioning date for every clone and either reaps all of
# them or none. `find -newermt` over the tree is the wrong check here.
#
# The signals that DO move with use, all four taken and the NEWEST one used:
#
#   1. the clone directory's BIRTH time (`stat %W`; ext4 carries it) — when the
#      clone was made. A never-used clone is aged from this, which is the
#      conservative direction.
#
#      NOT EVERY FILESYSTEM HAS ONE. On WSL1 (lxfs and drvfs) `stat %W` prints
#      0. Measured on a WSL1 box 2026-09-17: `touch -t 202001010000` on a fresh
#      mktemp -d read %W=0, %Y=1577829600, %Z=now — and with BIRTH silently 0
#      the rsync-copied tree mtimes decided, and a clone made minutes earlier
#      was REMOVED. So with no birth time the clone dir's CTIME (%Z) stands in:
#      rsync cannot copy a ctime and `touch` cannot set one, and it only ever
#      moves forward, so it can make a clone look younger, never older. When
#      neither clock reads (both 0 or stat failed) the clone is SKIPPED as
#      `no-birth-time`. An unknown age is never treated as an old one. The
#      source used is named on every verdict, e.g. "clone ctime (%Z, no birth
#      time)".
#   2. the clone directory's own mtime — bumped when an entry is created or
#      removed directly in it, which a Firefox start does (lock/.parentlock).
#   3. the newest mtime among the clone's DIRECT CHILDREN. The things rsync
#      excludes — lock, .parentlock, cache2/, startupCache/, sessionstore*,
#      *.sqlite-wal — can only exist because a browser really ran here, so
#      their mtimes are real. They all live at the top level.
#   4. $MCP_BOT_HOME/run/<ID>.marionette-port and run/mcp-config-<ID>.json,
#      which mcp-start.sh REWRITES on every launch for that id. This is the
#      most informative of the four: it dates the last MCP server start even
#      when the browser never got far enough to touch the profile.
#
# ── TRAP 3: never delete a profile a live browser holds ────────────────────
#
# Two independent signals, both consulted:
#
#   a. the process table. One pass over /proc/<pid>/cmdline; any live process
#      whose argv mentions the clone path makes that clone live. This is the
#      same test mcp-start.sh §3 applies to the lock owner
#      (`grep -qF -- "$PROFILE"`), widened to every process and every argv
#      position, because the point here is to be broad: the cost of a false
#      "live" is a profile kept one more day, and the cost of a false "dead" is
#      167M of someone's session deleted mid-run.
#
#      Being that broad has a consequence worth knowing, met while verifying
#      this script on 2026-09-10: a `grep ff-profile-CLE-422` — or any shell
#      whose -c script text merely MENTIONS a clone — is a live process whose
#      argv contains the path, and the clone is kept for as long as it runs.
#      That is the safe direction and it stays, but the report distinguishes the
#      two shapes so the evidence is readable:
#
#        argv-path  a token that IS the clone path, or a path inside it. This is
#                   what a browser looks like: the real mcp-bot Firefox runs
#                   `firefox … -profile /…/ff-profile-<ID>`, its own token.
#        argv-text  the path appears inside a LARGER token — a shell script
#                   body, a command line being echoed. Almost certainly not a
#                   browser, still kept.
#   b. Firefox's own lock. `lock` is a symlink whose target encodes the owning
#      pid ("<ip>:+<pid>"), parsed with the SAME expression mcp-start.sh uses,
#      and the pid is then checked in /proc.
#
# Where this script deliberately DIVERGES from mcp-start.sh: mcp-start treats a
# lock whose pid is alive but whose cmdline does not mention the profile as
# STALE and deletes the lock file. That is right for mcp-start — pid numbers
# are reused, and the cost of being wrong there is a failed launch. It is wrong
# for a reaper, where the cost of being wrong is unrecoverable. So a lock pid
# that is alive at all makes the clone un-reapable; the report distinguishes
# `live` (argv confirms it) from `held` (pid alive, argv does not confirm).
#
# `.parentlock` carries no pid, so on its own it is not evidence of liveness —
# it is reported as proof the clone was really used, and nothing more.
#
# ── TRAP 4: a missing tmux window does NOT mean the id is retired ──────────
#
# Ids get reused and sessions get restored, so "no window named CLE-32 right
# now" is not a reap signal and this script never consults tmux. Nor does it
# consult the agent registry: /var/tmp/claude/msgs/registry.tsv is append-only
# history, measured 2026-09-10 at 400 lines over 329 distinct ids, so treating
# it as a keep-list would protect 329 of the 468 clones — including every
# retired id — and turn the reaper into a near no-op. Age plus liveness is the
# test; `--keep` is the escape hatch for an id you know better about.
#
# ── NOT HANDLED: cr-profile-* ──────────────────────────────────────────────
#
# The Chrome MCP (mcp-start-chrome.sh) keeps its own cr-profile-* dirs and
# reaps its own stale ones. This script never looks at them, by design. If they
# ever need reaping, that belongs in the chrome entrypoint, next to the code
# that knows when a Chrome profile is finished with.
#
# ── REMOVAL IS RENAME-THEN-DELETE ──────────────────────────────────────────
#
# mcp-start.sh decides to clone with `[ ! -d "$PROFILE" ]`. A plain `rm -rf` on
# a 167M tree is not instantaneous, so for the duration of it that test says
# "the profile exists" while the profile is being gutted, and a concurrent agent
# launches Firefox on a half-deleted profile. Renaming first (an atomic
# rename(2) within one directory) closes that window: the next mcp-start sees
# no directory and makes a fresh clone. Leftover ff-profile-*.reap-<pid> dirs
# from a killed reaper — and ff-profile-*.tmp-<pid> dirs from an interrupted
# clone — are themselves reaped regardless of age once their pid is gone, since
# both are by definition partial and doomed.
#
# USAGE
#
#     reap-profiles.sh [OPTIONS]
#
#     --dry-run, -n      report what would be removed, remove nothing (DEFAULT)
#     --delete, -y       actually remove
#     --days N           keep any clone with activity in the last N days
#                        (default 14)
#     --all-ages         ignore the age threshold entirely; liveness and --keep
#                        still apply
#     --keep ID          never touch this clone; repeatable. Takes an agent id
#                        (CLE-07), a basename (ff-profile-CLE-07) or a full path
#     --limit N          remove at most N clones, oldest activity first. Use it
#                        to prove a real run on a handful before committing to
#                        the whole set
#     --home DIR         MCP_BOT_HOME (default $MCP_BOT_HOME, else ~/.local/mcp-bot)
#     --quiet-skips      do not list the kept clones, only count them
#     -h, --help         this text
#
# IDEMPOTENT and cron-safe: it derives everything from the filesystem and
# /proc, holds no state, and a second --delete over the same home removes
# nothing. No cron entry is installed by this script or by the feature — that
# is the operator's call.
#
# EXIT CODES
#     0  nothing to reap, or --delete removed everything it listed
#     1  --dry-run found clones to reap (so it is usable as a gate)
#     2  bad usage, missing prerequisite, or a removal failed
set -uo pipefail

MODE=dry-run
DAYS=14
ALL_AGES=0
LIMIT=0
QUIET_SKIPS=0
HOME_DIR="${MCP_BOT_HOME:-$HOME/.local/mcp-bot}"
declare -a KEEP_ARGS=()

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run|-n)  MODE=dry-run ;;
    --delete|-y)   MODE=delete ;;
    --days)        DAYS="${2:?--days needs a number}"; shift ;;
    --all-ages)    ALL_AGES=1 ;;
    --keep)        KEEP_ARGS+=("${2:?--keep needs an id}"); shift ;;
    --limit)       LIMIT="${2:?--limit needs a number}"; shift ;;
    --home)        HOME_DIR="${2:?--home needs a directory}"; shift ;;
    --quiet-skips) QUIET_SKIPS=1 ;;
    -h|--help)     usage; exit 0 ;;
    *)             echo "reap-profiles: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

say()  { printf 'mcp-bot reap: %s\n' "$*"; }
warn() { printf 'mcp-bot reap: %s\n' "$*" >&2; }

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { warn "bash 4+ required (associative arrays)"; exit 2; }
for b in find stat du sort awk mv rm readlink sed; do
  command -v "$b" >/dev/null 2>&1 || { warn "missing required binary: $b"; exit 2; }
done
case "$DAYS"  in ''|*[!0-9]*) warn "--days must be a non-negative integer: $DAYS";   exit 2 ;; esac
case "$LIMIT" in ''|*[!0-9]*) warn "--limit must be a non-negative integer: $LIMIT"; exit 2 ;; esac
[ -d "$HOME_DIR" ] || { warn "no such MCP_BOT_HOME: $HOME_DIR"; exit 2; }

HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
MASTER="$HOME_DIR/ff-profile"
RUN_DIR="$HOME_DIR/run"
PREFIX="$HOME_DIR/ff-profile-"
NOW="$(date -u +%s)"
CUTOFF=$(( NOW - DAYS * 86400 ))

# realpath of the master, for the path-equality guard. Empty when it is missing,
# and a missing master is a hard stop for --delete (see TRAP 1).
MASTER_REAL=""
if [ -d "$MASTER" ]; then MASTER_REAL="$(cd "$MASTER" && pwd -P)"; fi

iso()   { [ "${1:-0}" -gt 0 ] 2>/dev/null && date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ || printf 'unknown'; }
human() {  # bytes -> human, without depending on numfmt
  awk -v b="${1:-0}" 'BEGIN{ s="B KiB MiB GiB TiB"; n=split(s,u," "); i=1
    while (b >= 1024 && i < n) { b /= 1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

# ── keep list, normalised to basenames ─────────────────────────────────────
declare -A KEEP=()
for k in ${KEEP_ARGS+"${KEEP_ARGS[@]}"}; do
  k="${k%/}"; k="${k##*/}"                       # a full path -> its basename
  case "$k" in ff-profile-*) ;; *) k="ff-profile-$k" ;; esac
  KEEP["$k"]=1
done

# ── signal A: clones named in the argv of a LIVE process ───────────────────
# One pass over /proc, no exec per pid. A process one of whose argv tokens has
# THIS script's basename is the reaper itself (or the shell that launched it):
# its argv carries clone paths legitimately and must not be mistaken for a
# browser holding them.
declare -A LIVE_PID=() LIVE_KIND=()
SELF_NAME="${0##*/}"
scan_live_argv() {
  local d pid tok rest b isself
  local -a toks
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] && continue
    [ -r "$d/cmdline" ] || continue
    toks=()
    while IFS= read -r -d '' tok; do toks+=("$tok"); done < "$d/cmdline" 2>/dev/null
    [ "${#toks[@]}" -gt 0 ] || continue
    isself=0
    for tok in "${toks[@]}"; do
      # basename equality, not substring: a substring test also swallows
      # test-reap-profiles.sh, which is exactly the process a regression suite
      # uses to hold a profile, and excluding it would make the live-profile
      # check untestable.
      [ "${tok##*/}" = "$SELF_NAME" ] && { isself=1; break; }
    done
    [ "$isself" = 1 ] && continue
    for tok in "${toks[@]}"; do
      case "$tok" in
        *"$PREFIX"*)
          rest="${tok#*"$PREFIX"}"      # everything after ".../ff-profile-"
          rest="${rest%%/*}"            # stop at a path separator
          # ...and at the first character an agent id cannot contain. mcp-start.sh
          # sanitises the id with `tr -c 'A-Za-z0-9._-'`, so anything outside that
          # set ends the name. Without this the token
          #   "…/ff-profile-CLE-42 here"   (a shell -c body mentioning the path)
          # yields the key "ff-profile-CLE-42 here", which matches no clone — so
          # the mention is counted as a hold and then protects nothing.
          rest="${rest%%[!A-Za-z0-9._-]*}"
          b="ff-profile-$rest"
          # a token that IS the path (optionally behind a --flag=) is what a
          # browser looks like; anything else merely mentions it
          case "${tok#*=}" in "$PREFIX"*) kind=argv-path ;; *) kind=argv-text ;; esac
          if [ -z "${LIVE_PID[$b]:-}" ] || { [ "$kind" = argv-path ] && [ "${LIVE_KIND[$b]}" = argv-text ]; }; then
            LIVE_PID["$b"]="$pid"; LIVE_KIND["$b"]="$kind"
          fi
          ;;
      esac
    done
  done
}
scan_live_argv
# Drop entries whose pid has already exited, so the reported count means what it
# says. Classification is pid-gated anyway; this keeps the header from showing a
# holder the skip list does not.
for b in "${!LIVE_PID[@]}"; do
  [ -d "/proc/${LIVE_PID[$b]}" ] || { unset 'LIVE_PID[$b]'; unset 'LIVE_KIND[$b]'; }
done

# ── signal B: Firefox's own lock, parsed exactly as mcp-start.sh §3 does ───
declare -A LOCK_PID=() PARENTLOCK=()
while IFS='|' read -r rel target; do
  [ -n "$rel" ] || continue
  b="${rel%%/*}"
  pid="$(printf '%s\n' "$target" | sed -n 's/.*:+\([0-9]\+\)$/\1/p')"
  [ -n "$pid" ] && LOCK_PID["$b"]="$pid"
done < <(find "$HOME_DIR" -mindepth 2 -maxdepth 2 -name lock -type l -printf '%P|%l\n' 2>/dev/null)
while IFS= read -r rel; do
  [ -n "$rel" ] && PARENTLOCK["${rel%%/*}"]=1
done < <(find "$HOME_DIR" -mindepth 2 -maxdepth 2 -name .parentlock -printf '%P\n' 2>/dev/null)

# ── activity timestamps (TRAP 2): four batched passes, no per-clone exec ───
declare -A MTIME=() BIRTH=() BIRTH_SRC=() RUNMT=()
while IFS='|' read -r ts b; do [ -n "$b" ] && MTIME["$b"]="$ts"; done < <(
  find "$HOME_DIR" -mindepth 1 -maxdepth 2 -path "$PREFIX*" -printf '%T@|%P\n' 2>/dev/null \
  | awk -F'|' '{ split($2,p,"/"); k=p[1]; t=$1+0; if (t>m[k]) m[k]=t }
               END { for (k in m) printf "%d|%s\n", m[k], k }')
# birth time, else ctime (see signal 1): a clone with neither gets no BIRTH
# entry at all, and the classifier skips it rather than aging it from nothing.
while IFS='|' read -r bt ct b; do
  [ -n "$b" ] || continue
  if   [ "$bt" -gt 0 ]; then BIRTH["$b"]="$bt"; BIRTH_SRC["$b"]="clone born (%W)"
  elif [ "$ct" -gt 0 ]; then BIRTH["$b"]="$ct"; BIRTH_SRC["$b"]="clone ctime (%Z, no birth time)"
  fi
done < <(
  find "$HOME_DIR" -mindepth 1 -maxdepth 1 -name 'ff-profile-*' -printf '%p\0' 2>/dev/null \
  | xargs -0 -r stat -c '%W|%Z|%n' 2>/dev/null \
  | awk -F'|' '{ n=$3; sub(/.*\//,"",n); printf "%d|%d|%s\n", $1+0, $2+0, n }')
while IFS='|' read -r ts f; do [ -n "$f" ] && RUNMT["$f"]="$ts"; done < <(
  find "$RUN_DIR" -maxdepth 1 -type f -printf '%T@|%f\n' 2>/dev/null \
  | awk -F'|' '{ printf "%d|%s\n", $1+0, $2 }')

# last activity = newest of the four signals; also reports WHICH one spoke, so
# a verdict can be audited without re-deriving it.
LAST=0; LAST_WHY=""
last_activity() {  # $1 = clone basename
  local b="$1" id="${1#ff-profile-}" t
  LAST=0; LAST_WHY="none"
  t="${BIRTH[$b]:-0}";                     [ "$t" -gt "$LAST" ] && { LAST="$t"; LAST_WHY="${BIRTH_SRC[$b]}"; }
  t="${MTIME[$b]:-0}";                     [ "$t" -gt "$LAST" ] && { LAST="$t"; LAST_WHY="profile contents"; }
  t="${RUNMT[mcp-config-$id.json]:-0}";    [ "$t" -gt "$LAST" ] && { LAST="$t"; LAST_WHY="run/mcp-config-$id.json"; }
  t="${RUNMT[$id.marionette-port]:-0}";    [ "$t" -gt "$LAST" ] && { LAST="$t"; LAST_WHY="run/$id.marionette-port"; }
  return 0
}

# ── classify ───────────────────────────────────────────────────────────────
declare -a REAP=() REAP_TS=() SKIPS=()
declare -A KEPT_COUNT=()
note_skip() {  # $1=reason-tag $2=basename $3=detail
  KEPT_COUNT["$1"]=$(( ${KEPT_COUNT[$1]:-0} + 1 ))
  SKIPS+=("$(printf '  SKIP  %-10s %-34s %s' "$1" "$2" "$3")")
}
pid_alive() { [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

TOTAL=0
shopt -s nullglob
for d in "$HOME_DIR"/ff-profile-*; do
  b="${d##*/}"
  TOTAL=$(( TOTAL + 1 ))

  # TRAP 1, first line: a symlink or a plain file is never reaped. A symlink
  # pointing at the master is exactly how a glob-safe name ends up naming it.
  if [ -L "$d" ]; then note_skip symlink "$b" "symlink -> $(readlink "$d"); not a clone"; continue; fi
  if [ ! -d "$d" ]; then note_skip notdir "$b" "not a directory"; continue; fi

  # TRAP 1, second line: path equality against the master, after resolution.
  real="$(cd "$d" && pwd -P)"
  if [ -n "$MASTER_REAL" ] && [ "$real" = "$MASTER_REAL" ]; then
    warn "DEFECT: $d resolves to the master profile $MASTER — refusing to continue"
    exit 2
  fi

  # partial/doomed dirs: an interrupted clone (.tmp-<pid>) or a killed reaper's
  # rename (.reap-<pid>). Reapable at any age once the pid is gone.
  case "$b" in
    *.tmp-*|*.reap-*)
      pid="${b##*-}"
      if pid_alive "$pid"; then note_skip inflight "$b" "pid $pid is alive"; continue; fi
      REAP+=("$d"); REAP_TS+=("0"); continue ;;
  esac

  # An EPHEMERAL clone carries its owner's pid IN ITS NAME: mcp-start.sh sets
  # AGENT_ID="pid$$" when it can resolve no agent id, so ff-profile-pid<N> is
  # owned by mcp-start pid <N> and that name is itself a liveness signal.
  #
  # It has to be consulted, because the other two signals can both be silent
  # while the server is perfectly alive: the playwright-mcp process names only
  # run/mcp-config-pid<N>.json in its argv, never the profile, and until a
  # client asks for a page there is no browser and therefore no lock. Measured
  # 2026-09-10 against a fixture: under --all-ages an in-flight ephemeral clone
  # was listed for removal with its server still running. Under the --days
  # default it is protected by birth time, which is why it went unnoticed.
  #
  # A clone whose pid is GONE is deliberately NOT reaped on sight here, even
  # though mcp-start's own EXIT trap would have removed it and it is therefore
  # garbage. It falls through to the normal age threshold instead: this script
  # is a deleter, and widening what it removes is a thing to do on its own,
  # not as a side effect of closing a protection gap.
  case "$b" in
    ff-profile-pid[0-9]*)
      epid="${b#ff-profile-pid}"
      case "$epid" in
        ''|*[!0-9]*) ;;
        *) if pid_alive "$epid"; then
             note_skip inflight "$b" "ephemeral clone of live mcp-start server pid $epid"; continue
           fi ;;
      esac ;;
  esac

  if [ -n "${KEEP[$b]:-}" ]; then note_skip keep "$b" "--keep"; continue; fi

  if [ -n "${LIVE_PID[$b]:-}" ] && pid_alive "${LIVE_PID[$b]}"; then
    if [ "${LIVE_KIND[$b]}" = argv-path ]; then
      note_skip live "$b" "live pid ${LIVE_PID[$b]} names it as an argv path (argv-path) — a browser holds it"
    else
      note_skip live "$b" "live pid ${LIVE_PID[$b]} mentions it inside a larger argv token (argv-text) — kept, the safe direction"
    fi
    continue
  fi
  lp="${LOCK_PID[$b]:-}"
  if pid_alive "$lp"; then
    if [ -n "${LIVE_PID[$b]:-}" ]; then note_skip live "$b" "lock held by live pid $lp (argv confirms)"
    else                                note_skip held "$b" "lock pid $lp is alive but its argv does not name this profile — treated as held, not stale"; fi
    continue
  fi

  if [ "$ALL_AGES" = 0 ] && [ -z "${BIRTH[$b]:-}" ]; then
    note_skip no-birth-time "$b" "stat reads neither a birth time (%W) nor a ctime (%Z) — age unknown, not old"; continue
  fi

  last_activity "$b"
  if [ "$ALL_AGES" = 0 ] && [ "$LAST" -ge "$CUTOFF" ]; then
    note_skip fresh "$b" "activity $(iso "$LAST") ($LAST_WHY)"; continue
  fi
  REAP+=("$d"); REAP_TS+=("$LAST")
done
shopt -u nullglob

# oldest activity first, so --limit takes the deadest clones
if [ "${#REAP[@]}" -gt 0 ]; then
  mapfile -t _sorted < <(
    for i in "${!REAP[@]}"; do printf '%s|%s\n' "${REAP_TS[$i]}" "${REAP[$i]}"; done | sort -t'|' -k1,1n)
  REAP=(); REAP_TS=()
  for line in "${_sorted[@]}"; do REAP_TS+=("${line%%|*}"); REAP+=("${line#*|}"); done
fi
if [ "$LIMIT" -gt 0 ] && [ "${#REAP[@]}" -gt "$LIMIT" ]; then
  say "--limit $LIMIT: ${#REAP[@]} clone(s) qualify, taking the $LIMIT with the oldest activity"
  REAP=("${REAP[@]:0:$LIMIT}"); REAP_TS=("${REAP_TS[@]:0:$LIMIT}")
fi

# ── report ─────────────────────────────────────────────────────────────────
say "mode=$MODE home=$HOME_DIR days=$DAYS all-ages=$ALL_AGES cutoff=$(iso "$CUTOFF")"
if [ -n "$MASTER_REAL" ]; then
  say "master is guarded by path equality, not by glob: [$MASTER] mtime $(iso "$(stat -c %Y "$MASTER" 2>/dev/null || echo 0)")"
else
  warn "master profile $MASTER is MISSING — the clones may be the only copies of those logins"
fi
cr=$(find "$HOME_DIR" -mindepth 1 -maxdepth 1 -name 'cr-profile-*' -printf . 2>/dev/null | wc -c)
say "cr-profile-* dirs: $cr — NOT handled here; the chrome MCP reaps its own"
np=0; nt=0
for b in "${!LIVE_KIND[@]}"; do
  [ "${LIVE_KIND[$b]}" = argv-path ] && np=$(( np + 1 )) || nt=$(( nt + 1 ))
done
say "clones: $TOTAL  held by a live argv-path: $np  mentioned in a live argv-text: $nt  lock symlinks: ${#LOCK_PID[@]}  .parentlock: ${#PARENTLOCK[@]}"
echo

if [ "$QUIET_SKIPS" = 0 ]; then
  for s in ${SKIPS+"${SKIPS[@]}"}; do printf '%s\n' "$s"; done
  [ "${#SKIPS[@]}" -gt 0 ] && echo
fi
kept_summary=""
for r in "${!KEPT_COUNT[@]}"; do kept_summary+="$r=${KEPT_COUNT[$r]} "; done
say "kept: ${kept_summary:-none}"

if [ "${#REAP[@]}" -eq 0 ]; then
  say "nothing to reap."
  exit 0
fi

BYTES="$(printf '%s\0' "${REAP[@]}" | xargs -0 -r du -sb -- 2>/dev/null | awk '{s+=$1} END{print s+0}')"
printf '== %s %d profile(s), %s (%s bytes) ==\n' \
  "$([ "$MODE" = delete ] && echo 'removing' || echo 'would remove')" \
  "${#REAP[@]}" "$(human "$BYTES")" "$BYTES"
# bare absolute paths, one per line: this block is the machine-readable answer,
# and `... | grep -x "$MCP_BOT_HOME/ff-profile"` over it must print nothing.
printf '%s\n' "${REAP[@]}"
echo

if [ "$MODE" != delete ]; then
  say "dry run — nothing was removed. Re-run with --delete to act."
  exit 1
fi

[ -n "$MASTER_REAL" ] || { warn "refusing to delete with the master profile missing"; exit 2; }
say "home before: $(du -sh "$HOME_DIR" 2>/dev/null | awk '{print $1}')"
rc=0; removed=0
for d in "${REAP[@]}"; do
  # the guard, re-asserted per path: nothing between the scan and here may have
  # turned this into the master, and if it somehow did, stop rather than delete.
  if [ -d "$d" ] && [ -n "$MASTER_REAL" ] && [ "$(cd "$d" && pwd -P)" = "$MASTER_REAL" ]; then
    warn "DEFECT: $d now resolves to the master — aborting"; exit 2
  fi
  [ -e "$d" ] || continue                     # vanished under us; idempotent
  tmp="$d.reap-$$"
  if mv -T -- "$d" "$tmp" 2>/dev/null; then   # atomic: no half-gutted profile
    if rm -rf --one-file-system -- "$tmp"; then removed=$(( removed + 1 ))
    else warn "rm failed: $tmp (left in place, a later run will retake it)"; rc=2; fi
  else
    warn "rename failed, not deleting in place: $d"; rc=2
  fi
done
say "removed $removed of ${#REAP[@]} profile(s)"
say "home after:  $(du -sh "$HOME_DIR" 2>/dev/null | awk '{print $1}')"
if [ -d "$MASTER" ]; then
  say "master intact: $(du -sh "$MASTER" 2>/dev/null | awk '{print $1}') $MASTER"
else
  warn "MASTER IS GONE after the run — this is a defect, report it"; rc=2
fi
exit "$rc"
