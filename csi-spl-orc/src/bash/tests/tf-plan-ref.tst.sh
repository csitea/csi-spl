#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: make do-tf-plan PLAN_REF=<ref> (do_tf_plan_ref, SPL-2602) plans
#   another ref's tree through the tf-runner and only plans. Hermetic: a
#   throwaway git repo stands in for the mounted checkout, docker is a stub
#   that records each exec and reads the exported tree it is pointed at.
#   1. export: the exec runs ./run -a do_tf_plan in <root>/.tf-plan-ref/
#      <sha12>.<env>.<step>.<pid>/csi-spl-iac, and that tree holds the REF's
#      terraform and tfvars, not the checkout's
#   2. cleanup: the scratch dir is gone after a clean run AND after a failed
#      one (the stub also leaves a run dir inside it, as terraform would)
#   3. the checkout's HEAD, index and tracked files are unchanged
#   4. ACTION=apply / destroy / provision -> refused, docker never called
#   5. ENV=prd -> refused until a dev plan of the same sha + step exited 0;
#      a failed dev plan leaves no marker
#   6. a checkout that does not ignore .tf-plan-ref/ -> refused, nothing made
#   7. an unknown ref / a step the ref lacks -> refused; origin/<ref> resolves
#   8. the mount is found from `docker inspect` and mapped into the container
#   9. make: do-tf-plan with PLAN_REF routes to do_tf_plan_ref; every apply
#      target refuses while PLAN_REF is set
#   CONTROLS (red): each check is run once on a planted bad state (a leftover
#   scratch dir, a dirtied tracked file, a planted marker, an ACTION=plan run
#   that IS executed, make without PLAN_REF) and must say so.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
STEP=070-x-test

# ---- a checkout with master and a review branch ------------------------------
mk_repo() { # <dir> <ignore 0|1>
  local r="$1"
  git init -q -b master "$r"
  mkdir -p "$r/csi-spl-iac/src/terraform/$STEP" "$r/csi-spl-cnf/csi-spl/dev/tf" "$r/csi-spl-cnf/csi-spl/prd/tf"
  echo master >"$r/csi-spl-iac/src/terraform/$STEP/main.tf"
  for e in dev prd; do echo "v = \"master-$e\"" >"$r/csi-spl-cnf/csi-spl/$e/tf/$STEP.vars.tfvars"; done
  [[ "$2" == 1 ]] && printf '/.tf-plan-ref/\n' >"$r/.gitignore" || printf 'x\n' >"$r/.gitignore"
  git -C "$r" add -A && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$r" checkout -qb review/b
  echo branch >"$r/csi-spl-iac/src/terraform/$STEP/main.tf"
  echo 'v = "branch-dev"' >"$r/csi-spl-cnf/csi-spl/dev/tf/$STEP.vars.tfvars"
  git -C "$r" -c user.name=t -c user.email=t@t commit -qam branch
  git -C "$r" checkout -qb review/fails master
  echo fails >"$r/csi-spl-iac/src/terraform/$STEP/main.tf"
  git -C "$r" -c user.name=t -c user.email=t@t commit -qam fails
  git -C "$r" checkout -q master
  git -C "$r" update-ref refs/remotes/origin/review/remote-only review/b
}
ROOT="$T/root"; mk_repo "$ROOT" 1
NOIGN="$T/noign"; mk_repo "$NOIGN" 0
BR_SHA=$(git -C "$ROOT" rev-parse review/b)
FAIL_SHA=$(git -C "$ROOT" rev-parse review/fails)
HEAD0=$(git -C "$ROOT" rev-parse HEAD)

# ---- docker stub ---------------------------------------------------------------
# exec: logs "EXEC <con> W=<-w dir> ORG= APP= ENV= STEP= ACTION= | <args>" and
# "TREE <main.tf> | <tfvars>" read from the exported tree (CON_MAP maps the
# container root back to the host root), makes a run dir in it, exits STUB_RC.
# inspect: prints MOUNTS_FIXTURE.
mkdir -p "$T/stub"
cat >"$T/stub/docker" <<'EOF'
#!/bin/bash
case "$1" in
  inspect) cat "$MOUNTS_FIXTURE"; exit 0 ;;
  exec) shift ;;
  *) echo "UNEXPECTED docker $*" >>"$DOCKER_LOG"; exit 1 ;;
