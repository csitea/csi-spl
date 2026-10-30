#!/usr/bin/env bash
# owner-order-guard.inc.sh — the owner-order gate's callers (spec 168 part c,
# build row B3, SPL-4372; owner HUM-10 poll 10af03a3 answer A): a change to a
# path an active `gate: go` or `gate: content` order covers needs the owner's
# go, an `Owner-go: <msg uuid>` trailer whose message names the order's id8.
#
# The decision is ONE action, `ORDER_CMD=gate ./run -a do_spl_owner_order`
# (csi-spl-orc/src/bash/run/spl-owner-order-gate.func.sh): which paths, the
# rename reading per gate, the hub check of the go and of every lift. This
# file only finds the commits and runs it:
#
#   oog_pre_push <top> <remote>   git's pre-push ref lines on stdin; csi-spl's
#                                 pre-push hook (sa/hooks/pre-push) calls it
#   oog_range <top> <range>       the do_check_pre_push part (owner-orders)
#   owner_order_guard_check "<command>" [<cwd>]
#                                 the harness guard, the shape of
#                                 force-push-guard.inc.sh: before an agent's
#                                 `git commit` / `git push` in a checkout whose
#                                 repository has a ledger. rc 0 allow, rc 2
#                                 refuse, the reason on stderr
#   bash owner-order-guard.inc.sh --check "<command>" [<cwd>]   the same
#
# A repository with no ledger file is never asked (no ./run, ~ms). Every
# answer of the action but 0 refuses: a broken ledger (2), a hub read that
# failed or a missing action (1) never read as "no order" (fail closed).
# Nothing here installs a hook in, or edits the .git/config of, any
# repository: the harness hook (scripts/owner-order-guard-hook.sh) is
# installed by the owner.
# Seams: OWNER_ORDER_DIR (default $SPOOL_ROOT/owner-orders), OOG_ORC_DIR (the
# csi-spl-orc dir whose ./run runs the action, default this file's tree),
# ORDER_GO_HUB (dev | prd | none, read by the action).

_oog_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

oog_ledger_dir() { printf '%s' "${OWNER_ORDER_DIR:-${SPOOL_ROOT:-/var/spool-hub}/owner-orders}"; }

# oog_repo_key <dir>: the basename of the dir that holds the git common dir
# (every worktree of a repo gives the repo's name), as the action derives it
oog_repo_key() {
  local cd
  cd="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  basename "$(dirname "$cd")"
}

# oog_has_ledger <dir>: rc 0 when the repo of <dir> has a ledger file here
oog_has_ledger() {
  local k
  k="$(oog_repo_key "$1")" || return 1
  [ -e "$(oog_ledger_dir)/$k.jsonl" ]
}

# oog_gate <repo dir> VAR=value...: the action, through ./run (the hub read
# needs its environment). Prints the gate's own lines; rc = the action's.
oog_gate() {
  local dir orc="${OOG_ORC_DIR:-$(cd "$_oog_lib_dir/../../../../.." 2>/dev/null && pwd)}" out rc
  dir="$(cd "$1" 2>/dev/null && pwd)" || { echo "owner-orders: REFUSED cannot enter $1"; return 1; }
  shift
  [ -x "$orc/run" ] || { echo "owner-orders: REFUSED the gate action is missing ($orc/run): fail closed"; return 1; }
  out="$(cd "$orc" && env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_COMMON_DIR -u GIT_PREFIX \
    ORDER_CMD=gate ORDER_REPO_DIR="$dir" OWNER_ORDER_DIR="$(oog_ledger_dir)" "$@" ./run -a do_spl_owner_order 2>&1)"
  rc=$?
  grep -E '^(owner-orders:|FATAL )' <<<"$out" | grep -vE "^FATAL Command '" || true
  return "$rc"
}

_oog_zero() { case "$1" in *[!0]*) return 1 ;; *) return 0 ;; esac; }

