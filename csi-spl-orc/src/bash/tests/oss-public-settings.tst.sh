#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_oss_public_settings (spec 044 / SPL-64, CLE-35070), stubbed gh:
#          - a pull_request_target workflow, and a pull_request workflow that
#            names a self-hosted runner, are each reported (exit 1)
#          - a writable default token and a repo-level runner are reported;
#            DRY_RUN=1 changes nothing
#          - DRY_RUN=0 on a PUBLIC repo: token read-only, fork-PR approval for
#            all outside contributors, private vulnerability reporting, secret
#            scanning + push protection; exit 0
#          - the runner group must be selected-repos + selected-workflows, serve
#            this repo only, and pin every workflow to refs/heads/<default>
#          - on a PRIVATE repo the public-only checks are PENDING, not faked
#          - (spec 072 A60) no trunk ruleset reads FAIL and is only written
#            with DRY_RUN=0 AND OSS_SET_RULESET=1; a ruleset that allows
#            force-push or deletion, needs no review, misses a wf 11 check or
#            the trusted team's bypass reads FAIL; the required check names
#            match wf 11's job "gate" calling wf 10's job names
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$PROJ_ROOT/src/bash/run/oss-public-settings.func.sh" || { echo "FAIL: bash -n"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
source "$PROJ_ROOT/src/bash/run/oss-public-settings.func.sh"
WF_DIR="${WF_DIR:-$PROJ_ROOT/../.github/workflows}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
S="$T/state"; mkdir -p "$T/bin" "$S/wf"
cat >"$T/bin/gh" <<'G'
#!/usr/bin/env bash
S="$GH_STATE"; printf '%s\n' "$*" >>"$S/log"
case "$*" in
  "api repos/o/app --jq .private") cat "$S/private" ;;
  "api repos/o/app --jq .default_branch") echo master ;;
  "api repos/o/app --jq .id") echo 7 ;;
  "api repos/o/app/contents/.github/workflows?ref=master --jq .[].name") ls "$S/wf" ;;
  "api -H Accept: application/vnd.github.raw repos/o/app/contents/.github/workflows/"*) f="${4#repos/o/app/contents/.github/workflows/}"; cat "$S/wf/${f%%\?*}" ;;
  "api -X PUT repos/o/app/actions/permissions/workflow"*) echo "read false" >"$S/tok" ;;
  "api repos/o/app/actions/permissions/workflow --jq"*) cat "$S/tok" ;;
  "api -X PUT repos/o/app/actions/permissions/fork-pr-contributor-approval"*) echo all_external_contributors >"$S/fork" ;;
  "api repos/o/app/actions/permissions/fork-pr-contributor-approval --jq"*) cat "$S/fork" 2>/dev/null ;;
  "api -X PUT repos/o/app/private-vulnerability-reporting") echo true >"$S/pvr" ;;
  "api repos/o/app/private-vulnerability-reporting --jq"*) cat "$S/pvr" 2>/dev/null ;;
  "api -X PATCH repos/o/app --input -") cat >/dev/null; echo "enabled enabled" >"$S/ss" ;;
  "api repos/o/app --jq"*secret_scanning*) cat "$S/ss" 2>/dev/null || echo "disabled disabled" ;;
  "api repos/o/app/actions/runners --jq .total_count") cat "$S/runners" ;;
  "api orgs/o/actions/runner-groups --jq"*) echo 3 ;;
  "api orgs/o/actions/runner-groups/3 --jq"*selected_workflows*) grep -v '@refs/heads/master$' "$S/gwf" ;;
  "api orgs/o/actions/runner-groups/3 --jq"*) cat "$S/grp" ;;
  "api orgs/o/actions/runner-groups/3/repositories --jq"*) echo 7 ;;
  "api orgs/o/actions/runner-groups/3/runners --jq"*) echo r-01 ;;
  "api orgs/o/teams/trusted --jq .id") echo 42 ;;
  "api orgs/o/teams/"*) exit 1 ;;
  "api repos/o/app/rulesets --jq"*) [[ -s "$S/rs" ]] && echo 9 ;;
  "api repos/o/app/rulesets/9") cat "$S/rs" ;;
  "api -X POST repos/o/app/rulesets --input -"|"api -X PUT repos/o/app/rulesets/9 --input -") cat >"$S/rs" ;;
