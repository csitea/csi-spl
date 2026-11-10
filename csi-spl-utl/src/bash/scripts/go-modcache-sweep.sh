#!/usr/bin/env bash
# go-modcache-sweep.sh - remove the Go module versions that no checkout on the
# box names (SPL-5225, owner HUM-10 poll 2cfa8ce7 Q4, row 6 of the sat disk
# table: "Go module versions no project on the box uses", 1.4 GB, "a
# re-download if needed"). The build-cache prune (do_prune_go_build_cache)
# never touches GOMODCACHE, and `go clean -modcache` drops every version.
#
# The caches: each box user's GOMODCACHE (`go env GOMODCACHE` in that user's
# login shell, else <home>/go/pkg/mod), or GO_MODCACHE_DIRS. The names: every
# go.mod and go.sum under GO_MODCACHE_ROOTS and the users' homes (node_modules,
# .git and */pkg/mod pruned): a go.sum line names <module>@<version> (its
# /go.mod form too), a go.mod line <module> <version> (require, replace), and
# its go / toolchain line keeps golang.org/toolchain@v0.0.1-go<that>.<os-arch>.
#
# A module version (its extracted <module>@<version>/ dir and its
# cache/download/<module>/@v/<version>.* files, the case-escaped `!x` names
# decoded) goes only when ALL hold:
#   - no go.mod / go.sum names it;
#   - no file of it changed in GO_MODCACHE_AGE_D days (default 7);
#   - the cache owner runs no go build, test, vet or lint now (else the whole
#     cache is one KEEP busy line).
# It goes as the cache owner: chmod -R u+w (the cache's files and dirs are
# read-only, as `go clean -modcache` handles them), then rm. A scan that hits
# an unreadable dir, or finds no go.mod / go.sum at all, removes nothing.
#
#   DRY_RUN=1 (default) | 0
#   GO_MODCACHE_SUDO    1 (default) | 0: no sudo, this user's caches only
#   GO_MODCACHE_USERS   users whose cache is swept (default: every login shell)
#   GO_MODCACHE_DIRS    "<owner>:<dir> ..." in place of the users' caches
#   GO_MODCACHE_ROOTS   where go.mod / go.sum are looked for (default
#                       "/opt /srv /var/tmp /tmp", the users' homes added)
#   GO_MODCACHE_AGE_D   idle days before removal (default 7)
#   GO_MODCACHE_BUSY_RX (tests) the program names that make a cache busy
#
# Lines: PLAN remove|REMOVE <KB>KB user=<u> <module>@<version>;
#        KEEP used|recent <KB>KB user=<u> <module>@<version>; KEEP busy user=<u> <dir>;
#        CACHE ... per cache; DONE would-remove|removed=<n> (<MB> MB).
# Exit: 0 done; 1 a removal failed; 2 usage or a refusal (nothing removed).
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

dry="${DRY_RUN:-1}"
use_sudo="${GO_MODCACHE_SUDO:-1}"
age_d="${GO_MODCACHE_AGE_D:-7}"
roots="${GO_MODCACHE_ROOTS:-/opt /srv /var/tmp /tmp}"
busy_rx="${GO_MODCACHE_BUSY_RX:-^(go|compile|link|asm|cgo|vet|golangci-lint|gosec|staticcheck|govulncheck)\$}"
n_rm=0 kb_rm=0 fail=0
declare -a caches=()

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
refuse() { say "REFUSE $*: nothing removed"; exit 2; }
as_root() { if [[ "$use_sudo" == 1 && "$(id -u)" != 0 ]]; then sudo -n -- "$@"; else "$@"; fi; }
as_owner() { if [[ "$1" == "$(id -un)" ]]; then shift; "$@"; else local o="$1"; shift; sudo -n -u "$o" -- "$@"; fi; }

[[ "$dry" == 0 || "$dry" == 1 ]] || refuse "DRY_RUN must be 0 or 1, got '$dry'"
[[ "$use_sudo" == 0 || "$use_sudo" == 1 ]] || refuse "GO_MODCACHE_SUDO must be 0 or 1, got '$use_sudo'"
[[ "$age_d" =~ ^[0-9]+$ ]] && (( age_d >= 1 )) || refuse "GO_MODCACHE_AGE_D must be a whole number >= 1, got '$age_d'"
[[ "$use_sudo" == 0 || "$(id -u)" == 0 ]] || sudo -n true 2>/dev/null || refuse "no sudo -n: other users' caches and checkouts cannot be read"