# oog_pre_push <top> <remote>: the ref lines on stdin. Every pushed ref but a
# delete and refs/heads/wip/* (the watchdog's backup of unfinished work, spec
# 102 5.4): <remote sha>..<local sha>, or for a new ref every commit no
# remote-tracking ref holds. rc 0 pass, else the gate's lines on stdout.
oog_pre_push() {
  local top="$1" lsha r rsha revs rc=0
  oog_has_ledger "$top" || { cat >/dev/null; return 0; }
  while read -r _ lsha r rsha; do
    [ -n "${r:-}" ] || continue
    _oog_zero "$lsha" && continue
    case "$r" in refs/heads/wip/?*) continue ;; esac
    if ! _oog_zero "$rsha" && git -C "$top" cat-file -e "$rsha^{commit}" 2>/dev/null; then revs="$rsha..$lsha"
    else revs="$lsha --not --remotes"; fi
    oog_gate "$top" ORDER_REVS="$revs" || rc=1
  done
  return "$rc"
}

# oog_range <top> <range>: the do_check_pre_push part (the lane's own run)
oog_range() {
  oog_has_ledger "$1" || { echo "owner-orders: PASS no ledger for $(oog_repo_key "$1" 2>/dev/null || echo "$1")"; return 0; }
  oog_gate "$1" ORDER_REVS="$2"
}

