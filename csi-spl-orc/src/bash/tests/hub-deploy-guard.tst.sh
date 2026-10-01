#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: hub-deploy-guard.sh -- workflow 20's hub-input list and its
#          forward-only decision (CLE-77918: five green runs in a row all
#          "standing down" while trunk moved on, so the hub never deployed).
#   Against a SYNTHETIC repo (CI checks this one out shallow):
#     1. `paths` matches 20's push allow-list (image inputs; the cnf files and
#        the workflow files are the only extra triggers)
#     2. `changed`: iac / orc scripts / a non-hub cnf key are NOT hub inputs;
#        the Go module, the DDL, the Dockerfile, .version and the hub.image cnf
#        key ARE
#     3. `decide` against the served commit: already served / env ahead /
#        nothing new since served -> stand down; a hub input not served yet ->
#        deploy EVEN THOUGH trunk head moved on with more hub input
#     4. served unknown -> the trunk-head rule (stand down only for a newer hub
#        input on trunk)
#     5. the starvation case simulated: a busy trunk where every run's guard
#        sees a newer head. The old rule ships nothing; the new rule leaves the
#        env serving the last hub change
#     6. 20 runs this script in its guard step, and the lag check reads the
#        same list
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
G="$PROJ_ROOT/src/bash/scripts/hub-deploy-guard.sh"
WF="$APP_ROOT/.github/workflows/20_hub-build-deploy.yml"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v yq >/dev/null || { echo "SKIP: yq (mikefarah) is not installed"; exit 0; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

R="$T/repo"
git init -q -b master "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name "FirstName LastName"
mkdir -p "$R/csi-spl-cnf/csi-spl"
for f in all dev prd; do
  printf 'env:\n  hub:\n    image:\n      name: spool-hub\n      tag: 1.0.0\n      sql_src: csi-spl-rdb/src/sql/postgres/spool-hub\n    service_name: hub-%s\n  dns:\n    note: a\n' "$f" >"$R/csi-spl-cnf/csi-spl/$f.env.yaml"
done
git -C "$R" add -- csi-spl-cnf && git -C "$R" commit -qm cnf
# c <rel-path> -> commits a change to it, prints the sha
c() {
  mkdir -p "$R/$(dirname "$1")"; echo "$RANDOM" >>"$R/$1"
  git -C "$R" add -- "$1" && git -C "$R" commit -qm "$1" && git -C "$R" rev-parse HEAD
}
# y <file> <yq expr> -> commits a cnf edit, prints the sha
y() {
  yq -i "$2" "$R/csi-spl-cnf/csi-spl/$1"
  git -C "$R" add -- "csi-spl-cnf/csi-spl/$1" && git -C "$R" commit -qm "cnf $2" && git -C "$R" rev-parse HEAD
}
g() { APP_PATH="$R" bash "$G" "$@"; }
decide() { APP_PATH="$R" SHA="$1" TIP="$2" SERVED="$3" bash "$G" decide; }

C0=$(c csi-spl-api/src/go/main.go)

# --- 1. paths == 20's push allow-list ----------------------------------------
want="$(g paths | sort)"
got="$(yq -r '.on.push.paths[]' "$WF" | sed 's|/\*\*$||' |
  grep -vE '^(csi-spl-cnf/csi-spl/(all|dev|prd)\.env\.yaml|\.github/workflows/2[02]_[a-z-]+\.yml)$' | sort)"
[[ -n "$want" && "$want" == "$got" ]] && pass "1. paths == 20's push allow-list ($(wc -l <<<"$want") image inputs)" ||
  fail "1. paths and 20's allow-list differ: guard=[$want] wf=[$got]"
extra="$(yq -r '.on.push.paths[]' "$WF" | grep -cE '^csi-spl-(iac|orc|cnf)/\*\*$')"
[[ "$extra" == 0 ]] && pass "1. no whole iac/orc/cnf tree in 20's triggers" || fail "1. 20 still triggers on a whole tree ($extra)"

# --- 2. changed ---------------------------------------------------------------
chk() {  # <label> <want rc> <from> <to>
  local rc=0; g changed "$3" "$4" >/dev/null || rc=$?
  [[ "$rc" == "$2" ]] && pass "2. $1 -> rc $rc" || fail "2. $1: rc $rc, want $2"
}
a=$(git -C "$R" rev-parse HEAD); b=$(c csi-spl-iac/src/bash/run/x.func.sh);              chk "iac only is not a hub input" 1 "$a" "$b"
a=$b; b=$(c csi-spl-orc/src/bash/run/y.func.sh);                                         chk "an orc action is not a hub input" 1 "$a" "$b"
a=$b; b=$(c csi-spl-api/src/bash/tests/z.tst.sh);                                        chk "an api test script is not a hub input" 1 "$a" "$b"
a=$b; b=$(y dev.env.yaml '.env.dns.note = "b"');                                         chk "a non-hub cnf key is not a hub input" 1 "$a" "$b"
a=$b; b=$(c csi-spl-rdb/src/sql/postgres/spool-hub-roles/r.sql);                         chk "spool-hub-roles is not in the image" 1 "$a" "$b"
a=$b; b=$(c csi-spl-api/src/go/hub/h.go);                                                chk "the Go module is" 0 "$a" "$b"
a=$b; b=$(c csi-spl-rdb/src/sql/postgres/spool-hub/0099_x.sql);                          chk "the bundled DDL is" 0 "$a" "$b"
a=$b; b=$(c csi-spl-orc/src/docker/spool-hub-api/Dockerfile);                            chk "the hub Dockerfile is" 0 "$a" "$b"
a=$b; b=$(c .version);                                                                   chk ".version is" 0 "$a" "$b"
a=$b; b=$(y prd.env.yaml '.env.hub.image.tag = "2.0.0"');                                chk "cnf hub.image.tag is" 0 "$a" "$b"
a=$b; b=$(y all.env.yaml '.env.hub.service_name = "hub-x"');                             chk "cnf hub.service_name is" 0 "$a" "$b"
rc=0; g changed "$a" nope >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] && pass "2. a bad ref -> rc 2" || fail "2. bad ref rc $rc"