# find_caches: fills caches with "<owner>:<dir>", one per real dir; adds the
# users' homes to roots
find_caches() {
  local u home d spec o seen=" "
  if [[ -n "${GO_MODCACHE_DIRS:-}" ]]; then
    for spec in $GO_MODCACHE_DIRS; do caches+=("$spec"); done
    return 0
  fi
  while IFS=: read -r u _ _ _ _ home _; do
    [[ -n "${GO_MODCACHE_USERS:-}" && " $GO_MODCACHE_USERS " != *" $u "* ]] && continue
    [[ -d "$home" && "$home" != / ]] && roots="$roots $home"
    d="$(as_owner "$u" timeout 30 bash -lc 'command -v go >/dev/null && go env GOMODCACHE' 2>/dev/null | tail -1)"
    [[ -n "$d" ]] || d="$home/go/pkg/mod"
    d="$(as_root readlink -f -- "$d" 2>/dev/null)" || continue
    [[ -n "$d" && "$seen" != *" $d "* ]] && as_root test -d "$d/cache/download" || continue
    seen="$seen$d "; o="$(as_root stat -c %U -- "$d")" || continue
    caches+=("$o:$d")
  done < <(getent passwd | awk -F: -v want="${GO_MODCACHE_USERS:-}" \
    'want != "" || $7 !~ /(nologin|false|sync)$/')
}

# names_py: reads NUL-separated go.mod / go.sum paths on stdin, prints
# "m <module>@<version>" and "t <go version>"; "err <path>" for an unreadable one
names_py='
import os, re, sys
ver = re.compile(r"^v\d+\.\d+\.\d+\S*$")
seen = set()
for p in sys.stdin.read().split("\0"):
    if not p:
        continue
    try:
        txt = open(p, errors="replace").read()
    except OSError:
        print("err", p)
        continue
    gosum = os.path.basename(p) == "go.sum"
    for line in txt.splitlines():
        t = line.split("//")[0].split()
        if gosum and len(t) >= 2:
            seen.add("m %s@%s" % (t[0], t[1][:-7] if t[1].endswith("/go.mod") else t[1]))
            continue
        if not gosum and len(t) >= 2 and t[0] in ("go", "toolchain"):
            seen.add("t " + (t[1][2:] if t[1].startswith("go") else t[1]))
        for i in range(len(t) - 1):
            if not gosum and ver.match(t[i + 1]) and t[i] != "=>":
                seen.add("m %s@%s" % (t[i], t[i + 1]))
print("\n".join(sorted(seen)))
'

# versions_py <cache>: one line per module version in the cache:
# <module>@<version> TAB <extracted dir|-> TAB <download files, "|"-joined|-> TAB <KB> TAB <newest mtime>
versions_py='
import os, re, stat, sys
root = sys.argv[1]
dec = lambda s: re.sub(r"!([a-z])", lambda m: m.group(1).upper(), s)
v = {}
def tree(p):
    kb, new = 0, 0
    for dp, dn, fn in os.walk(p):
        for n in [dp] + [os.path.join(dp, f) for f in fn]:
            s = os.lstat(n)
            new = max(new, int(s.st_mtime))
            if not stat.S_ISDIR(s.st_mode):
                kb += (s.st_blocks * 512) // 1024
    return kb, new
def row(key):
    return v.setdefault(key, {"dir": "-", "dl": [], "kb": 0, "new": 0})
def visit(p):
    if os.path.islink(p) or not os.path.isdir(p):
        return
    if "@" in os.path.basename(p):
        r = row(dec(os.path.relpath(p, root)))
        r["dir"] = p
        kb, new = tree(p)
        r["kb"] += kb; r["new"] = max(r["new"], new)
        return
    for e in sorted(os.listdir(p)):
        visit(os.path.join(p, e))
for e in sorted(os.listdir(root)):
    if e != "cache":
        visit(os.path.join(root, e))
dl = os.path.join(root, "cache", "download")
for dp, dn, fn in os.walk(dl):
    if os.path.relpath(dp, dl).split(os.sep)[0] == "sumdb":
        dn[:] = []
        continue
    if os.path.basename(dp) != "@v":
        continue
    dn[:] = []
    mod = os.path.relpath(os.path.dirname(dp), dl)
    for f in fn:
        m = re.match(r"^(.+)\.(info|mod|zip|ziphash|lock|partial)$", f)
        if not m:
            continue
        r = row(dec(mod + "@" + m.group(1)))
        s = os.lstat(os.path.join(dp, f))
        r["dl"].append(os.path.join(dp, f))
        r["kb"] += (s.st_blocks * 512) // 1024; r["new"] = max(r["new"], int(s.st_mtime))
for k in sorted(v):
    r = v[k]
    print("%s\t%s\t%s\t%d\t%d" % (k, r["dir"], "|".join(sorted(r["dl"])) or "-", r["kb"], r["new"]))
'

# go_busy <user>: 0 when one of that user's processes is a Go build or lint
# (its program name matches busy_rx)
go_busy() {
  local prog _
  while read -r prog _; do
    [[ "${prog##*/}" =~ $busy_rx ]] && return 0
  done < <(ps -u "$1" -o args= 2>/dev/null || true)
  return 1
}