esac
declare -A kv=(); w=
while :; do
  case "$1" in
    -e) [[ "$2" == *=* ]] && kv[${2%%=*}]=${2#*=}; shift 2 ;;
    -w) w=$2; shift 2 ;;
    *) break ;;
  esac
done
con=$1; shift
echo "EXEC $con W=$w ORG=${kv[ORG]:-} APP=${kv[APP]:-} ENV=${kv[ENV]:-} STEP=${kv[STEP]:-} ACTION=${kv[ACTION]:-} | $*" >>"$DOCKER_LOG"
h="$w"; [[ -n "${CON_MAP:-}" ]] && h="${w/#${CON_MAP%%|*}/${CON_MAP#*|}}"
echo "TREE $(cat "$h/src/terraform/${kv[STEP]}/main.tf" 2>&1) | $(cat "$h/../csi-spl-cnf/csi-spl/${kv[ENV]}/tf/${kv[STEP]}.vars.tfvars" 2>&1)" >>"$DOCKER_LOG"
mkdir -p "$h/bin/csi/spl/${kv[ENV]}/${kv[STEP]}" "$h/dat/log"
exit "${STUB_RC:-0}"
EOF
chmod +x "$T/stub/docker"

run_action() { # env assignments...
  : >"$T/docker.log"
  env DOCKER_LOG="$T/docker.log" PATH="$T/stub:$PATH" TF_PLAN_REF_ROOT="$ROOT" \
    TF_PLAN_REF_STATE="$T/state" CON_TF_RUNNER=con-test-tf-runner MOUNTS_FIXTURE=/dev/null "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "'"$ORC"'/src/bash/run/tf-plan-ref.func.sh"
    do_tf_plan_ref' 2>&1
}
calls() { grep -c '^EXEC' "$T/docker.log"; }

# check functions: each prints nothing when the state is good
chk_clean() { [[ ! -e "$1/.tf-plan-ref" ]] || echo "scratch left: $(cd "$1" && find .tf-plan-ref -maxdepth 1 | tr '\n' ' ')"; }
chk_untouched() {
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$HEAD0" ]] || echo "HEAD moved"
  [[ -z "$(git -C "$ROOT" status --porcelain)" ]] || echo "status: $(git -C "$ROOT" status --porcelain | tr '\n' ' ')"
  [[ "$(cat "$ROOT/csi-spl-iac/src/terraform/$STEP/main.tf")" == master ]] || echo "main.tf changed"
}
chk_no_marker() { [[ ! -e "$T/state/$1.$STEP.dev.ok" ]] || echo "marker for ${1:0:12} exists"; }

# 5a. prd before any dev plan
out=$(run_action PLAN_REF=review/b ENV=prd STEP=$STEP); rc=$?
[[ $rc -ne 0 && "$out" == *"no clean dev plan"* && $(calls) -eq 0 ]] && pass "prd before a dev plan -> refused, no exec" \
  || fail "prd before dev: rc=$rc calls=$(calls) $(tail -2 <<<"$out")"

# 1. + 2. + 3. dev plan of the branch
out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP); rc=$?
want_w="$ROOT/.tf-plan-ref/${BR_SHA:0:12}.dev.$STEP."
if [[ $rc -eq 0 && $(calls) -eq 1 ]] && grep -q "^EXEC con-test-tf-runner W=${want_w}[0-9]*/csi-spl-iac ORG=csi APP=spl ENV=dev STEP=$STEP ACTION=provision | ./run -a do_tf_plan\$" "$T/docker.log"; then
  pass "dev: one exec of ./run -a do_tf_plan in .tf-plan-ref/<sha12>.dev.<step>.<pid>/csi-spl-iac"
else
  fail "dev exec: rc=$rc $(cat "$T/docker.log") $(tail -2 <<<"$out")"
fi
grep -qx 'TREE branch | v = "branch-dev"' "$T/docker.log" && pass "the exported tree holds the ref's terraform and tfvars" \
  || fail "exported tree: $(grep TREE "$T/docker.log")"
