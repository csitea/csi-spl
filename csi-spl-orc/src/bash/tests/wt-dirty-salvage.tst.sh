#!/usr/bin/env bash
# wt-dirty-salvage.tst.sh - hermetic test of the SPL-2514 salvage step in
# wt-dead-sweep.sh: a RETIRED lane's dirty worktree is pushed to its wip ref
# and archived, then removed on a later pass; nothing else is.
#
# A sandbox bare origin, its clone as the main checkout, worktrees under a temp
# root, all files 10 days old:
#   c-901  retired, a tracked edit, a new source file, a STATE.md scratch and
#          an ignored node_modules file  -> pass 1 SALVAGE (kept), pass 2 REMOVE
#   c-902  dirty, retired row for its rundir BUT a live registry.tsv row (the
#          id was reused)                -> KEEP dirty both passes, no wip ref
#   c-903  retired, but origin refuses its wip push -> KEEP push-failed, no log
#          row, tree kept both passes
#   c-904  retired, salvaged on pass 1, edited again before pass 2
#          -> pass 2 salvages again, the tree stays
# A first real run with WT_SALVAGE=0 (the default) keeps c-901 dirty and
# pushes nothing; the other runs pass WT_SALVAGE=1.
# The dry run plans, pushes nothing and writes no log.
#
# Red control: the script before SPL-2514 (no salvage) keeps c-901 dirty on
# every pass, so "pass 2 removes c-901" and the wip-ref checks FAIL.
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
wip_sha() { git -C "$origin" rev-parse -q --verify "refs/heads/wip/$1-lane" 2>/dev/null || true; }

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
cat >"$origin/hooks/pre-receive" <<'HOOK'
#!/bin/sh
while read -r _ _ ref; do case "$ref" in refs/heads/wip/c-903*) echo "refused $ref" >&2; exit 1 ;; esac; done
HOOK
chmod +x "$origin/hooks/pre-receive"
old "$root"

run() {
  WT_REPO="$repo" WT_ROOT="$root" WT_SWEEP_AGE_H=24 SPOOL_ROOT="$spool" DRY_RUN="$1" WT_SALVAGE="${SALV:-1}" \
    bash "$sweep" >"$tmp/$2.out" 2>&1 || true
}
log="$spool/wt-salvage.tsv"

SALV=0 run 0 off
check "WT_SALVAGE=0: c-901 KEEP dirty, nothing pushed" has "$tmp/off.out" "KEEP dirty .*/c-901$"
untouched_off() { [ -z "$(wip_sha c-901)" ] && [ ! -e "$spool/wt-salvage.tsv" ]; }
check "WT_SALVAGE=0: no wip ref, no log" untouched_off
run 1 dry
D="$tmp/dry.out"
check "dry: c-901 salvage planned" has "$D" "KEEP dirty-retired-salvage-planned .*/c-901$"
check "dry: pushes nothing" [ -z "$(wip_sha c-901)$(wip_sha c-904)" ]
check "dry: writes no salvage log" [ ! -e "$log" ]
check "dry: c-902 (live id) KEEP dirty" has "$D" "KEEP dirty .*/c-902$"
check "dry: DONE would-salvage=3" has "$D" 'would-salvage=3 '

run 0 p1
P1="$tmp/p1.out"
s901="$(wip_sha c-901)"
check "pass 1: c-901 SALVAGE line" has "$P1" "SALVAGE c-901 $s901 -> origin refs/heads/wip/c-901-lane residue=1 "
check "pass 1: c-901 kept until a later pass" [ -f "$root/c-901/csi-spl-orc/a.sh" ]
check "pass 1: origin wip commit has the tracked edit" [ "$(git -C "$origin" show "$s901:csi-spl-orc/a.sh" 2>/dev/null | tail -1)" = "edit c-901" ]
check "pass 1: origin wip commit has the new source file" [ "$(git -C "$origin" show "$s901:csi-spl-orc/new.sh" 2>/dev/null)" = new ]
check "pass 1: STATE.md stays off the public ref" [ -z "$(git -C "$origin" ls-tree "$s901" STATE.md)" ]
arch="$(awk -F'\t' '$2 == "c-901" {print $7}' "$log" 2>/dev/null || true)"
no_junk() { [ -n "$arch" ] && [ -z "$(git -C "$origin" ls-tree -r "$s901" node_modules)$(tar -tzf "$arch" | grep node_modules || true)" ]; }
no_row() { [ -e "$log" ] && [ -z "$(awk -F'\t' -v id="$1" '$2 == id' "$log")" ]; }
check "pass 1: STATE.md archived" [ "$(tar -xzOf "$arch" STATE.md 2>/dev/null)" = notes ]
check "pass 1: node_modules (ignored) neither pushed nor archived" no_junk
check "pass 1: c-902 KEEP dirty, no wip ref" [ -z "$(wip_sha c-902)" ]
check "pass 1: c-903 KEEP push-failed" has "$P1" "KEEP dirty-retired-kept-push-failed .*/c-903$"
check "pass 1: c-903 no log row" no_row c-903
check "pass 1: removes nothing" hasnt "$P1" ' REMOVE '

s904="$(wip_sha c-904)"
echo "edit again" >>"$root/c-904/csi-spl-orc/a.sh"; old "$root/c-904"
run 0 p2
P2="$tmp/p2.out"
check "pass 2: c-901 REMOVED, salvaged sha logged" has "$P2" "REMOVE .*/c-901 branch c-901-lane salvaged $s901$"
check "pass 2: c-901 tree gone" [ ! -e "$root/c-901" ]
check "pass 2: c-901 work still on origin" [ "$(git -C "$origin" show "$s901:csi-spl-orc/new.sh" 2>/dev/null)" = new ]
check "pass 2: c-902 (live) untouched" [ "$(tail -1 "$root/c-902/csi-spl-orc/a.sh")" = "edit c-902" ]
check "pass 2: c-902 KEEP dirty" has "$P2" "KEEP dirty .*/c-902$"
check "pass 2: c-903 (push failed) still there" [ "$(tail -1 "$root/c-903/csi-spl-orc/a.sh")" = "edit c-903" ]
check "pass 2: c-904 changed after salvage: salvaged again" has "$P2" "SALVAGE c-904 "
resalvaged() { [ -n "$s904" ] && [ "$(wip_sha c-904)" != "$s904" ]; }
check "pass 2: c-904 new wip sha" resalvaged
check "pass 2: c-904 tree kept" [ "$(tail -1 "$root/c-904/csi-spl-orc/a.sh")" = "edit again" ]
check "pass 2: removes only c-901" [ "$(grep -c ' REMOVE ' "$P2")" = 1 ]

if (( fails )); then
  for f in dry p1 p2; do echo "--- $f"; cat "$tmp/$f.out"; done
  echo "FAILED: $fails of $n"; exit 1
fi
echo "OK: $n of $n"
