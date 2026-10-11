#!/usr/bin/env bash
# test-spawn-private-realm.sh — spec 129 G1 (phase A0): at spawn a lane whose
# brief comes from a topic of a workspace on the box-local private list is a
# PRIVATE lane. It gets no worktree of the public repository, whatever path
# its brief names, and a lane already holding a public worktree gets no
# private checkout. Rendered with SPAWN_DRY_RUN=1 in the sandbox.
#   1. a brief naming the private topic and csi-spl-doc/specs/... on the
#      public repo -> REFUSED, no worktree planned, workspace never printed
#   2. SPAWN_LANE_TOPIC alone names the private topic        -> REFUSED
#   3. CONTROL: the same brief without the topic             -> realm=public, worktree planned
#   4. a lane on a listed private checkout                   -> realm=private, allowed, hub scope realm=private
#   5. ... with an id that already holds a public worktree   -> REFUSED
#   6. a lane recorded private stays private on a respawn    -> REFUSED
#   7. a list that exists but cannot be read                 -> REFUSED (never assumed public)
#   8. no list at all                                        -> realm=public
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
export SPAWN_GIT_IDENTITY='FirstName LastName <dev@example.com>'
ws="wsq9private" topic="abcdef12-1111-4222-8333-444455556666"
export SPOOL_PRIVATE_REALMS="$T_TMP/private-realms.conf"

mkrepo() {  # <dir> [fleet hook]: a git repo with an origin
  git init -q "$1"
  if [ -n "${2:-}" ]; then
    mkdir -p "$1/csi-spl-orc/src/bash/features/spawn-agents/hooks"
    echo '#!/bin/sh' >"$1/csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push"
    git -C "$1" add -A
  fi
  git -C "$1" -c user.name=FirstName\ LastName -c user.email=dev@example.com commit -q --allow-empty -m init
  git -C "$1" branch -M master
  git init -q --bare "$1.origin.git"; git -C "$1" remote add origin "$1.origin.git"
  git -C "$1" push -q origin master 2>/dev/null
}
PUB="$T_TMP/pub"; mkrepo "$PUB" hook
PRIV="$T_TMP/priv"; mkrepo "$PRIV"
export SPAWN_PUBLIC_REPO="$PUB"
printf '# workspaces\nworkspace %s %s\ncheckout %s %s\n' "$ws" "${topic:0:8}" "$ws" "$PRIV" >"$SPOOL_PRIVATE_REALMS"
printf '# Brief: write the panel spec\nReport on task dispatch-%s-a0.\nFiles: csi-spl-doc/specs/130-panel/spec.md\n' "${topic:0:8}" >"$T_TMP/brief-priv.md"
printf '# Brief: write the panel spec\nFiles: csi-spl-doc/specs/130-panel/spec.md\n' >"$T_TMP/brief-pub.md"
spawn() { bash "$T_SCRIPTS/spawn-claude.sh" "$@" 2>&1; }

# 1.
out="$(spawn CLE-81 "$PUB" "$T_TMP/brief-priv.md" "panel spec")"; rc=$?
check "1. a private-topic brief naming csi-spl-doc/specs/... on the public repo -> refused" [ "$rc" -ne 0 ]
has "1. ... by the realm gate" "REFUSED (spec 129 G1): CLE-81 comes from a private workspace's topic" "$out"
hasnt "1. ... no worktree planned" "PLAN worktree   add" "$out"
hasnt "1. ... the workspace is never printed" "$ws" "$out"

# 2.
out="$(SPAWN_LANE_TOPIC="dispatch-${topic:0:8}" spawn CLE-82 "$PUB" "$T_TMP/brief-pub.md" "panel spec")"; rc=$?
check "2. SPAWN_LANE_TOPIC of a private topic, neutral brief -> refused" [ "$rc" -ne 0 ]
has "2. ... by the realm gate" "REFUSED (spec 129 G1)" "$out"

# 3. CONTROL
out="$(spawn CLE-83 "$PUB" "$T_TMP/brief-pub.md" "panel spec")"; rc=$?
eq "3. CONTROL: no private topic -> spawned (rc 0)" 0 "$rc"
has "3. ... realm=public" "PLAN realm      realm=public -> ${SPOOL_ROOT}/CLE-83/lane.realm" "$out"
has "3. ... worktree planned" "PLAN worktree   add ${PUB}-wt/CLE-83" "$out"

# 4.
out="$(spawn CLE-84 "$PRIV" "$T_TMP/brief-priv.md" "panel spec")"; rc=$?
eq "4. a private lane on its private checkout -> spawned (rc 0)" 0 "$rc"
has "4. ... realm=private, the workspace kept out of the plan" "PLAN realm      realm=private -> ${SPOOL_ROOT}/CLE-84/lane.realm" "$out"
has "4. ... worktree of the private repo planned" "PLAN worktree   add ${PRIV}-wt/CLE-84" "$out"
has "4. ... the hub row's scope says only realm=private" "--scope 'realm=private'" "$out"
hasnt "4. ... the workspace is never printed" "$ws" "$out"

# 5.
git -C "$PUB" worktree add -q -b CLE-85-x "$PUB-wt/CLE-85" origin/master 2>/dev/null
out="$(spawn CLE-85 "$PRIV" "$T_TMP/brief-pub.md" "panel spec")"; rc=$?
check "5. a private checkout for an id holding a public worktree -> refused" [ "$rc" -ne 0 ]
has "5. ... names the held worktree" "already holds a worktree of the public repository (${PUB}-wt/CLE-85)" "$out"

# 6.
mkdir -p "$SPOOL_ROOT/CLE-86"; printf 'realm=private:%s\n' "$ws" >"$SPOOL_ROOT/CLE-86/lane.realm"
out="$(spawn CLE-86 "$PUB" "$T_TMP/brief-pub.md" "panel spec")"; rc=$?
check "6. a lane recorded private, respawned with a neutral brief on the public repo -> refused" [ "$rc" -ne 0 ]

# 7.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$SPOOL_PRIVATE_REALMS"
  out="$(spawn CLE-87 "$PUB" "$T_TMP/brief-pub.md" "panel spec")"; rc=$?
  chmod 0640 "$SPOOL_PRIVATE_REALMS"
  check "7. an unreadable private list -> refused" [ "$rc" -ne 0 ]
  has "7. ... says why" "cannot be read" "$out"
fi

# 8.
out="$(SPOOL_PRIVATE_REALMS="$T_TMP/none.conf" spawn CLE-88 "$PUB" "$T_TMP/brief-priv.md" "panel spec")"; rc=$?
eq "8. no private list on the box -> spawned as public (rc 0)" 0 "$rc"
has "8. ... realm=public" "PLAN realm      realm=public" "$out"

t_done
