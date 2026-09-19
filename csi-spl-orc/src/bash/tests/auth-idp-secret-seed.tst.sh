#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_auth_idp_secret_seed (spec 019 FR-L4, shared with 018) adds a
#          provider's client-secret version only when told (DRY_RUN=0) and only
#          when it differs, runs as the project SA in a throwaway
#          CLOUDSDK_CONFIG with --account on every secrets call, refuses a
#          missing / non-0600 / malformed owner file, a client_id that differs
#          from cnf, a placeholder cnf client id (naming the id to commit), an
#          unknown IDP and a Microsoft "Secret ID" GUID, and never puts the
#          value in argv or output. By CALLING it against a stubbed gcloud with
#          a file-backed secret store, HOME in a temp dir, and a copy of the cnf
#          whose dev LinkedIn/Microsoft client ids are set.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# a private APP tree: the real iac funcs, a cnf copy with test client ids
APP="$T/app"; mkdir -p "$APP/csi-spl-iac/lib/bash" "$APP/csi-spl-cnf"
ln -s "$APP_ROOT/csi-spl-iac/lib/bash/funcs" "$APP/csi-spl-iac/lib/bash/funcs"
cp -r "$APP_ROOT/csi-spl-cnf/csi-spl" "$APP/csi-spl-cnf/csi-spl"
LID="86test0linkedin" MID="00000000-1111-2222-3333-444444444444"
yq -i ".env.auth.social.env.SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID = \"$LID\" |
        .env.auth.social.env.SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID = \"$MID\"" "$APP/csi-spl-cnf/csi-spl/dev.env.yaml"
# a second tree whose dev LinkedIn client id is still the cnf placeholder
PH="$T/ph"; mkdir -p "$PH/csi-spl-iac/lib/bash" "$PH/csi-spl-cnf"
ln -s "$APP_ROOT/csi-spl-iac/lib/bash/funcs" "$PH/csi-spl-iac/lib/bash/funcs"
cp -r "$APP/csi-spl-cnf/csi-spl" "$PH/csi-spl-cnf/csi-spl"
yq -i '.env.auth.social.env.SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID = "PLACEHOLDER-linkedin-client-id"' "$PH/csi-spl-cnf/csi-spl/dev.env.yaml"

SECRET="WPL_AP1.test-$RANDOM-$RANDOM.secret=="
CD="$T/home/.gcp/.csi/.spl"; mkdir -p "$CD" "$T/store"
echo '{"type":"service_account"}' >"$T/home/.gcp/.csi/key-csi-spl-dev.json"
owner_file() {  # <idp> <client_id> <secret> [mode]
  (umask 077; printf '{"client_id":"%s","client_secret":"%s"}\n' "$2" "$3" >"$CD/$1-client-dev.json")
  chmod "${4:-600}" "$CD/$1-client-dev.json"
}
owner_file linkedin "$LID" "$SECRET"

run_seed() {  # [VAR=value ...] -> stdout+stderr of the action; gcloud argv in $T/argv
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="${APP_OVERRIDE:-$APP}" HOME="$T/home" SPL_STATE_DIR="$T/state" STORE="$T/store" \
      ARGV="$T/argv" CFGS="$T/cfgs" ENV=dev IDP=linkedin "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      echo "${CLOUDSDK_CONFIG:-<unset>}" >>"$CFGS"
      case "$*" in
        "auth activate-service-account"*) return 0 ;;
        "auth list"*) echo "csi-spl-dev-sa@csi-spl-dev.iam.gserviceaccount.com" ;;
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        "secrets versions add "*) local s="$4"; cat >"$STORE/$s"; echo add "$s" >>"$STORE/.adds" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_auth_idp_secret_seed' 2>&1
}
LS=csi-spl-hub-auth-linkedin-client-secret MS=csi-spl-hub-auth-microsoft-client-secret
adds() { grep -c . "$T/store/.adds" 2>/dev/null || echo 0; }

out=$(run_seed); rc=$?
[[ $rc -eq 0 && $(adds) -eq 0 && "$out" == *"DRY_RUN would add"* ]] && pass "default is a dry run: nothing added" || fail "dry run: rc=$rc adds=$(adds) $out"

