#!/usr/bin/env bash
# wt-dirty-salvage.tst.sh - hermetic test of the SPL-2514 salvage step in
# wt-dead-sweep.sh: a RETIRED lane's dirty worktree is written to a LOCAL git
# bundle plus an archive, then removed on a later pass; nothing is pushed.
#
# A sandbox bare origin, its clone as the main checkout, worktrees under a temp
# root, all files 10 days old:
#   c-901  retired, a tracked edit, a new source file, a STATE.md scratch and
#          an ignored node_modules file  -> pass 1 SALVAGE (kept), pass 2 REMOVE
#   c-902  dirty, retired row for its rundir BUT a live registry.tsv row (the
#          id was reused)                -> KEEP dirty both passes
#   c-903  retired, salvaged on pass 1, its bundle corrupted before pass 2
#          -> pass 2 refuses the removal, the tree stays
#   c-904  retired, salvaged on pass 1, edited again before pass 2
#          -> pass 2 salvages again, the tree stays
# Origin's refs are counted before and after every run: none is added.
# A first real run with WT_SALVAGE=0 (the default) keeps c-901 dirty and
# writes nothing; the other runs pass WT_SALVAGE=1.
#
# Red control: the script before SPL-2514 keeps c-901 dirty on every pass;
# 2385546e2's (the wip-push salvage) adds refs to origin: both FAIL here.
set -euo pipefail

self_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
sweep="${WT_SWEEP_SCRIPT:-$self_dir/../scripts/wt-dead-sweep.sh}"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
origin="$tmp/origin.git"; repo="$tmp/repo"; root="$tmp/repo-wt"; spool="$tmp/spool"
fails=0 n=0

