#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 075 T00 - the Docs GitHub App, made with the manifest flow.
#   do_spl_gh_app_manifest (gh, gcloud stubbed; no real App, no GCP):
#     1. DRY_RUN default: prints the manifest (Contents write + Metadata read,
#        no webhook, not public, no events, homepage https://<BASE_DOMAIN>),
#        starts no listener, exchanges nothing
#     2. the listener serves the auto-POST form to the org's new-App page with
#        the manifest; a callback with a wrong state is 400 and keeps waiting;
#        the right state ends it, the code is exchanged, the key lands 0600 in
#        GH_APP_KEY_DIR/<slug>.pem, the key is put on dev and prd as each env's
#        own SA, and only the id / slug / key path / Install link are printed
#     3. CONTROL: an existing key file is never overwritten
#   do_spl_gh_app_key_put: 4. existing slot + same key -> nothing added
#   do_spl_gh_app_bypass:
#     5. not installed -> rc 3 and the Install link
#     6. no ruleset -> "nothing to bypass", no write
#     7. a ruleset on master -> DRY_RUN would add; DRY_RUN=0 PUTs the App as an
#        Integration bypass actor and reads it back; a second run is a no-op
# The key material in the stubs is a fixed non-key string.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
fails=0
for b in jq yq python3 curl; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done
require_action "$RUN/spl-gh-app-manifest.func.sh"
require_action "$RUN/spl-gh-app-key-put.func.sh"
require_action "$RUN/spl-gh-app-bypass.func.sh"

DEV_SA=csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com
PRD_SA=csi-spl-prd@csi-spl-prd.iam.gserviceaccount.com
mkdir -p "$T/home/.gcp/.csi" "$T/bin" "$T/sm" "$T/gh"
printf '{"type":"service_account","client_email":"%s"}\n' "$DEV_SA" >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
printf '{"type":"service_account","client_email":"%s"}\n' "$PRD_SA" >"$T/home/.gcp/.csi/key-csi-spl-prd.json"

# gcloud: secrets live as files $SM/<project>/<id>/{created,latest}
cat >"$T/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud|$*" >>"$STUB_LOG"
arg() { local a; for a in "${@:2}"; do [[ "$a" == "$1="* ]] && { echo "${a#*=}"; return; }; done; }
p="$(arg --project "$@")"
case "$*" in
  "auth activate-service-account"*) jq -r .client_email "$(arg --key-file "$@")" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "$CLOUDSDK_CONFIG/active" 2>/dev/null ;;
  "secrets describe "*) [[ -d "$SM/$p/$3" ]] ;;
  "secrets create "*) mkdir -p "$SM/$p/$3" ;;
  "secrets versions add "*) cp "$(arg --data-file "$@")" "$SM/$p/$4/latest" ;;
  "secrets versions access "*) cat "$SM/$p/$(arg --secret "$@")/latest" 2>/dev/null ;;
esac
EOF
# gh: canned answers; writes are logged with their stdin
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh|$*" >>"$STUB_LOG"
case "$*" in
  "api users/o --jq .type") echo Organization ;;
  "api -X POST /app-manifests/good-code/conversions")
    printf '{"id":4242,"slug":"o-docs","pem":"FAKE-KEY-MATERIAL\\n","webhook_secret":"FAKE-WH","client_secret":"FAKE-CS"}\n' ;;
  "api -X POST /app-manifests/"*) echo '{"message":"Not Found"}' >&2; exit 1 ;;
  "api repos/o/r --jq"*'owner.id'*) echo "11 22" ;;
  "api repos/o/r --jq .default_branch") echo master ;;
  "api orgs/o/installations"*) [[ -f "$GH/installed" ]] && echo "4242 777" ;;
  "api repos/o/r/rules/branches/master") cat "$GH/rules" ;;
  "api repos/o/r/branches/master --jq .protected") echo false ;;
  "api repos/o/r/rulesets/9") cat "$GH/rs9" ;;
  "api -X PUT repos/o/r/rulesets/9 --input -")
    jq --slurpfile b /dev/stdin '.bypass_actors = $b[0].bypass_actors' "$GH/rs9" >"$GH/rs9.new" && mv "$GH/rs9.new" "$GH/rs9" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
EOF
printf '#!/usr/bin/env bash\n:\n' >"$T/bin/sleep"
chmod +x "$T/bin/"*