out=$(run_seed DRY_RUN=0); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$LS" 2>/dev/null)" == "$SECRET" ]] && pass "DRY_RUN=0 adds the file's client_secret (no newline) to the linkedin slot" || fail "real run: rc=$rc $out"
if grep -qF "$SECRET" <<<"$out"; then fail "the value appears in the output"; else pass "no value in the output"; fi
if grep -qF "$SECRET" "$T/argv"; then fail "the value appears in gcloud argv"; else pass "no value in gcloud argv"; fi
[[ $(grep '^secrets ' "$T/argv" | grep -vc -- '--account=csi-spl-dev-sa@csi-spl-dev.iam.gserviceaccount.com') -eq 0 ]] \
  && pass "every secrets call carries --account=<the project SA>" || fail "unpinned secrets call"
if grep -qxE '<unset>|.*/\.config/gcloud' "$T/cfgs"; then fail "a gcloud call ran on the shared/ambient config"; else pass "every gcloud call ran in a throwaway CLOUDSDK_CONFIG"; fi
[[ ! -e "$(head -1 "$T/cfgs")" ]] && pass "the throwaway config is removed afterwards" || fail "throwaway config left behind"

n=$(adds)
out=$(run_seed DRY_RUN=0)
[[ $(adds) -eq $n && "$out" == *"nothing to add"* ]] && pass "a re-run adds nothing (idempotent)" || fail "re-run added: $(adds) vs $n"

owner_file linkedin "$LID" "$SECRET-rotated"
out=$(run_seed DRY_RUN=0)
[[ "$(cat "$T/store/$LS")" == "$SECRET-rotated" ]] && pass "a rotated secret is re-added" || fail "rotation: $out"

refused() {  # <label> <expect-substring> [VAR=value ...]
  local label="$1" want="$2"; shift 2
  local n; n=$(adds)
  out=$(run_seed DRY_RUN=0 "$@"); rc=$?
  [[ $rc -ne 0 && $(adds) -eq $n && "$out" == *"$want"* ]] && pass "refused: $label" || fail "$label: rc=$rc adds=$(adds)/$n $out"
}
owner_file linkedin "$LID" "$SECRET" 644;         refused "a group/world-readable owner file" "mode 0600"
owner_file linkedin "other-id" "$SECRET";         refused "a client_id that differs from cnf" "differs from cnf"
owner_file linkedin "$LID" "";                    refused "an empty client_secret" "no client_secret"
owner_file linkedin "$LID" " $SECRET";            refused "whitespace around the secret" "whitespace"
printf 'not json' >"$CD/linkedin-client-dev.json"; chmod 600 "$CD/linkedin-client-dev.json"
refused "a malformed owner file" "not a JSON object"
rm -f "$CD/linkedin-client-dev.json";             refused "no owner file" "no owner file"
owner_file linkedin "$LID" "$SECRET"
refused "an unknown IDP" "IDP must be" IDP=google
refused "a bad DRY_RUN" "DRY_RUN must be" DRY_RUN=yes
# cnf still at PLACEHOLDER- -> refused, naming the public id to commit
APP_OVERRIDE="$PH" refused "a placeholder cnf client id (names the id to commit)" "commit '$LID'"

# microsoft: a bare GUID is the Azure Secret ID, not the Value (request from 018)
owner_file microsoft "$MID" "1b2c3d4e-aaaa-bbbb-cccc-0123456789ab"
refused "a Microsoft Secret ID (bare GUID) instead of the Value" "Secret ID" IDP=microsoft
owner_file microsoft "$MID" "Abc8Q~valueLooksLikeThis.xyz"
out=$(run_seed DRY_RUN=0 IDP=microsoft); rc=$?
[[ $rc -eq 0 && "$(cat "$T/store/$MS" 2>/dev/null)" == "Abc8Q~valueLooksLikeThis.xyz" ]] \
  && pass "CONTROL: a Microsoft secret Value is admitted into the microsoft slot" || fail "microsoft value: rc=$rc $out"

echo
(( fails == 0 )) && echo "auth-idp-secret-seed: ALL PASS" || { echo "auth-idp-secret-seed: $fails FAIL"; exit 1; }