# load_names: fills used / used_tc from every go.mod and go.sum under roots;
# refuses on a scan error or when none is found
declare -A used=() used_tc=()
load_names() {
  local errf list n kind val c bad prunes=()
  errf="$(mktemp)" list="$(mktemp)"
  for c in "${caches[@]}"; do prunes+=(-path "${c#*:}" -prune -o); done
  # shellcheck disable=SC2086 # roots is a word list
  as_root find $roots "${prunes[@]}" \( -name node_modules -o -name .git -o -path '*/pkg/mod' \) -prune \
    -o -type f \( -name go.mod -o -name go.sum \) -print0 >"$list" 2>"$errf"
  bad="$(grep -v 'No such file or directory' "$errf")"
  if [[ -n "$bad" ]]; then
    say "ERR $(sed -n 1,3p <<<"$bad" | tr '\n' ' ')"
    rm -f "$errf" "$list"; refuse "the go.mod / go.sum scan did not read every dir"
  fi
  n="$(tr -cd '\0' <"$list" | wc -c)"
  (( n > 0 )) || { rm -f "$errf" "$list"; refuse "no go.mod or go.sum under $roots"; }
  while read -r kind val; do
    case "$kind" in
      m) used["$val"]=1 ;;
      t) used_tc["$val"]=1 ;;
      err) rm -f "$errf" "$list"; refuse "cannot read $val" ;;
    esac
  done < <(as_root python3 -c "$names_py" <"$list")
  rm -f "$errf" "$list"
  say "NAMES files=$n versions=${#used[@]} go_versions=${#used_tc[@]} roots=$roots"
}

# is_used <module>@<version>
is_used() {
  [[ -n "${used[$1]:-}" ]] && return 0
  [[ "$1" =~ ^golang\.org/toolchain@v0\.0\.1-go(.+)\.[a-z0-9]+-[a-z0-9]+$ ]] && [[ -n "${used_tc[${BASH_REMATCH[1]}]:-}" ]]
}

# rm_version <owner> <dir|-> <files|->: chmod u+w, then remove, as the owner
rm_version() {
  local o="$1" d="$2" f="$3" files=()
  [[ "$f" == - ]] || IFS='|' read -r -a files <<<"$f"
  if [[ "$d" != - ]]; then
    as_owner "$o" chmod -R u+w -- "$d" 2>/dev/null
    as_owner "$o" rm -rf -- "$d" || return 1
    [[ ! -e "$d" ]] || return 1
  fi
  (( ${#files[@]} )) || return 0
  as_owner "$o" rm -f -- "${files[@]}" || return 1
  for f in "${files[@]}"; do [[ ! -e "$f" ]] || return 1; done
}

# sweep_cache <owner>:<dir>
sweep_cache() {
  local o="${1%%:*}" d="${1#*:}" key dir files kb new cut n=0 k=0 nk=0 kk=0
  [[ "$use_sudo" == 0 && "$o" != "$(id -un)" ]] && { say "KEEP not-ours user=$o $d"; return; }
  go_busy "$o" && { say "KEEP busy user=$o $d: a go build, test, vet or lint of that user is running"; return; }
  cut=$(( $(date +%s) - age_d * 86400 ))
  while IFS=$'\t' read -r key dir files kb new; do
    if is_used "$key"; then say "KEEP used ${kb}KB user=$o $key"
    elif (( new > cut )); then say "KEEP recent ${kb}KB user=$o $key"
    else
      if [[ "$dry" == 1 ]]; then say "PLAN remove ${kb}KB user=$o $key"
      elif rm_version "$o" "$dir" "$files"; then say "REMOVE ${kb}KB user=$o $key"
      else say "WARN could not remove user=$o $key"; fail=1; nk=$((nk + 1)); kk=$((kk + kb)); continue
      fi
      n=$((n + 1)); k=$((k + kb)); continue
    fi
    nk=$((nk + 1)); kk=$((kk + kb))
  done < <(as_root python3 -c "$versions_py" "$d")
  say "CACHE user=$o $d $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n ($((k / 1024)) MB) kept=$nk ($((kk / 1024)) MB)"
  n_rm=$((n_rm + n)); kb_rm=$((kb_rm + k))
}

find_caches
(( ${#caches[@]} )) || { say "OK no Go module cache found"; exit 0; }
say "START caches=${#caches[@]} dry_run=$dry age_d=$age_d"
load_names
for c in "${caches[@]}"; do sweep_cache "$c"; done
say "DONE $([[ "$dry" == 1 ]] && echo would-remove || echo removed)=$n_rm ($((kb_rm / 1024)) MB) dry_run=$dry"
exit "$fail"