# owner_order_guard_check "<command>" [<cwd>]: rc 0 allow, 2 refuse (stderr
# "owner-order-guard: refused: ..." then the gate's lines)
owner_order_guard_check() {
  local cmd="${1-}" cwd="${2:-$PWD}" calls verb dir all gos revs base out rc=0 f
  case "$cmd" in *git*) ;; *) return 0 ;; esac
  case "$cmd" in *commit*|*push*) ;; *) return 0 ;; esac
  for f in "$(oog_ledger_dir)"/*.jsonl; do [ -e "$f" ] && break; f=""; done
  [ -n "$f" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "owner-order-guard: refused: python3 is missing, the guard cannot read the command (fail closed)" >&2
    return 2
  fi
  calls="$(python3 -c "$_OOG_PY" "$_oog_lib_dir/force-push-guard.inc.sh" "$cmd" "$cwd" 2>&1)" ||
    { echo "owner-order-guard: refused: cannot read the command (${calls##*$'\n'}; fail closed)" >&2; return 2; }
  while IFS=$'\x1f' read -r verb dir all gos revs base; do
    [ -n "$verb" ] || continue
    oog_has_ledger "$dir" || continue
    if [ "$verb" = commit ]; then
      out="$(oog_gate "$dir" ORDER_STAGED=1 ORDER_STAGED_ALL="$all" ORDER_STAGED_BASE="$base" ORDER_GO_MSGS="$gos")"
    else
      out="$(oog_gate "$dir" ORDER_REVS="$revs")"
    fi || {
      rc=2
      echo "owner-order-guard: refused: git $verb in $dir changes a path an owner order covers without the owner's go:" >&2
      printf '%s\n' "$out" >&2
    }
  done <<<"$calls"
  return "$rc"
}

# The walker: force-push-guard.inc.sh's tokenizer loaded as a library (the
# ONE shell parser: sudo, env, bash -c, eval, ssh, heredocs), its VISIT seam
# handed every git, cd and pushd call in order. Prints per git commit / push
# "verb<US>dir<US>all<US>go ids<US>revs<US>base" (US = \x1f).
#   commit  all=1 when it takes more than the index (-a, a pathspec, --include,
#           --only) or the same command stages something before it (the index
#           is not written yet when the hook runs): the gate then reads every
#           tracked change plus the untracked files. --amend: against HEAD^.
#           go ids: every "Owner-go: <uuid>" (or --trailer Owner-go=<uuid>)
#           in the command text, heredoc bodies included, and in a -F file.
#   push    revs = the refspecs' sources (HEAD when none; --all/--branches/
#           --mirror: every branch) not on any remote-tracking ref
# shellcheck disable=SC2016  # python source, never expanded by bash
_OOG_PY='
import os, re, sys
path, cmd, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
i = s.index("_FORCE_PUSH_GUARD_PY=\x27") + len("_FORCE_PUSH_GUARD_PY=\x27")
ns = {"__name__": "force_push_guard"}
exec(compile(s[i:s.index("\n\x27\n", i)], path, "exec"), ns)
UUID = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
GO = re.compile(r"Owner-go\s*[:=]\s*(" + UUID + ")", re.I)
GOS = GO.findall(cmd)
C_ARG = {"-m", "--message", "-F", "--file", "-C", "--reuse-message", "-c", "--reedit-message",
         "--author", "--date", "--trailer", "--fixup", "--squash", "-t", "--template", "--cleanup",
         "--pathspec-from-file"}
P_ARG = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
STAGE = {"add", "rm", "mv", "stage", "apply", "restore", "checkout", "reset", "cherry-pick"}
SAFE = re.compile(r"^[A-Za-z0-9_./@^~{}-]+$")
st = {"cwd": cwd, "staged": False}
out = []

def commit(tgt, a):
    gos, allc, base, j = list(GOS), st["staged"], "HEAD", 0
    while j < len(a):
        x = a[j]
        if x == "--":
            allc = allc or j + 1 < len(a)
            break
        if x == "--amend":
            base = "HEAD^"
        elif x in ("--all", "--include", "--only") or re.match(r"^-[A-Za-z]*a[A-Za-z]*$", x) and not x.startswith("--"):
            allc = True
        if x in ("-F", "--file") and j + 1 < len(a) or x.startswith("--file="):
            fp = a[j + 1] if "=" not in x else x.split("=", 1)[1]
            try:
                gos += GO.findall(open(os.path.join(tgt, os.path.expanduser(fp))).read())
            except OSError:
                pass
        if x in C_ARG:
            j += 2
            continue
        if not x.startswith("-"):
            allc = True
        j += 1
    return ["commit", tgt, "1" if allc else "0", ",".join(dict.fromkeys(gos)), "", base]

def push(tgt, a):
    pos, srcs, j = [], [], 0
    while j < len(a):
        x = a[j]
        if x in ("--all", "--branches", "--mirror"):
            srcs.append("--branches")
        if x.startswith("-"):
            j += 2 if x in P_ARG else 1
            continue
        pos.append(x)
        j += 1
    for r in pos[1:]:
        src = r.lstrip("+").split(":", 1)[0]
        if src:
            srcs.append(src if SAFE.match(src) else "--branches")
    if not srcs:
        srcs = ["HEAD"]
    return ["push", tgt, "0", "", " ".join(dict.fromkeys(srcs)) + " --not --remotes", ""]

def visit(word, args):
    if word != "git":
        d = [x for x in args if not x.startswith("-")]
        if d:
            st["cwd"] = os.path.join(st["cwd"], os.path.expanduser(d[0]))
        return
    i, dirs = ns["git_verb"](args)
    if i >= len(args):
        return
    tgt = os.path.normpath(os.path.join(st["cwd"], *[os.path.expanduser(x) for x in dirs]))
    v, rest = args[i], args[i + 1:]
    if v == "commit":
        out.append(commit(tgt, rest))
    elif v == "push":
        out.append(push(tgt, rest))
    elif v in STAGE:
        st["staged"] = True

ns["VISIT"] = visit
try:
    ns["check"](cmd)
except ns["Refuse"]:
    pass  # a forbidden push form is force-push-guard-hook.sh to deny
for o in out:
    print("\x1f".join(o))
'

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1-}" = --check ] && { [ $# -eq 2 ] || [ $# -eq 3 ]; }; then
    owner_order_guard_check "$2" "${3:-$PWD}"
    exit $?
  fi
  echo "usage: bash owner-order-guard.inc.sh --check \"<command>\" [<cwd>]  (rc 0 allow, 2 refuse)" >&2
  exit 64
fi
