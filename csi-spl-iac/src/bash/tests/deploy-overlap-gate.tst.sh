#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: perf round 4, C6 - the deploy workflows overlap the BUILD with the
# test suite and gate only the irreversible steps. What must still hold:
#   hub (20)
#     1. deploy needs test and runs only on test success (the mint, the
#        migrations and the roll live in deploy); prebuild failure never skips
#        it (!cancelled(), prebuild continue-on-error)
#     2. prebuild never mints (no DRY_RUN=0) and pushes only
#        ci-<sha>-v<version> tags, never the release tag itself
#     3. deploy promotes that exact tag (tags add) and still falls back to its
#        own build + push
#     4. verify still needs test success; deploy sets up Go even when the
#        image was promoted (do_spl_db_bootstrap builds spool, run 37071957656)
#   WUI (30)
#     5. the "Wait for the suite" gate sits before the mint, and every step
#        that claims a tag or touches the site comes after it
#     6. the gate polls the real test job name, and passes only when it is green
#     7. the bundle is generated again when the mint differs from the guess
#     8. starved is not red (c-333): a test job the hosted pool never ran
#        makes the leg run the suite itself (green passes, red fails); 21
#        re-dispatches a run lost only to the hosted queue and does not count
#        on an in-flight run that already lost a job, but a suite that ran red
#        still stops it
#   CONTROLS: a hub deploy that loses `needs.test.result == 'success'`, a
#   prebuild that pushes the release tag, and a WUI gate moved after the
#   mint are each reported.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
W="$APP_ROOT/.github/workflows"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# hub_problems <wf file> -> one line per broken rule (empty = ok)
hub_problems() {
  python3 - "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); j = wf["jobs"]; bad = []
d = j["deploy"]; needs = d.get("needs") or []
needs = [needs] if isinstance(needs, str) else needs
cond = str(d.get("if", ""))
if "test" not in needs: bad.append("deploy does not need test")
if "needs.test.result == 'success'" not in cond: bad.append("deploy if: lacks needs.test.result == 'success'")
if "!cancelled()" not in cond: bad.append("deploy if: lacks !cancelled() (a failed prebuild would skip it)")
p = j.get("prebuild")
if not p:
    bad.append("no prebuild job")
else:
    if p.get("continue-on-error") is not True: bad.append("prebuild is not continue-on-error")
    if "test" in str(p.get("needs", "")): bad.append("prebuild waits for test (no overlap)")
    body = "\n".join(str(s.get("run", "")) for s in p["steps"])
    if "DRY_RUN=0" in body: bad.append("prebuild runs something with DRY_RUN=0 (a mint or a release-tag push)")
    if 'pre="${ref%:*}:ci-${GITHUB_SHA}-v${img##*:}"' not in body: bad.append("prebuild does not push ci-<sha>-v<version>")
    if body.count("docker push") != 1 or 'docker push -q "$pre"' not in body: bad.append("prebuild pushes something other than the ci- tag")
steps = d["steps"]; ids = [s.get("id") for s in steps]
img = steps[ids.index("img")]["run"]
# the prebuilt copy is named by the plain version it baked; the minted tag
# may be the release key X.Y.Z-c<N> past 9.9.9
if 'pre="${IMAGE_REF%:*}:ci-${GITHUB_SHA}-v${VERSION}"' not in img or 'docker tags add "$pre" "$IMAGE_REF"' not in img:
    bad.append("deploy does not promote ci-<sha>-v<minted version>")
if not any("do_build_push_hub_image" in str(s.get("run", "")) for s in steps): bad.append("deploy lost its own build + push fallback")
if ids.index("ver") > ids.index("img"): bad.append("deploy reads the registry before the mint")
# the migrate step builds spool whether or not the image was promoted (run 37071957656)
go = [s for s in steps if "actions/setup-go" in str(s.get("uses", ""))]
if not go or "steps.img.outputs.exists" in str(go[0].get("if", "")): bad.append("deploy's setup-go is skipped when the image exists, but do_spl_db_bootstrap still builds spool")
if "needs.test.result == 'success'" not in str(j["verify"].get("if", "")): bad.append("verify if: lacks needs.test.result == 'success'")
print("\n".join(bad))
PY
}

