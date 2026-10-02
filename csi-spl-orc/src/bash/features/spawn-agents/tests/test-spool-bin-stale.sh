#!/usr/bin/env bash
# test-spool-bin-stale.sh — SPOOL_BIN never resolves to a tree build that is
# OLDER than its own sources (CLE-77929, 2026-10-02): the box user's checkout
# held a 2026-09-18 bin/spool that refused kind blocker, so every spool-send.sh
# run from that tree failed (the asks re-raise, a probe's "ask: open").
#   1. a fresh build (newer than the last source commit) is used
#   2. a stale one is skipped with a loud WARN naming the rebuild command;
#      the spool on PATH is used
#   3. nothing on PATH: ~/.local/bin/spool
#   4. nothing else at all: the stale build anyway, with a WARN
#   5. an explicit SPOOL_BIN always wins, with no check
#   6. not a git checkout: the build is used, not judged
set -uo pipefail
. "$(dirname "$0")/lib.inc.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/repo"; API="$R/csi-spl-api/src/go/spool-hub-api"
mkdir -p "$API/internal" "$API/bin" "$R/csi-spl-orc/src/bash/features/spawn-agents" "$T/path" "$T/home/.local/bin" "$T/spool"
cp -r "$T_FEAT/lib" "$R/csi-spl-orc/src/bash/features/spawn-agents/"
echo 'package x' >"$API/internal/x.go"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" -c user.email=t@example.com -c user.name=t commit -q -m src
src="$(git -C "$R" log -1 --format=%ct)"
for b in "$API/bin/spool" "$T/path/spool" "$T/home/.local/bin/spool"; do printf '#!/bin/sh\necho %s\n' "$b" >"$b"; chmod +x "$b"; done
resolve() {  # prints SPOOL_BIN, stderr to $T/err
  env -u SPOOL_BIN HOME="$T/home" PATH="$1:/usr/bin:/bin" SPOOL_ROOT="$T/spool" SPOOL_TEST=1 ${2:+SPOOL_BIN=$2} \
    bash -c '. "'"$R"'/csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh"; spool_env_resolve; printf "%s" "$SPOOL_BIN"' 2>"$T/err"
}
touch -d "@$((src + 60))" "$API/bin/spool"
eq "1 a build newer than its sources is used" "$API/bin/spool" "$(resolve "$T/path")"
touch -d "@$((src - 86400))" "$API/bin/spool"
eq "2 a stale build is skipped for the spool on PATH" "$T/path/spool" "$(resolve "$T/path")"
has "2 ... with a WARN naming the rebuild" "is older than its sources" "$(cat "$T/err")"
has "2 ... and the build command" "csi-spl-api/src/bash/build.sh" "$(cat "$T/err")"
eq "3 nothing on PATH: ~/.local/bin/spool" "$T/home/.local/bin/spool" "$(resolve "$T/nopath")"
rm -f "$T/home/.local/bin/spool"
eq "4 nothing else: the stale build anyway" "$API/bin/spool" "$(resolve "$T/nopath")"
has "4 ... with a WARN" "using the stale" "$(cat "$T/err")"
eq "5 an explicit SPOOL_BIN wins" "/explicit/spool" "$(resolve "$T/path" /explicit/spool)"
rm -rf "$R/.git"
eq "6 not a git checkout: the build is used" "$API/bin/spool" "$(resolve "$T/path")"
t_done