[[ "$out" == *"TF_PLAN_REF dev $STEP sha=$BR_SHA ref=review/b rc=0"* ]] && pass "verdict line names the sha" || fail "verdict: $(tail -1 <<<"$out")"
p=$(chk_clean "$ROOT"); [[ -z "$p" ]] && pass "scratch dir removed after a clean run" || fail "$p"
p=$(chk_untouched); [[ -z "$p" ]] && pass "checkout untouched (HEAD, status, tracked file)" || fail "$p"
[[ -f "$T/state/$BR_SHA.$STEP.dev.ok" ]] && pass "clean dev plan leaves the prd marker" || fail "no marker after a clean dev plan"

# 5b. prd of the same sha now runs
out=$(run_action PLAN_REF=review/b ENV=prd STEP=$STEP); rc=$?
[[ $rc -eq 0 && $(calls) -eq 1 ]] && grep -q "ENV=prd STEP=$STEP ACTION=provision | ./run -a do_tf_plan\$" "$T/docker.log" \
  && pass "prd after a clean dev plan of the same sha -> plans" || fail "prd after dev: rc=$rc $(cat "$T/docker.log")"
grep -qx 'TREE branch | v = "master-prd"' "$T/docker.log" && pass "prd reads the ref's prd tfvars" || fail "prd tree: $(grep TREE "$T/docker.log")"

# 2. + 5c. a failing dev plan
out=$(run_action PLAN_REF=review/fails ENV=dev STEP=$STEP STUB_RC=1); rc=$?
[[ $rc -ne 0 && $(calls) -eq 1 && "$out" == *"rc=1"* ]] && pass "failed plan -> non-zero" || fail "failed plan: rc=$rc"
p=$(chk_clean "$ROOT"); [[ -z "$p" ]] && pass "scratch dir removed after a failed run" || fail "after failure: $p"
p=$(chk_no_marker "$FAIL_SHA"); [[ -z "$p" ]] && pass "failed dev plan leaves no marker" || fail "$p"
out=$(run_action PLAN_REF=review/fails ENV=prd STEP=$STEP); rc=$?
[[ $rc -ne 0 && $(calls) -eq 0 ]] && pass "prd after a FAILED dev plan -> refused" || fail "prd after failed dev: rc=$rc"
p=$(chk_untouched); [[ -z "$p" ]] && pass "checkout untouched after the failure" || fail "$p"

# 4. apply refused
for a in apply destroy provision; do
  out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP ACTION=$a); rc=$?
  [[ $rc -ne 0 && "$out" == *"plan-only"* && $(calls) -eq 0 ]] && pass "ACTION=$a -> refused, no exec" || fail "ACTION=$a: rc=$rc calls=$(calls)"
done
out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP ACTION=plan); rc=$?
[[ $rc -eq 0 && $(calls) -eq 1 ]] && pass "CONTROL: ACTION=plan is executed (the refusal is ACTION-specific)" || fail "control ACTION=plan: rc=$rc"

# 6. not ignored
out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP TF_PLAN_REF_ROOT="$NOIGN"); rc=$?
[[ $rc -ne 0 && "$out" == *"not git-ignored"* && $(calls) -eq 0 && ! -e "$NOIGN/.tf-plan-ref" ]] \
  && pass "checkout without the ignore line -> refused, nothing created" || fail "not ignored: rc=$rc calls=$(calls)"

# 7. refs and steps
for bad in "PLAN_REF=no/such-ref" "PLAN_REF=--upload-pack=x" "PLAN_REF=" "STEP=999-not-there" "STEP=../etc" "ENV=qa"; do
  out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP $bad); rc=$?
  [[ $rc -ne 0 && $(calls) -eq 0 ]] && pass "refused: $bad" || fail "not refused: $bad (rc=$rc calls=$(calls))"
done
p=$(chk_clean "$ROOT"); [[ -z "$p" ]] && pass "no scratch left by the refusals" || fail "$p"
out=$(run_action PLAN_REF=review/remote-only ENV=dev STEP=$STEP); rc=$?
[[ $rc -eq 0 && "$out" == *"sha=$BR_SHA"* ]] && pass "a remote-only branch resolves as origin/<ref>" || fail "origin/<ref>: rc=$rc $(tail -1 <<<"$out")"
out=$(run_action PLAN_REF="${BR_SHA:0:10}" ENV=dev STEP=$STEP); rc=$?
[[ $rc -eq 0 && "$out" == *"sha=$BR_SHA"* ]] && pass "a short sha resolves" || fail "short sha: rc=$rc"