# wui_problems <wf file> -> one line per broken rule (empty = ok)
wui_problems() {
  python3 - "$1" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); j = wf["jobs"]; bad = []
test_name = j["test"]["name"]
steps = j["deploy"]["steps"]; names = [s.get("name", "") for s in steps]
gate = [i for i, n in enumerate(names) if n.startswith("Wait for the suite")]
if len(gate) != 1:
    print("no single 'Wait for the suite' step"); sys.exit()
g = gate[0]; st = steps[g]; run = st["run"]
if st.get("env", {}).get("TEST_JOB") != test_name: bad.append(f"gate polls '{st.get('env', {}).get('TEST_JOB')}', the test job is '{test_name}'")
if '"completed success") echo "test job green"; exit 0' not in run: bad.append("gate does not pass only on 'completed success'")
if st.get("if") or st.get("continue-on-error"): bad.append("gate is conditional or continue-on-error")
for i, s in enumerate(steps):
    if s.get("id") == "ver" or "firebase-tools" in str(s.get("run", "")) or "Authenticate" in s.get("name", "") \
       or "wait-for-hub-version" in str(s.get("run", "")):
        if i < g: bad.append(f"'{s.get('name') or s.get('id')}' runs before the suite gate")
again = [s for s in steps if "steps.ver.outputs.version != steps.pre.outputs.version" in str(s.get("if", ""))]
if not again or "pnpm run generate" not in again[0].get("run", ""): bad.append("no generate-again when the mint differs from the prediction")
print("\n".join(bad))
PY
}

for f in "$W/20_hub-build-deploy.yml" "$W/30_wui-build-deploy.yml"; do
  python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f" && pass "$(basename "$f") parses" || fail "$(basename "$f") is not valid yaml"
done

p=$(hub_problems "$W/20_hub-build-deploy.yml")
[[ -z "$p" ]] && pass "20: the build overlaps the suite; mint, migrate and roll stay behind it; ci- tag only, promoted or rebuilt" \
  || fail "20: $(tr '\n' '|' <<<"$p")"
p=$(wui_problems "$W/30_wui-build-deploy.yml")
[[ -z "$p" ]] && pass "30: generate overlaps the suite; mint, auth, hub wait and firebase deploy stay behind the gate" \
  || fail "30: $(tr '\n' '|' <<<"$p")"

# --- starved is not red (c-333): the real step scripts, against a stub gh ------
# step_run <wf file> <job> <step-name prefix> -> that step's run: script
step_run() {
  python3 - "$@" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
print(next(s["run"] for s in wf["jobs"][sys.argv[2]]["steps"] if s.get("name", "").startswith(sys.argv[3])))
PY
}
# the stub gh: `api <path>` and `run list --workflow=<wf>` read $FIX/<key>.json
# and apply --jq with jq; `workflow run <wf>` is recorded in $FIX/dispatched
stub gh '
jqf="."; args=("$@"); key=""
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == --jq ]] && jqf="${args[i+1]}"; done
case "$1 $2" in
  "workflow run") echo "$3" >> "$FIX/dispatched"; exit 0 ;;
  "run list") for a in "$@"; do [[ "$a" == --workflow=* ]] && key="list-${a#--workflow=}"; done ;;
  api*) [[ "$2" =~ /jobs/([0-9]+)/logs$ ]] && { cat "$FIX/logs-${BASH_REMATCH[1]}.txt" 2>/dev/null; exit; }
        key="$(sed -E "s#.*/runs/([0-9]+)/jobs.*#jobs-\1#" <<<"$2")" ;;