# --- 3. decide against the served commit --------------------------------------
H1=$(c csi-spl-api/src/go/a.go)
I1=$(c csi-spl-iac/src/bash/run/i.func.sh)
H2=$(c csi-spl-api/src/go/b.go)
I2=$(c csi-spl-orc/src/bash/run/o.func.sh)
dc() {  # <label> <want rc> <sha> <tip> <served>
  local rc=0 out; out="$(decide "$3" "$4" "$5" 2>&1)" || rc=$?
  [[ "$rc" == "$2" ]] && pass "3. $1 -> rc $rc ($(tail -1 <<<"$out"))" || fail "3. $1: rc $rc want $2: $out"
}
dc "served == sha"                                   10 "$H1" "$I2" "$H1"
dc "env ahead (served descends from sha)"            10 "$H1" "$I2" "$H2"
dc "nothing the image reads changed since served"    10 "$I1" "$I2" "$H1"
dc "unserved hub input, trunk head has MORE hub input" 0 "$H1" "$I2" "$C0"
dc "unserved hub input, trunk head == sha"            0 "$H2" "$H2" "$H1"

# --- 4. served unknown: the trunk-head rule -----------------------------------
dc "unknown served, newer hub input on trunk"        10 "$H1" "$H2" ""
dc "unknown served, only iac/orc after sha"           0 "$H2" "$I2" ""
dc "junk served value"                                0 "$H2" "$I2" "not-a-sha"
rc=0; decide nope "$I2" "" >/dev/null 2>&1 || rc=$?; [[ $rc == 2 ]] && pass "4. a bad SHA -> rc 2" || fail "4. bad SHA rc $rc"

# --- 5. the starvation case simulated -----------------------------------------
# A busy trunk: every run reaches its guard after more pushes landed and the
# trunk never goes quiet, so each run's TIP is a head newer than every run in
# the window (here an orc commit, as on 2026-10-01). Runs execute oldest first
# (the per-env deploy concurrency group); a deploy moves SERVED to its sha.
S0=$(c csi-spl-api/src/go/s0.go)
seq=("$(c csi-spl-api/src/go/s1.go)" "$(c csi-spl-iac/s2)" "$(c csi-spl-api/src/go/s3.go)" "$(c csi-spl-orc/s4)" "$(y dev.env.yaml '.env.dns.note = "c"')")
tip="$(c csi-spl-orc/s6)" last_hub="${seq[2]}"
old_deployed=0
for s in "${seq[@]}"; do
  # the old rule: stand down whenever trunk head moved on with a change under
  # csi-spl-api / -rdb / -cnf / -iac / -orc / .version (20 before CLE-77918)
  git -C "$R" diff --quiet "$s" "$tip" -- csi-spl-api csi-spl-rdb csi-spl-cnf csi-spl-iac csi-spl-orc .version && old_deployed=$((old_deployed + 1))
done
[[ "$old_deployed" == 0 ]] && pass "5. CONTROL: the old rule deploys none of the 5 runs on this trunk" ||
  fail "5. control: the old rule deployed $old_deployed run(s) -- the simulation does not reproduce the starvation"
served="$S0" deployed=0
for s in "${seq[@]}"; do
  if decide "$s" "$tip" "$served" >/dev/null 2>&1; then served="$s"; deployed=$((deployed + 1)); fi
done
[[ "$served" == "$last_hub" && "$deployed" == 2 ]] &&
  pass "5. the new rule: 2 rolls (s1, s3), the env serves the last hub change though every run saw a newer head" ||
  fail "5. new rule: served=${served:0:8} want ${last_hub:0:8}, deployed=$deployed want 2"

# --- 6. wiring -----------------------------------------------------------------
grep -q 'hub-deploy-guard.sh decide' "$WF" && pass "6. 20's guard step runs hub-deploy-guard.sh decide" ||
  fail "6. 20 does not run hub-deploy-guard.sh decide"
grep -q 'hub-deploy-guard.sh" paths' "$PROJ_ROOT/src/bash/run/check-deploy-lag.func.sh" &&
  pass "6. do_check_deploy_lag reads the same hub-input list" || fail "6. do_check_deploy_lag keeps its own hub list"

echo "fails=$fails"
[[ $fails -eq 0 ]]
