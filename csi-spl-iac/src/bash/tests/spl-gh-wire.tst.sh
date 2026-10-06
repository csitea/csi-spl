#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 072 A11 -- the GitHub vars wf 20 and 30 read are wired from
#   terraform's outputs by do_spl_gh_wire, never by a hand `gh variable set`.
#   Hermetic: `gh` is a stub over a dir of variables, `gcloud` a stub over a
#   dir of tfstate objects (gs://<bucket>/<prefix>/default.tfstate).
#     0. the action's 6 names == the `vars.*` of wf 20 + wf 30 (the real files)
#     1. DRY_RUN default: every variable "would create", nothing written; envs
#        come from the cnf's rendered step 017 backend configs
#     2. each env's state is read as THAT env's SA (--account on every call)
#        in a private CLOUDSDK_CONFIG, never the shared one
#     3. DRY_RUN=0 writes all 6 and reads each back; a re-run is unchanged
#     4. a changed output is "would update: old -> new"
#     5. an absent output (step not applied) is refused naming the step and
#        the make target; the other variables still run; nothing written for it
#     6. a malformed output is refused
#     7. GH_WIRE_ENVS narrows the envs; the repo comes from origin, else
#        GH_WIRE_REPO, else refused
#     8. ORG / APP come from the project dir's name, so a stale ORG / APP
#        (an agent worktree's parent dirs) still finds the cnf
#   CONTROL: no SA key for an env -> refused, no state read for it; a value
#   planted in the state outside the wired outputs never reaches the output.
#------------------------------------------------------------------------------
set -uo pipefail
# Inherited from a git hook, these make `git -C "$T/app"` write the CALLER's repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/spl-gh-wire.func.sh"
PIN="$PROJ_ROOT/lib/bash/funcs/gcp-account-pin.func.sh"
OAP="$PROJ_ROOT/lib/bash/funcs/resolve-oap.func.sh"
WF="$APP_ROOT/.github/workflows"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
require_action "$FUNC"

# --- 0. the names the workflows read ------------------------------------------
want_names=$(grep -ohE 'vars\.GCP_[A-Z_]+' "$WF"/20_*.yml "$WF"/30_*.yml | sed 's/^vars\.//' | sort -u)
have_names=$(for e in DEV PRD; do bash -c 'source "$1"; _sgw_map' _ "$FUNC" | cut -f1 | sed "s/\$/_$e/"; done | sort -u)
[[ -n "$want_names" && "$want_names" == "$have_names" && $(wc -l <<<"$have_names") == 6 ]] \
  && pass "0. the action wires exactly the 6 vars.* wf 20 and 30 read" \
  || fail "0. names differ: workflows [${want_names//$'\n'/ }] action [${have_names//$'\n'/ }]"

# --- fixtures -----------------------------------------------------------------
mkdir -p "$T/bin" "$T/vars" "$T/gcs" "$T/home/.gcp/.o" "$T/home/.config/gcloud" "$T/app/o-app-iac"
git -C "$T/app" init -q
[[ "$(git -C "$T/app" rev-parse --absolute-git-dir)" == "$T/app/.git" ]] || { echo "FAIL: fixture repo is not isolated"; exit 1; }
git -C "$T/app" remote add origin git@github.com:o/app.git
for e in dev prd; do
  printf '{"type":"service_account","client_email":"o-app-%s@o-app-%s.iam.gserviceaccount.com"}\n' "$e" "$e" \
    >"$T/home/.gcp/.o/key-o-app-$e.json"
  for s in 016-firebase-deploy-iam 017-github-wif-deploy; do
    mkdir -p "$T/app/o-app-cnf/o-app/$e/tf"
    printf '# GENERATED\nbucket = "o-app-%s-tfstate"\nprefix = "terraform/%s"\n' "$e" "$s" \
      >"$T/app/o-app-cnf/o-app/$e/tf/$s.backend-config.tfvars"
  done
done
MARK="PLANTED-NOT-AN-OUTPUT-$$"
state() {  # <env> <step> <outputs-json>
  local d="$T/gcs/o-app-$1-tfstate/terraform/$2"; mkdir -p "$d"
  jq -n --argjson o "$3" --arg m "$MARK" \
    '{version:4, outputs:($o | map_values({value:., type:"string"})), resources:[{instances:[{attributes:{private_key:$m}}]}]}' \
    >"$d/default.tfstate"
}
wif() { printf 'projects/%s/locations/global/workloadIdentityPools/github/providers/github' "$1"; }
seed() {
  for e in dev prd; do
    n=1; [[ $e == prd ]] && n=2
    state "$e" 017-github-wif-deploy "{\"wif_provider_name\":\"$(wif $n)\",\"deploy_sa_email\":\"deploy@o-app-$e.iam.gserviceaccount.com\",\"github_ref\":\"refs/heads/master\"}"
    state "$e" 016-firebase-deploy-iam "{\"firebase_deploy_sa_email\":\"fb-deploy@o-app-$e.iam.gserviceaccount.com\",\"firebase_deploy_roles\":\"x\"}"
  done
}
seed

cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*/actions/variables/*) f="$GH_STUB_VARS/${2##*/}"; [[ -f "$f" ]] || { echo '{"message":"Not Found","status":"404"}'; exit 1; }; cat "$f" ;;
  "api repos/"*) echo "${2#repos/}" ;;
  "variable set") echo "$*" >>"$GH_STUB_LOG"; [[ "$4" == --repo && "$6" == --body ]] || exit 2; printf '%s' "$7" >"$GH_STUB_VARS/$3" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
STUB
cat >"$T/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "${CLOUDSDK_CONFIG-<unset>}|$*" >>"$GCLOUD_STUB_LOG"
case "$*" in
  "auth activate-service-account --key-file="*)
    for a in "$@"; do [[ "$a" == --key-file=* ]] && k="${a#--key-file=}"; done
    jq -r .client_email "$k" >"$CLOUDSDK_CONFIG/active" ;;
  "auth list"*) cat "${CLOUDSDK_CONFIG:-/nonexistent}/active" 2>/dev/null ;;
  "storage cat --account="*" gs://"*) cat "$GCS_STUB/${4#gs://}" ;;
  *) echo "gcloud stub: unexpected $*" >&2; exit 3 ;;
esac
STUB
chmod +x "$T/bin/gh" "$T/bin/gcloud"

act() {  # runs the action in a clean shell; output in $T/out
  : >"$T/log"; : >"$T/glog"
  env -u GH_WIRE_ENVS -u GH_WIRE_REPO -u DRY_RUN -u ACCOUNT -u GCP_ACCOUNT -u GCP_SA_KEY_FILE -u CLOUDSDK_CONFIG \
    -u PROJ_ID -u SPL_PROJECT -u GCP_PROJECT -u ENV \
    PATH="$T/bin:$PATH" HOME="$T/home" GH_STUB_VARS="$T/vars" GH_STUB_LOG="$T/log" GCLOUD_STUB_LOG="$T/glog" GCS_STUB="$T/gcs" \
    APP_PATH="$T/app" PROJ_PATH="$T/app/o-app-iac" ORG=o APP=app "$@" \
    bash -c 'do_log() { echo "$*"; }; source "$1"; source "$2"; source "$3"; do_spl_gh_wire' _ "$OAP" "$PIN" "$FUNC" >"$T/out" 2>&1
}
nvars() { find "$T/vars" -type f | wc -l; }

# --- 1. dry run -----------------------------------------------------------------
act; rc=$?
[[ $rc == 0 && $(grep -c 'would create' "$T/out") == 6 && ! -s "$T/log" && $(nvars) == 0 ]] \
  && grep -qF "o/app GCP_WIF_PROVIDER_PRD would create: $(wif 2)" "$T/out" \
  && grep -qF "GCP_FIREBASE_DEPLOY_SA_EMAIL_DEV would create: fb-deploy@o-app-dev.iam.gserviceaccount.com" "$T/out" \
  && pass "1. dry run by default: 6 would create (dev + prd from the cnf), nothing written" || fail "1. dry run: rc=$rc $(cat "$T/out" "$T/log")"

# --- 2. identity --------------------------------------------------------------
reads=$(grep -c '|storage cat ' "$T/glog")
bad_id=$(grep '|storage cat ' "$T/glog" | grep -vcE '\|storage cat --account=o-app-(dev|prd)@o-app-(dev|prd)\.iam\.gserviceaccount\.com gs://o-app-(dev|prd)-tfstate/')
mismatch=$(grep '|storage cat ' "$T/glog" | sed -nE 's/.*--account=o-app-([a-z]+)@.* gs:\/\/o-app-([a-z]+)-tfstate.*/\1 \2/p' | awk '$1 != $2' | wc -l)
shared=$(grep -cE "^(<unset>|$T/home/.config/gcloud)\|" "$T/glog")
[[ $reads == 4 && $bad_id == 0 && $mismatch == 0 && $shared == 0 ]] \
  && pass "2. 4 state reads (2 steps x 2 envs), each as its own env SA, in a private gcloud config" \
  || fail "2. identity: reads=$reads bad=$bad_id mismatch=$mismatch shared=$shared $(cat "$T/glog")"

# --- 3. write, read back, re-run ------------------------------------------------
act DRY_RUN=0; rc=$?
[[ $rc == 0 && $(wc -l <"$T/log") == 6 && $(grep -c ' set: ' "$T/out") == 6 && $(nvars) == 6 ]] \
  && grep -qxF "variable set GCP_DEPLOY_SA_EMAIL_PRD --repo o/app --body deploy@o-app-prd.iam.gserviceaccount.com" "$T/log" \
  && [[ "$(find "$T/vars" -type f -printf '%f\n' | sort)" == "$want_names" ]] \
  && pass "3. DRY_RUN=0 sets the 6 vars the workflows read, each read back" || fail "3. set: rc=$rc $(cat "$T/out" "$T/log")"
act DRY_RUN=0; rc=$?
[[ $rc == 0 && $(grep -c unchanged "$T/out") == 6 && ! -s "$T/log" ]] \
  && pass "3. a re-run is unchanged x6, nothing written" || fail "3. re-run: rc=$rc $(cat "$T/out" "$T/log")"