# 8. mount from docker inspect
printf '%s\n' "$T|/home/<APPUSR>/.gcp" "$ROOT|/home/<APPUSR>$ROOT" "$ROOT|/con/root" >"$T/mounts"
out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP TF_PLAN_REF_ROOT= MOUNTS_FIXTURE="$T/mounts" CON_MAP="/con/root|$ROOT"); rc=$?
[[ $rc -eq 0 ]] && grep -q "W=/con/root/.tf-plan-ref/${BR_SHA:0:12}.dev.$STEP.[0-9]*/csi-spl-iac " "$T/docker.log" \
  && grep -qx 'TREE branch | v = "branch-dev"' "$T/docker.log" \
  && pass "mount read from docker inspect, -w mapped into the container root" || fail "mount: rc=$rc $(cat "$T/docker.log") $(tail -2 <<<"$out")"
out=$(run_action PLAN_REF=review/b ENV=dev STEP=$STEP TF_PLAN_REF_ROOT= MOUNTS_FIXTURE=/dev/null); rc=$?
[[ $rc -ne 0 && "$out" == *"cannot read the mounts"* && $(calls) -eq 0 ]] && pass "no mount found -> refused" || fail "no mount: rc=$rc"

# CONTROLS: each check flags a planted bad state
mkdir -p "$ROOT/.tf-plan-ref/planted"
[[ -n "$(chk_clean "$ROOT")" ]] && pass "CONTROL: a leftover scratch dir is flagged" || fail "control: leftover not flagged"
rm -rf "$ROOT/.tf-plan-ref"
echo dirty >"$ROOT/csi-spl-iac/src/terraform/$STEP/main.tf"
[[ -n "$(chk_untouched)" ]] && pass "CONTROL: a dirtied tracked file is flagged" || fail "control: dirty not flagged"
git -C "$ROOT" checkout -q -- .
mkdir -p "$T/state" && : >"$T/state/$FAIL_SHA.$STEP.dev.ok"
[[ -n "$(chk_no_marker "$FAIL_SHA")" ]] && pass "CONTROL: a planted marker is flagged" || fail "control: marker not flagged"
out=$(run_action PLAN_REF=review/fails ENV=prd STEP=$STEP); rc=$?
[[ $rc -eq 0 && $(calls) -eq 1 ]] && pass "CONTROL: with the marker planted, prd of that sha runs (the gate reads the marker)" || fail "control prd marker: rc=$rc"
rm -f "$T/state/$FAIL_SHA.$STEP.dev.ok"

# 9. make routing
cd "$ORC" || exit 1
mk() { GITHUB_TOKEN=x make --no-print-directory "$@" 2>&1; }
out=$(PLAN_REF=review/b mk -n do-tf-plan ENV=dev STEP=$STEP)
[[ "$out" == *"PLAN_REF='review/b' ./run -a do_tf_plan_ref"* && "$out" != *"docker exec"* ]] \
  && pass "make do-tf-plan PLAN_REF=... -> do_tf_plan_ref, no direct docker exec" || fail "make routing: $(tail -3 <<<"$out")"
out=$(mk -n do-tf-plan ENV=dev STEP=$STEP)
[[ "$out" == *"docker exec"* && "$out" != *do_tf_plan_ref* ]] && pass "CONTROL: without PLAN_REF, do-tf-plan is the tf-runner exec" || fail "control routing: $(tail -3 <<<"$out")"
for t in do-provision do-tf-apply-target do-deprovision do-tf-destroy-target do-tf-replace-target do-tf-import do-tf-state-remove do-tf-state-push do-provision-local; do
  out=$(PLAN_REF=review/b mk "$t" ENV=dev STEP=$STEP TARGET=x ID=x TFSTATE_FILE=x); rc=$?
  [[ $rc -ne 0 && "$out" == *"REFUSED: PLAN_REF=review/b is plan-only"* && "$out" != *"docker exec"* ]] \
    && pass "make $t with PLAN_REF -> refused" || fail "make $t with PLAN_REF: rc=$rc $(tail -2 <<<"$out")"
done
mk no-plan-ref >/dev/null && pass "CONTROL: no-plan-ref passes without PLAN_REF" || fail "control: no-plan-ref refuses without PLAN_REF"

echo "---"
[[ $fails -eq 0 ]] && { echo "tf-plan-ref: all passed"; exit 0; }
echo "tf-plan-ref: $fails failed"; exit 1