ok() { n=$((n + 1)); echo "PASS: $1"; }
ko() { n=$((n + 1)); fails=$((fails + 1)); echo "FAIL: $1"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else ko "$what"; fi; }
has() { grep -qE -- "$2" "$1"; }
hasnt() { ! grep -qE -- "$2" "$1"; }
old() { find "$1" -exec touch -h -d '10 days ago' {} +; }
gq() { git -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
refs_n() { git -C "$origin" for-each-ref | wc -l; }
row() { awk -F'\t' -v id="$1" -v c="$2" '$2 == id {r = $c} END {print r}' "$log" 2>/dev/null || true; }

mkdir -p "$spool/agents"
gq init --bare "$origin"
gq clone "$origin" "$repo"
git -C "$repo" config user.name "Test Author"; git -C "$repo" config user.email "test@example.com"
mkdir -p "$repo/csi-spl-orc"
echo base >"$repo/csi-spl-orc/a.sh"; printf 'node_modules/\n' >"$repo/.gitignore"
gq -C "$repo" add .; gq -C "$repo" commit -m init; gq -C "$repo" push origin master; gq -C "$repo" fetch origin

for id in c-901 c-902 c-903 c-904; do
  gq -C "$repo" worktree add -b "$id-lane" "$root/$id" origin/master
  echo "edit $id" >>"$root/$id/csi-spl-orc/a.sh"
  printf '%s\tclaude\t%%1\t%s\t20261001T000000Z\t20261002T000000Z\n' "$id" "$root/$id" >>"$spool/registry.retired.tsv"
done
echo new >"$root/c-901/csi-spl-orc/new.sh"
echo notes >"$root/c-901/STATE.md"
mkdir -p "$root/c-901/node_modules"; echo junk >"$root/c-901/node_modules/x.js"
printf 'c-902\tclaude\t%%2\t%s\t20261010T000000Z\n' "$root/c-902" >"$spool/registry.tsv"
old "$root"
# The live spool root carries a default ACL (group rwx) that beats the umask:
# plant one, so the 600 / 700 checks below see what sat sees.
acl=0; if command -v setfacl >/dev/null && setfacl -d -m g::rwx -m o::- "$spool" 2>/dev/null; then acl=1; fi

run() {
  WT_REPO="$repo" WT_ROOT="$root" WT_SWEEP_AGE_H=24 SPOOL_ROOT="$spool" DRY_RUN="$1" WT_SALVAGE="${SALV:-1}" \
    bash "$sweep" >"$tmp/$2.out" 2>&1 || true
}
log="$spool/wt-salvage.tsv"
refs0="$(refs_n)"

SALV=0 run 0 off
check "WT_SALVAGE=0: c-901 KEEP dirty" has "$tmp/off.out" "KEEP dirty .*/c-901$"
check "WT_SALVAGE=0: no log" [ ! -e "$log" ]

run 1 dry
D="$tmp/dry.out"
check "dry: c-901 salvage planned" has "$D" "KEEP dirty-retired-salvage-planned .*/c-901$"
check "dry: writes no salvage log" [ ! -e "$log" ]
check "dry: c-902 (live id) KEEP dirty" has "$D" "KEEP dirty .*/c-902$"
check "dry: DONE would-salvage=3" has "$D" 'would-salvage=3 '

run 0 p1
P1="$tmp/p1.out"
s901="$(row c-901 5)"; b901="$(row c-901 4)"; arch="$(row c-901 8)"
check "pass 1: c-901 SALVAGE line" has "$P1" "SALVAGE c-901 $s901 -> .*/c-901\.[0-9TZ]+\.bundle residue=1 "
check "pass 1: c-901 kept until a later pass" [ -f "$root/c-901/csi-spl-orc/a.sh" ]
check "pass 1: NO ref reaches origin" [ "$(refs_n)" = "$refs0" ]
bundle_ok() { git -C "$repo" bundle verify -q "$b901" >/dev/null 2>&1; }
check "pass 1: the bundle verifies in the repo" bundle_ok
mkdir -p "$tmp/restore"; git -C "$tmp/restore" init -q
git -C "$tmp/restore" fetch -q "$origin" master 2>/dev/null || true
git -C "$tmp/restore" fetch -q "$b901" "refs/heads/salvage/c-901:refs/heads/r" 2>/dev/null || true
check "pass 1: the bundle has the tracked edit" [ "$(git -C "$tmp/restore" show "$s901:csi-spl-orc/a.sh" 2>/dev/null | tail -1)" = "edit c-901" ]
check "pass 1: the bundle has the new source file" [ "$(git -C "$tmp/restore" show "$s901:csi-spl-orc/new.sh" 2>/dev/null)" = new ]
check "pass 1: STATE.md is not in the bundle" [ -z "$(git -C "$tmp/restore" ls-tree "$s901" STATE.md 2>/dev/null)" ]
check "pass 1: STATE.md archived" [ "$(tar -xzOf "$arch" STATE.md 2>/dev/null)" = notes ]
no_junk() { [ -n "$arch" ] && [ -z "$(git -C "$tmp/restore" ls-tree -r "$s901" node_modules 2>/dev/null)$(tar -tzf "$arch" | grep node_modules || true)" ]; }
check "pass 1: node_modules (ignored) neither bundled nor archived" no_junk
check "pass 1: the salvage dir is mode 700" [ "$(stat -c %a "$spool/wt-salvage")" = 700 ]
check "pass 1: the bundle is mode 600" [ "$(stat -c %a "$b901")" = 600 ]
check "pass 1: the archive is mode 600" [ "$(stat -c %a "$arch")" = 600 ]
no_default_acl() { (( ! acl )) || [ -z "$(getfacl -p -d "$spool/wt-salvage" 2>/dev/null | grep -v '^#' | grep .)" ]; }
check "pass 1: the salvage dir has no default ACL" no_default_acl
check "pass 1: the lane's own index is untouched" [ -z "$(git -C "$root/c-901" diff --cached --name-only)" ]
check "pass 1: the repo has no salvage ref" [ -z "$(git -C "$repo" for-each-ref refs/heads/salvage)" ]
check "pass 1: c-902 KEEP dirty" has "$P1" "KEEP dirty .*/c-902$"
check "pass 1: removes nothing" hasnt "$P1" ' REMOVE '

s904="$(row c-904 5)"; b903="$(row c-903 4)"
{ printf 'not a bundle\n' >"$b903"; } 2>/dev/null || true
echo "edit again" >>"$root/c-904/csi-spl-orc/a.sh"; old "$root/c-904"
run 0 p2
P2="$tmp/p2.out"
check "pass 2: c-901 REMOVED, salvaged sha logged" has "$P2" "REMOVE .*/c-901 branch c-901-lane salvaged $s901$"
check "pass 2: c-901 tree gone" [ ! -e "$root/c-901" ]
check "pass 2: c-901 bundle kept" [ -s "$b901" ]
check "pass 2: c-902 (live) untouched" [ "$(tail -1 "$root/c-902/csi-spl-orc/a.sh")" = "edit c-902" ]
check "pass 2: c-902 KEEP dirty" has "$P2" "KEEP dirty .*/c-902$"
check "pass 2: c-903 corrupt bundle: removal refused" hasnt "$P2" "REMOVE .*/c-903"
check "pass 2: c-903 tree still there" [ "$(tail -1 "$root/c-903/csi-spl-orc/a.sh")" = "edit c-903" ]
check "pass 2: c-904 changed after salvage: salvaged again" has "$P2" "SALVAGE c-904 "
resalvaged() { [ -n "$s904" ] && [ "$(row c-904 5)" != "$s904" ]; }
check "pass 2: c-904 new salvage sha" resalvaged
check "pass 2: c-904 tree kept" [ "$(tail -1 "$root/c-904/csi-spl-orc/a.sh")" = "edit again" ]
check "pass 2: removes only c-901" [ "$(grep -c ' REMOVE ' "$P2")" = 1 ]
check "pass 2: NO ref reaches origin" [ "$(refs_n)" = "$refs0" ]

if (( fails )); then
  for f in off dry p1 p2; do echo "--- $f"; cat "$tmp/$f.out"; done
  echo "FAILED: $fails of $n"; exit 1
fi
echo "OK: $n of $n"