# --- 4. update ------------------------------------------------------------------
state dev 017-github-wif-deploy "{\"wif_provider_name\":\"$(wif 9)\",\"deploy_sa_email\":\"deploy@o-app-dev.iam.gserviceaccount.com\"}"
act; rc=$?
[[ $rc == 0 && $(grep -c 'would update' "$T/out") == 1 ]] && grep -qF "GCP_WIF_PROVIDER_DEV would update: $(wif 1) -> $(wif 9)" "$T/out" && [[ ! -s "$T/log" ]] \
  && pass "4. a changed output is would-update old -> new" || fail "4. update: rc=$rc $(cat "$T/out" "$T/log")"
seed

# --- 5. absent output -----------------------------------------------------------
rm -rf "$T/vars"; mkdir -p "$T/vars"
rm -f "$T/gcs/o-app-prd-tfstate/terraform/016-firebase-deploy-iam/default.tfstate"
act DRY_RUN=0; rc=$?
[[ $rc != 0 && $(nvars) == 5 && ! -e "$T/vars/GCP_FIREBASE_DEPLOY_SA_EMAIL_PRD" ]] \
  && grep -qF "GCP_FIREBASE_DEPLOY_SA_EMAIL_PRD: step 016-firebase-deploy-iam has no output firebase_deploy_sa_email in prd" "$T/out" \
  && grep -qF "ENV=prd STEP=016-firebase-deploy-iam make do-tf-plan" "$T/out" \
  && pass "5. an unapplied step is refused naming the step and make target; the other 5 still set" \
  || fail "5. absent: rc=$rc nvars=$(nvars) $(cat "$T/out")"
seed

# --- 6. malformed ---------------------------------------------------------------
state dev 016-firebase-deploy-iam '{"firebase_deploy_sa_email":"not an email"}'
act; rc=$?
[[ $rc != 0 ]] && grep -qF "GCP_FIREBASE_DEPLOY_SA_EMAIL_DEV: step 016-firebase-deploy-iam output firebase_deploy_sa_email in dev is malformed" "$T/out" \
  && pass "6. a malformed output is refused" || fail "6. malformed: rc=$rc $(cat "$T/out")"
seed

# --- 7. envs and repo -------------------------------------------------------------
act GH_WIRE_ENVS=dev; rc=$?
[[ $rc == 0 && $(grep -c 'GCP_[A-Z_]*_DEV ' "$T/out") == 3 ]] && ! grep -q '_PRD ' "$T/out" && ! grep -q 'o-app-prd' "$T/glog" \
  && pass "7. GH_WIRE_ENVS=dev wires dev only, prd untouched" || fail "7. envs: rc=$rc $(cat "$T/out")"
git -C "$T/app" remote set-url origin https://github.com/o2/app2.git
act; grep -qF "o2/app2 GCP_WIF_PROVIDER_DEV" "$T/out" && pass "7. repo from an https origin" || fail "7. https origin: $(cat "$T/out")"
git -C "$T/app" remote set-url origin https://git.example.com/o/app.git
act; rc=$?
[[ $rc != 0 ]] && grep -qF "set GH_WIRE_REPO" "$T/out" && [[ ! -s "$T/glog" ]] \
  && pass "7. a non-GitHub origin with no GH_WIRE_REPO is refused before any read" || fail "7. non-GitHub: rc=$rc $(cat "$T/out")"
act GH_WIRE_REPO=o3/app3; grep -qF "o3/app3 GCP_WIF_PROVIDER_DEV" "$T/out" && pass "7. GH_WIRE_REPO wins" || fail "7. GH_WIRE_REPO: $(cat "$T/out")"
git -C "$T/app" remote set-url origin git@github.com:o/app.git

# --- 8. a worktree's stale ORG / APP -------------------------------------------
act ORG=o-app-wt APP=c-001; rc=$?
[[ $rc == 0 && $(grep -cE '_(DEV|PRD) (would create|would update|unchanged)' "$T/out") == 6 ]] \
  && pass "8. a stale ORG / APP (worktree parents) still resolves the cnf from the project dir" || fail "8. oap: rc=$rc $(cat "$T/out")"

# --- CONTROLs ---------------------------------------------------------------------
act; ! grep -rqF "$MARK" "$T/out" && grep -qF "$MARK" "$T/gcs/o-app-dev-tfstate/terraform/017-github-wif-deploy/default.tfstate" \
  && pass "CONTROL: a value in the state outside the wired outputs never reaches the output" || fail "CONTROL: the planted value leaked"
mv "$T/home/.gcp/.o/key-o-app-prd.json" "$T/key-prd.json"
act DRY_RUN=0; rc=$?
[[ $rc != 0 ]] && ! grep -q 'o-app-prd-tfstate' "$T/glog" && ! grep -q '_PRD' "$T/log" && grep -qF "prd: no identity" "$T/out" \
  && pass "CONTROL: no SA key for prd -> refused, its state is never read, nothing written for it" \
  || fail "CONTROL no key: rc=$rc $(cat "$T/out" "$T/glog")"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
