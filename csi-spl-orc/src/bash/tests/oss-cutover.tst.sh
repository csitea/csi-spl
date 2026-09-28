#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_oss_cutover (spec 044, CLE-35070) on local bare "public" and
#          "ops" repos, a shared checkout with a linked worktree, stubbed gh:
#          - fail fast on missing / identical repos, and on an ops repo that
#            is not private
#          - DRY_RUN=1 changes no remote, pushes nothing
#          - DRY_RUN=0: ops master + v-tags = public master, origin of the
#            checkout AND of its worktree now point at ops, the mirror-only
#            ruleset is created on the public repo, Actions are enabled in ops
#          - re-run is idempotent (no second ruleset)
#          - ops already AHEAD of public (the fleet pushed after the switch):
#            still succeeds and never rewinds ops
#          - diverged masters are refused, nothing forced
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$PROJ_ROOT/src/bash/run/oss-cutover.func.sh" || { echo "FAIL: bash -n"; exit 1; }
command -v git >/dev/null || { echo "SKIP: git not installed"; exit 0; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
git init -q --bare "$T/pub.git"; git init -q --bare "$T/ops.git"
git init -q -b master "$T/src"; echo a >"$T/src/f"; git -C "$T/src" add f; git -C "$T/src" commit -qm one; git -C "$T/src" tag v1.0.0
git -C "$T/src" push -q "$T/pub.git" master v1.0.0
git -C "$T/src" push -q "$T/ops.git" master
echo b >"$T/src/f"; git -C "$T/src" commit -qam two; git -C "$T/src" push -q "$T/pub.git" master
git clone -q "$T/pub.git" "$T/app"; git -C "$T/app" worktree add -q "$T/wt" -b lane
mkdir -p "$T/bin" "$T/state"
cat >"$T/bin/gh" <<'G'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  "api repos/o/app-ops --jq .private") echo "${OPS_PRIVATE:-true}" ;;
  "api repos/o/app/rulesets --jq"*) [[ -f "$GH_STATE/rs" ]] && echo 42 ;;
  "api -X POST repos/o/app/rulesets --input -") cat >"$GH_STATE/rs" ;;
esac
exit 0
G
chmod +x "$T/bin/gh"; export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_STATE="$T/state"
act() {
  ( LOGF="$T/log"
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    APP_PATH="$T/app" OSS_OPS_URL="$T/ops.git" OSS_PUBLIC_URL="$T/pub.git"
    source "$PROJ_ROOT/src/bash/run/oss-cutover.func.sh"
    do_oss_cutover ) >/dev/null 2>&1
}
pubm() { git -C "$T/pub.git" rev-parse master; }
opsm() { git -C "$T/ops.git" rev-parse master; }

OSS_PUBLIC_REPO=o/app act && no "missing ops must fail" || ok "missing OSS_OPS_REPO fails fast"
OSS_OPS_REPO=o/app OSS_PUBLIC_REPO=o/app act && no "same repo must fail" || ok "the same repo twice fails fast"
OPS_PRIVATE=false OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act && no "a non-private ops must fail" || ok "an ops repo that is not private is refused"
[[ "$(git -C "$T/app" remote get-url origin)" == "$T/pub.git" ]] && ok "the refusal switched nothing" || no "origin changed on refusal"

: >"$GH_LOG"; before=$(opsm)
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app act && ok "dry run exits 0" || no "dry run failed: $(tail -2 "$T/log")"
[[ "$(git -C "$T/app" remote get-url origin)" == "$T/pub.git" && "$(opsm)" == "$before" ]] && ok "dry run switches and pushes nothing" || no "dry run mutated"
grep -qE '^api -X (POST|PUT)' "$GH_LOG" && no "dry run called a mutating API" || ok "dry run calls no mutating API"

OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act && ok "cutover exits 0" || no "cutover failed: $(tail -3 "$T/log")"
[[ "$(opsm)" == "$(pubm)" ]] && ok "ops master = public master" || no "ops not synced"
git -C "$T/ops.git" rev-parse -q --verify refs/tags/v1.0.0 >/dev/null && ok "v-tags carried to ops" || no "tags missing"
[[ "$(git -C "$T/app" remote get-url origin)" == "$T/ops.git" ]] && ok "origin of the checkout -> ops" || no "checkout origin: $(git -C "$T/app" remote get-url origin)"
[[ "$(git -C "$T/wt" remote get-url origin)" == "$T/ops.git" ]] && ok "origin of its WORKTREE -> ops (common config)" || no "worktree origin not switched"
grep -q '"bypass_actors":\[{"actor_type":"DeployKey","bypass_mode":"always"}\]' "$T/state/rs" && grep -q '"type":"update"' "$T/state/rs" \
  && ok "public master ruleset: updates by a deploy key only" || no "ruleset body: $(cat "$T/state/rs" 2>/dev/null)"
grep -q '^api -X PUT repos/o/app-ops/actions/permissions -F enabled=true' "$GH_LOG" && ok "Actions enabled in ops" || no "Actions not enabled"

: >"$GH_LOG"
echo c >"$T/src/f"; git -C "$T/src" commit -qam three; git -C "$T/src" push -q "$T/ops.git" master; ahead=$(opsm)
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act && ok "re-run with ops ahead exits 0" || no "re-run failed: $(tail -3 "$T/log")"
[[ "$(opsm)" == "$ahead" ]] && ok "ops ahead of public is never rewound" || no "ops rewound"
grep -q '^api -X POST repos/o/app/rulesets' "$GH_LOG" && no "a second ruleset was created" || ok "re-run is idempotent (one ruleset)"

git clone -q "$T/pub.git" "$T/x"; echo d >"$T/x/g"; git -C "$T/x" add g; git -C "$T/x" commit -qm diverge; git -C "$T/x" push -q origin master
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act && no "diverged masters must be refused" || ok "diverged masters are refused"
[[ "$(opsm)" == "$ahead" ]] && ok "nothing was forced onto ops" || no "ops changed on divergence"

echo "=== oss-cutover: $fails failure(s)"
[[ "$fails" -eq 0 ]]