esac
exit 0
G
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH" GH_STATE="$S"
reset() { echo "$1" >"$S/private"; echo "write true" >"$S/tok"; echo "$2" >"$S/runners"; rm -f "$S/fork" "$S/pvr" "$S/ss" "$S/log" "$S/wf/"*
          printf 'on:\n  push:\njobs:\n  a:\n    runs-on: [self-hosted, x]\n' >"$S/wf/10.yml"
          printf '# the self-hosted runners are never reached from here\non:\n  pull_request:\njobs:\n  a:\n    runs-on: ubuntu-latest\n' >"$S/wf/11.yml"
          echo "selected true" >"$S/grp"; echo "o/app/.github/workflows/10.yml@refs/heads/master" >"$S/gwf"
          oss_ruleset_body trunk "" >"$S/rs"; }
act() { ( LOGF="$T/log"; : >"$LOGF"
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    source "$PROJ_ROOT/src/bash/run/oss-public-settings.func.sh"
    OSS_PUBLIC_REPO=o/app OSS_RUNNER_GROUP=g do_oss_public_settings ) >/dev/null 2>&1; }

reset false 4
act && no "dry run with gaps must exit 1" || ok "dry run reports the gaps (exit 1)"
grep -q "FAIL.*permissions: write true" "$T/log" && ok "reported: writable default token" || no "token not reported"
grep -q "FAIL.*4 self-hosted runner" "$T/log" && ok "reported: repo-level runners" || no "runners not reported"
grep -qE '^api -X' "$S/log" && no "dry run mutated" || ok "dry run mutates nothing"
grep -q '^OK .*no workflow on master reaches a self-hosted runner' "$T/log" && ok "push-only self-hosted + hosted pull_request pass" || no "clean workflows flagged"

reset false 0; printf 'on:\n  pull_request_target:\njobs:\n  a:\n    runs-on: ubuntu-latest\n' >"$S/wf/12.yml"
DRY_RUN=0 act && no "pull_request_target must fail" || ok "a pull_request_target workflow fails it"
reset false 0; printf 'on:\n  pull_request:\njobs:\n  a:\n    runs-on: [self-hosted, x]\n' >"$S/wf/13.yml"
DRY_RUN=0 act && no "pull_request on self-hosted must fail" || ok "a pull_request workflow naming self-hosted fails it"
reset false 0; echo "o/app/.github/workflows/10.yml@refs/heads/feature" >>"$S/gwf"
DRY_RUN=0 act && no "an unpinned group workflow must fail" || ok "a group workflow not pinned to master fails it"
reset false 0; echo "all false" >"$S/grp"
DRY_RUN=0 act && no "an unrestricted group must fail" || ok "a runner group without repo+workflow restriction fails it"

reset false 0
DRY_RUN=0 act && ok "apply exits 0 on a public repo" || no "apply failed: $(grep FAIL "$T/log")"
for w in "master ruleset trunk" "read-only" "approval (all outside contributors)" "private vulnerability reporting on" "push protection on" "no self-hosted runner registered" "serves o/app only" "pinned to refs/heads/master"; do
  grep -q "^OK .*$w" "$T/log" && ok "holds: $w" || no "missing: $w"; done

reset true 0
DRY_RUN=0 act && ok "private repo: exit 0 with pending checks" || no "private apply failed: $(grep FAIL "$T/log")"
grep -q PENDING-PUBLIC "$T/log" && ! grep -q 'fork-pr-contributor-approval' "$S/log" && ok "public-only checks are PENDING on a private repo, not faked" || no "pending not honest"