# act <action> [VAR=value ...] -> rc; output in $T/out, calls in $T/calls.log
act() {
  local a="$1"; shift
  : >"$T/calls.log"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u GH_APP_CODE HOME="$T/home" PATH="$T/bin:$PATH" \
    STUB_LOG="$T/calls.log" SM="$T/sm" GH="$T/gh" PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" ORG=csi APP=spl \
    GH_APP_REPO=o/r GH_APP_KEY_DIR="$T/keys" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; quit_on() { :; }; do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/spl-gh-app-*.func.sh; do source "$f"; done
    '"$a" >"$T/out" 2>&1
}
port() { python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
writes() { grep -cE 'gcloud\|secrets (create|versions add)|gh\|api -X (POST|PUT)' "$T/calls.log"; }

# --- 1. dry run ------------------------------------------------------------------
act do_spl_gh_app_manifest; rc=$?
m="$(sed -n '/^{/,/^}/p' "$T/out")"
[[ $rc == 0 ]] && jq -e '.default_permissions == {contents:"write",metadata:"read"} and .public == false
  and .default_events == [] and (has("hook_attributes") | not) and (.url | test("^https://[a-z0-9.-]+$"))
  and (.redirect_url | test("^http://127\\.0\\.0\\.1:[0-9]+/callback$"))' <<<"$m" >/dev/null \
  && pass "1. DRY_RUN: the manifest is Contents write + Metadata read, no webhook, private" || fail "1. manifest: rc=$rc $(cat "$T/out")"
[[ "$(writes)" == 0 ]] && grep -q 'DRY_RUN would serve' "$T/out" && pass "1. DRY_RUN: no listener, no exchange, no write" \
  || fail "1. dry writes: $(cat "$T/calls.log")"
jq -e --arg d "$(yq -r .env.dns.BASE_DOMAIN "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")" '.url == "https://" + $d' <<<"$m" >/dev/null \
  && pass "1. the homepage is the cnf BASE_DOMAIN" || fail "1. homepage: $m"

# --- 2. the listener, the exchange, the store ---------------------------------------------------------
P=$(port)
act do_spl_gh_app_manifest DRY_RUN=0 GH_APP_PORT="$P" GH_APP_WAIT=30 & pid=$!
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$P/" >"$T/page" 2>/dev/null && break; /bin/sleep 0.1; done
state="$(grep -oE 'state=[A-Za-z0-9_-]+' "$T/page" | sed -n 1p | cut -d= -f2)"
grep -qF 'action="https://github.com/organizations/o/settings/apps/new?state=' "$T/page" && grep -q '&quot;contents&quot;: &quot;write&quot;' "$T/page" \
  && pass "2. / serves the auto-POST form to the org's new-App page with the manifest" || fail "2. page: $(cat "$T/page")"
code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$P/callback?code=good-code&state=nope")
[[ "$code" == 400 ]] && kill -0 $pid 2>/dev/null && pass "2. CONTROL: a wrong state is 400 and the listener keeps waiting" || fail "2. wrong state: $code"
curl -fs "http://127.0.0.1:$P/callback?code=good-code&state=$state" >/dev/null; wait $pid; rc=$?
key="$T/keys/o-docs.pem"
[[ $rc == 0 && "$(cat "$key")" == FAKE-KEY-MATERIAL && "$(stat -c %a "$key")" == 600 ]] \
  && pass "2. the code is exchanged, the key lands 0600 at <dir>/<slug>.pem" || fail "2. store: rc=$rc $(cat "$T/out")"
[[ "$(cat "$T/sm/csi-spl-dev/spool-hub-github-app-key/latest")" == FAKE-KEY-MATERIAL && "$(cat "$T/sm/csi-spl-prd/spool-hub-github-app-key/latest")" == FAKE-KEY-MATERIAL ]] \
  && pass "2. the key is in spool-hub-github-app-key on dev and prd" || fail "2. secrets: $(cat "$T/calls.log")"
n_sm=$(grep -c 'gcloud|secrets' "$T/calls.log")
n_own=$(grep 'gcloud|secrets' "$T/calls.log" | grep -cE -- "--project=csi-spl-dev --account=$DEV_SA|--project=csi-spl-prd --account=$PRD_SA")
[[ $n_sm -gt 0 && $n_sm == "$n_own" ]] && pass "2. every secrets call ran as that env's own SA on its project ($n_sm calls)" || fail "2. identity: $(grep secrets "$T/calls.log")"
grep -qE 'gcloud\|secrets create spool-hub-github-app-key .*--replication-policy=user-managed --locations=europe-north1 --labels=org=csi,app=spl,env=dev,role=hub-github-app' "$T/calls.log" \
  && pass "2. a missing slot is created the way step 030 makes slots" || fail "2. create: $(grep create "$T/calls.log")"
grep -qF 'id=4242 slug=o-docs' "$T/out" && grep -qF 'https://github.com/apps/o-docs/installations/new/permissions?suggested_target_id=11&repository_ids[]=22' "$T/out" \
  && pass "2. prints the App id, slug and the preselected Install link" || fail "2. report: $(cat "$T/out")"
! grep -qE 'FAKE-(KEY|WH|CS)' "$T/out" "$T/calls.log" && pass "2. no key, webhook or client secret in the output or argv" || fail "2. LEAK: $(grep FAKE "$T/out" "$T/calls.log")"

# --- 3. CONTROL: never overwrite a key ------------------------------------------------
act do_spl_gh_app_manifest DRY_RUN=0 GH_APP_CODE=good-code; rc=$?
[[ $rc != 0 ]] && grep -q 'refusing to overwrite' "$T/out" && ! grep -q 'gcloud|secrets' "$T/calls.log" \
  && pass "3. CONTROL: an existing key file is refused, nothing put" || fail "3. overwrite: rc=$rc $(cat "$T/out")"
act do_spl_gh_app_manifest DRY_RUN=0 GH_APP_CODE=bad-code GH_APP_KEY_DIR="$T/k2"; rc=$?
[[ $rc != 0 && ! -e "$T/k2" ]] && grep -q 'exchange failed' "$T/out" && pass "3. CONTROL: a failed exchange writes no key" || fail "3. bad code: rc=$rc $(cat "$T/out")"

# --- 4. key put, same key -------------------------------------------------------------
act do_spl_gh_app_key_put ENV=dev DRY_RUN=0 KEY_FILE="$key"; rc=$?
[[ $rc == 0 && "$(writes)" == 0 ]] && grep -q 'already holds this key' "$T/out" && pass "4. same key -> nothing added" || fail "4. rc=$rc $(cat "$T/out")"

# --- 5..7. bypass ---------------------------------------------------------------------
act do_spl_gh_app_bypass GH_APP_SLUG=o-docs; rc=$?
[[ $rc == 3 ]] && grep -q 'not installed' "$T/out" && grep -qF 'apps/o-docs/installations/new' "$T/out" \
  && pass "5. not installed -> rc 3 with the Install link" || fail "5. rc=$rc $(cat "$T/out")"
touch "$T/gh/installed"; echo '[]' >"$T/gh/rules"
act do_spl_gh_app_bypass GH_APP_SLUG=o-docs DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(writes)" == 0 ]] && grep -q 'installation_id=777' "$T/out" && grep -q 'nothing to bypass' "$T/out" \
  && pass "6. no ruleset on master -> nothing to bypass, no write" || fail "6. rc=$rc $(cat "$T/out")"
echo '[{"type":"pull_request","ruleset_source_type":"Repository","ruleset_source":"o/r","ruleset_id":9}]' >"$T/gh/rules"
echo '{"id":9,"name":"master","bypass_actors":[{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}]}' >"$T/gh/rs9"
act do_spl_gh_app_bypass GH_APP_SLUG=o-docs; rc=$?
[[ $rc == 0 && "$(writes)" == 0 ]] && grep -q 'DRY_RUN would add App 4242' "$T/out" && pass "7. DRY_RUN: would add, no write" || fail "7. dry: rc=$rc $(cat "$T/out")"
act do_spl_gh_app_bypass GH_APP_SLUG=o-docs DRY_RUN=0; rc=$?
[[ $rc == 0 ]] && jq -e '.bypass_actors == [{actor_id:5,actor_type:"RepositoryRole",bypass_mode:"always"},{actor_id:4242,actor_type:"Integration",bypass_mode:"always"}]' "$T/gh/rs9" >/dev/null \
  && grep -qF 'read-back repos/o/r/rulesets/9 bypass_actors: ["RepositoryRole:5:always","Integration:4242:always"]' "$T/out" \
  && pass "7. DRY_RUN=0 adds the App (Integration, always), keeps the others, reads it back" || fail "7. put: rc=$rc $(cat "$T/out") $(cat "$T/gh/rs9")"
act do_spl_gh_app_bypass GH_APP_SLUG=o-docs DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(writes)" == 0 ]] && grep -q 'already bypasses' "$T/out" && pass "7. a second run is a no-op" || fail "7. rerun: rc=$rc $(cat "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