esac
[[ -f "$FIX/$key.json" ]] || exit 1
jq -r "$jqf" "$FIX/$key.json"'
stub sleep 'exit 0'
stub pnpm 'echo "pnpm $*" >> "$FIX/pnpm"; exit "${PNPM_RC:-0}"'
export FIX="$T/fix"
gate="$(step_run "$W/30_wui-build-deploy.yml" deploy "Wait for the suite")"
# gate_case <test job status> <conclusion|null> <pnpm rc> -> "<exit> <pnpm calls>"
gate_case() {
  rm -rf "$FIX" "$T/wd"; mkdir -p "$FIX" "$T/wd/csi-spl-wui"
  printf '{"jobs":[{"name":"WUI unit tests + typecheck","status":"%s","conclusion":%s}]}\n' "$1" "$2" > "$FIX/jobs-42.json"
  (cd "$T/wd" && PATH="$T/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=42 TEST_JOB="WUI unit tests + typecheck" PNPM_RC="$3" \
    bash -c "$gate" >/dev/null 2>&1); echo "$? $(cat "$FIX/pnpm" 2>/dev/null | wc -l)"
}
[[ "$(gate_case completed '"success"' 0)" == "0 0" ]] && pass "30 gate: a green test job passes, no suite in the leg" || fail "30 gate: green test job -> $(gate_case completed '"success"' 0)"
[[ "$(gate_case completed '"failure"' 0)" == "1 0" ]] && pass "30 gate: a red test job fails the leg, no retry" || fail "30 gate: red test job -> $(gate_case completed '"failure"' 0)"
[[ "$(gate_case completed '"cancelled"' 0)" == "0 2" ]] && pass "30 gate: a test job cancelled unrun (job 111944656358) -> the leg runs unit + typecheck, green passes" || fail "30 gate: cancelled test job -> $(gate_case completed '"cancelled"' 0)"
[[ "$(gate_case queued null 0)" == "0 2" ]] && pass "30 gate: a test job still queued -> the leg runs the suite itself" || fail "30 gate: queued test job -> $(gate_case queued null 0)"
[[ "$(gate_case completed '"timed_out"' 0)" == "1 0" ]] && pass "CONTROL: 30 gate: a timed-out test job fails the leg, no fallback" || fail "CONTROL: timed_out test job -> $(gate_case completed '"timed_out"' 0)"
[[ "$(gate_case completed '"neutral"' 0)" == "1 0" ]] && pass "CONTROL: 30 gate: only cancelled/skipped/queued fall back (neutral fails)" || fail "CONTROL: neutral test job -> $(gate_case completed '"neutral"' 0)"
[[ "$(gate_case completed '"cancelled"' 1)" == "1 1" ]] && pass "CONTROL: 30 gate: a red suite in the leg still fails it (never ships a red tree)" || fail "CONTROL: red inline suite -> $(gate_case completed '"cancelled"' 1)"

nw="$(python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["jobs"]["newest"]["steps"][-1]["env"]["DEPLOY_RESULT"])' "$W/30_wui-build-deploy.yml")"
[[ "$nw" == *"needs.plan.result == 'success'"*"'cancelled'"* ]] && pass "30 newest: a plan the hosted pool never ran counts as cancelled (dispatches), not skipped" \
  || fail "30 newest: DEPLOY_RESULT '$nw' reads a starved plan as skipped"

catch="$(step_run "$W/21_hub-deploy-catchup.yml" catchup "Dispatch the lagging deploys")"
# catch_case <list json> [<run id> <jobs json>]... -> what 21 dispatched for the hub
catch_case() {
  rm -rf "$FIX"; mkdir -p "$FIX"; echo "$1" > "$FIX/list-20_hub-build-deploy.yml.json"; shift
  while (($#)); do echo "$2" > "$FIX/jobs-$1.json"; shift 2; done
  PATH="$T/bin:$PATH" GITHUB_REPOSITORY=o/r HUB=true WUI=false SHA=0123456789abcdef bash -c "$catch" >/dev/null 2>&1
  cat "$FIX/dispatched" 2>/dev/null || echo none
}
# the 37363944858 shape: suite + prebuild never acquired, deploy skipped, run failure
J_STARVED='{"jobs":[{"name":"Determine deploy targets","conclusion":"success","runner_name":"GitHub Actions 1"},{"name":"Hub suite (run-all-tests.sh)","conclusion":"cancelled","runner_name":null},{"name":"Deploy hub","conclusion":"skipped","runner_name":null}]}'
J_RED='{"jobs":[{"id":91,"name":"Hub suite (run-all-tests.sh)","conclusion":"failure","runner_name":"GitHub Actions 2"}]}'
J_LOST='{"jobs":[{"id":92,"name":"Hub suite (run-all-tests.sh)","conclusion":"failure","runner_name":"GitHub Actions 4"}]}'
J_OK='{"jobs":[{"name":"Hub suite (run-all-tests.sh)","conclusion":null,"runner_name":"GitHub Actions 3"}]}'
[[ "$(catch_case '[{"databaseId":7,"status":"completed","conclusion":"failure"}]' 7 "$J_STARVED")" == 20_hub-build-deploy.yml ]] \
  && pass "21: a run lost only to the hosted queue is starved, not broken -> dispatches 20" || fail "21: starved run did not dispatch"
lost_case() {  # the 37375283653 shape: the suite's runner died under it
  catch_case '[{"databaseId":7,"status":"completed","conclusion":"failure"}]' 7 "$J_LOST" >/dev/null
  printf '%s\n' 'ok   store tests' '##[error]The runner has received a shutdown signal. This can happen when the runner service is stopped' > "$FIX/logs-92.txt"
  PATH="$T/bin:$PATH" GITHUB_REPOSITORY=o/r HUB=true WUI=false SHA=0123456789abcdef bash -c "$catch" >/dev/null 2>&1
  cat "$FIX/dispatched" 2>/dev/null || echo none
}
red_case() {
  catch_case '[{"databaseId":7,"status":"completed","conclusion":"failure"}]' 7 "$J_RED" >/dev/null
  printf '%s\n' 'not ok 3 - store: tenant isolation' '##[error]Process completed with exit code 1.' > "$FIX/logs-91.txt"
  PATH="$T/bin:$PATH" GITHUB_REPOSITORY=o/r HUB=true WUI=false SHA=0123456789abcdef bash -c "$catch" >/dev/null 2>&1
  cat "$FIX/dispatched" 2>/dev/null || echo none
}
[[ "$(lost_case)" == 20_hub-build-deploy.yml ]] \
  && pass "21: a suite whose runner got a shutdown signal (run 37375283653) is starved -> dispatches 20" || fail "21: runner loss read as broken"
[[ "$(red_case)" == none ]] \
  && pass "CONTROL: 21: a suite that ran and went red is broken -> no dispatch" || fail "CONTROL: 21 dispatched over a red suite"
[[ "$(catch_case '[{"databaseId":8,"status":"in_progress","conclusion":null},{"databaseId":7,"status":"completed","conclusion":"success"}]' 8 "$J_STARVED")" == 20_hub-build-deploy.yml ]] \
  && pass "21: an in-flight run that already lost a job is not counted on -> dispatches 20" || fail "21: doomed in-flight run still held the dispatch back"
[[ "$(catch_case '[{"databaseId":8,"status":"in_progress","conclusion":null},{"databaseId":7,"status":"completed","conclusion":"success"}]' 8 "$J_OK")" == none ]] \
  && pass "CONTROL: 21: a healthy in-flight run still holds the dispatch back" || fail "CONTROL: 21 dispatched beside a healthy run"

# --- controls ------------------------------------------------------------------
python3 - "$W/20_hub-build-deploy.yml" "$T/h1.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(s.replace("!cancelled() && needs.test.result == 'success' && ", "!cancelled() && ", 1))
PY
[[ -n "$(hub_problems "$T/h1.yml")" ]] && pass "CONTROL: a hub deploy no longer gated on the suite is reported" \
  || fail "CONTROL: an ungated hub deploy passed"

python3 - "$W/20_hub-build-deploy.yml" "$T/h2.yml" <<'PY'
import sys
s = open(sys.argv[1]).read()
open(sys.argv[2], "w").write(s.replace(':ci-${GITHUB_SHA}-v${img##*:}"', ':${img##*:}"', 1))
PY
[[ -n "$(hub_problems "$T/h2.yml")" ]] && pass "CONTROL: a prebuild that pushes the release tag is reported" \
  || fail "CONTROL: a prebuild pushing the release tag passed"

python3 - "$W/30_wui-build-deploy.yml" "$T/w1.yml" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1])); st = wf["jobs"]["deploy"]["steps"]
g = next(i for i, s in enumerate(st) if s.get("name", "").startswith("Wait for the suite"))
gate = st.pop(g); v = next(i for i, s in enumerate(st) if s.get("id") == "ver"); st.insert(v + 1, gate)
yaml.safe_dump(wf, open(sys.argv[2], "w"), sort_keys=False)
PY
[[ -n "$(wui_problems "$T/w1.yml")" ]] && pass "CONTROL: a WUI gate moved after the mint is reported" \
  || fail "CONTROL: a WUI gate after the mint passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
