#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_oss_ops_repo (spec 044, CLE-35070) with a stubbed gh and a local
#          bare "ops" remote:
#          - fail fast: no OSS_OPS_REPO / OSS_PUBLIC_REPO, the same repo twice
#          - DRY_RUN=1 creates, pushes and sets nothing
#          - DRY_RUN=0 creates the repo private with Actions DISABLED, pushes
#            master + the v-tags, sets both GCP key secrets FROM STDIN (the key
#            value is never in any gh argv nor in the log), mints the mirror
#            deploy key and removes the local private key
#          - an existing ops repo that is PUBLIC is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
ok() { echo "PASS: $1"; }
no() { echo "FAIL: $1"; fails=$((fails + 1)); }
bash -n "$PROJ_ROOT/src/bash/run/oss-ops-repo.func.sh" || { echo "FAIL: bash -n"; exit 1; }
for b in git ssh-keygen; do command -v "$b" >/dev/null || { echo "SKIP: $b not installed"; exit 0; }; done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
APP="$T/app"; mkdir -p "$APP/x-y-orc"
git init -q "$APP" && echo a >"$APP/f" && git -C "$APP" add f && git -C "$APP" commit -qm one && git -C "$APP" tag v1.0.0
git init -q --bare "$T/ops.git"
# git@github.com:<ops>.git -> the local bare repo
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$T/ops.git.insteadOf" GIT_CONFIG_VALUE_0="git@github.com:o/app-ops.git"

KEYS="$T/keys"; mkdir -p "$KEYS"
echo "{\"sa_secret\":\"SENTINEL-DEV-VALUE\"}" >"$KEYS/key-x-y-dev.json"
echo "{\"sa_secret\":\"SENTINEL-PRD-VALUE\"}" >"$KEYS/key-x-y-prd.json"

mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  "api repos/o/app-ops --jq .private") [[ -f "$GH_STATE/created" ]] && cat "$GH_STATE/created" || exit 1 ;;
  "repo create"*) echo true >"$GH_STATE/created" ;;
  "secret set"*) cat >"$GH_STATE/secret.$3" ;;
  "api repos/o/app/keys --jq .[].title") [[ -f "$GH_STATE/key" ]] && echo oss-mirror ;;
  "api -X POST repos/o/app/keys"*) touch "$GH_STATE/key" ;;
esac
exit 0
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" GH_STATE="$T/state"; mkdir -p "$GH_STATE"

act() {
  ( LOGF="$T/log"
    do_log() { printf '%s\n' "$*" >>"$LOGF"; }
    do_require_bin() { :; }
    spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
    APP_PATH="$APP" PROJ_PATH="$APP/x-y-orc" OSS_KEY_DIR="$KEYS" OSS_REF=HEAD
    source "$PROJ_ROOT/src/bash/run/oss-ops-repo.func.sh"
    do_oss_ops_repo )
}

OSS_PUBLIC_REPO=o/app act >/dev/null 2>&1 && no "no OSS_OPS_REPO must fail" || ok "no OSS_OPS_REPO fails fast"
OSS_OPS_REPO=o/app-ops act >/dev/null 2>&1 && no "no OSS_PUBLIC_REPO must fail" || ok "no OSS_PUBLIC_REPO fails fast"
OSS_OPS_REPO=o/app OSS_PUBLIC_REPO=o/app act >/dev/null 2>&1 && no "same repo must fail" || ok "the same repo twice fails fast"

: >"$GH_LOG"
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app act >/dev/null 2>&1 && ok "dry run exits 0" || no "dry run failed: $(tail -3 "$T/log")"
grep -qE '^(repo create|secret set|api -X (PUT|POST))' "$GH_LOG" && no "dry run mutated: $(grep -E '^(repo|secret|api -X)' "$GH_LOG")" || ok "dry run mutates nothing on GitHub"
[[ -z "$(git -C "$T/ops.git" for-each-ref)" ]] && ok "dry run pushes nothing" || no "dry run pushed refs"

: >"$GH_LOG"
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act >/dev/null 2>&1 && ok "apply exits 0" || no "apply failed: $(tail -3 "$T/log")"
grep -q -- '^repo create o/app-ops --private' "$GH_LOG" && ok "the repo is created private" || no "no private create"
grep -q -- '^api -X PUT repos/o/app-ops/actions/permissions -F enabled=false' "$GH_LOG" && ok "Actions stay disabled" || no "Actions not disabled"
[[ "$(git -C "$T/ops.git" rev-parse master)" == "$(git -C "$APP" rev-parse HEAD)" ]] && ok "master pushed" || no "master not pushed"
git -C "$T/ops.git" rev-parse -q --verify refs/tags/v1.0.0 >/dev/null && ok "v-tags pushed" || no "v-tags not pushed"
for e in dev prd; do
  grep -q "^api -X PUT repos/o/app-ops/environments/$e" "$GH_LOG" && ok "environment $e" || no "environment $e missing"
  n="GCP_KEY_X_Y_${e^^}"
  cmp -s "$GH_STATE/secret.$n" "$KEYS/key-x-y-$e.json" && ok "$n set from the key file on stdin" || no "$n not set from stdin"
done
grep -q SENTINEL "$GH_LOG" "$T/log" && no "a key value reached gh argv or the log" || ok "no key value in any argv or log line"
grep -q '^secret set OSS_MIRROR_DEPLOY_KEY --repo o/app-ops' "$GH_LOG" && grep -q '^api -X POST repos/o/app/keys -f title=oss-mirror .*read_only=false' "$GH_LOG" \
  && ok "mirror deploy key: public half on the public repo (write), private half an ops secret" || no "mirror deploy key not installed"
grep -q "BEGIN OPENSSH PRIVATE"' KEY' "$GH_STATE/secret.OSS_MIRROR_DEPLOY_KEY" && ok "the secret is the private key" || no "secret is not a private key"
grep -q 'PRIVATE KEY' "$GH_LOG" && no "the private key reached gh argv" || ok "the private key never reached an argv"

: >"$GH_LOG"
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act >/dev/null 2>&1 && ok "re-run exits 0" || no "re-run failed"
grep -qE '^(repo create|api -X POST repos/o/app/keys)' "$GH_LOG" && no "re-run re-created the repo or re-minted the key" || ok "re-run is idempotent (no re-create, no re-mint)"

echo false >"$GH_STATE/created"
OSS_OPS_REPO=o/app-ops OSS_PUBLIC_REPO=o/app DRY_RUN=0 act >/dev/null 2>&1 && no "a PUBLIC ops repo must be refused" || ok "a public ops repo is refused"

echo "=== oss-ops-repo: $fails failure(s)"
[[ "$fails" -eq 0 ]]