# --- 6. the trunk ruleset (spec 072 A60) --------------------------------------
reset false 0; rm -f "$S/rs"
act && no "no ruleset must fail" || ok "no trunk ruleset: exit 1"
grep -q "FAIL no trunk ruleset on master" "$T/log" && ok "no trunk ruleset reads FAIL" || no "missing ruleset not reported"
DRY_RUN=0 act; grep -q 'rulesets --input' "$S/log" && no "DRY_RUN=0 alone wrote the ruleset" || ok "DRY_RUN=0 without OSS_SET_RULESET writes no ruleset"
OSS_SET_RULESET=1 act; grep -q 'rulesets --input' "$S/log" && no "OSS_SET_RULESET=1 under a dry run wrote the ruleset" || ok "OSS_SET_RULESET=1 under a dry run writes nothing"
DRY_RUN=0 OSS_SET_RULESET=1 OSS_TRUSTED_TEAM=trusted act && ok "apply creates the ruleset, exit 0" || no "ruleset apply failed: $(grep FAIL "$T/log")"
grep -q '^api -X POST repos/o/app/rulesets' "$S/log" && ok "created with POST" || no "no POST"
jq -e '.bypass_actors | any(.actor_type == "Team" and .actor_id == 42) and any(.actor_type == "RepositoryRole" and .actor_id == 5)' "$S/rs" >/dev/null \
  && ok "trusted team and repo admins bypass" || no "bypass actors wrong: $(jq -c .bypass_actors "$S/rs")"
grep -q "^OK master ruleset trunk.*team trusted bypass" "$T/log" && ok "OK master ruleset printed" || no "no OK master ruleset line"
for m in 'force-push is allowed|del(.rules[] | select(.type == "non_fast_forward"))' \
         'deletion is allowed|del(.rules[] | select(.type == "deletion"))' \
         'needs no approving review|(.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count) = 0' \
         'check not required: gate / orc|del(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[3])' \
         'enforcement is evaluate|.enforcement = "evaluate"' \
         'does not target master|.conditions.ref_name.include = ["refs/heads/dev"]' \
         'repo admins|.bypass_actors = []'; do
  reset false 0; jq "${m#*|}" "$S/rs" >"$S/rs.new" && mv "$S/rs.new" "$S/rs"
  act && no "weak ruleset passed: ${m%%|*}" || { grep -q "FAIL trunk ruleset: .*${m%%|*}" "$T/log" && ok "weak ruleset reads FAIL: ${m%%|*}" || no "weak ruleset not named: ${m%%|*}"; }
done
reset false 0
OSS_TRUSTED_TEAM=trusted act && no "a ruleset without the team's bypass passed" || ok "trusted team without a bypass reads FAIL"
OSS_TRUSTED_TEAM=nobody act && no "an unknown team passed" || ok "an unknown OSS_TRUSTED_TEAM reads FAIL"
reset false 0; jq '.rules |= map(select(.type != "deletion"))' "$S/rs" >"$S/rs.new" && mv "$S/rs.new" "$S/rs"
DRY_RUN=0 OSS_SET_RULESET=1 act && grep -q '^api -X PUT repos/o/app/rulesets/9' "$S/log" && ok "apply repairs a weak ruleset with PUT" || no "weak ruleset not repaired"

# the required check names are what wf 11 -> wf 10 really report
grep -qE '^  gate:$' "$WF_DIR/11_ci-public.yml" && grep -qE '^    name: "gate"$' "$WF_DIR/11_ci-public.yml" \
  && ok "wf 11's one job is named gate" || no "wf 11 has no job named \"gate\": the ruleset's check names are stale"
# a matrix shard "<name> k/m" is reported by a job named "<name> ${{ matrix.shard }}/m"
while IFS= read -r c; do
  n="${c#gate / }"
  [[ "$n" =~ ^(.*)\ [0-9]+/([0-9]+)$ ]] && n="${BASH_REMATCH[1]} \${{ matrix.shard }}/${BASH_REMATCH[2]}"
  grep -qF "    name: \"$n\"" "$WF_DIR/10_ci-quality.yml" && ok "wf 10 reports: $c" || no "wf 10 has no job named \"$n\" (update oss_ruleset_checks)"
done < <(oss_ruleset_checks)

echo "=== oss-public-settings: $fails failure(s)"
[[ "$fails" -eq 0 ]]
