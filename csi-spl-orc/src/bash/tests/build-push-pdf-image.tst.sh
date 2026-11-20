#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_build_push_pdf_image (spec 183 row P4) builds the topic PDF
#          renderer image as exactly the reference step 031 runs, and only
#          when the renderer's inputs changed:
#   1. the tag is src-<12 hex>, the same for the same committed inputs, and it
#      changes when cmd/spool-pdf, internal/topicpdf, go.mod, go.sum or
#      pdf.Dockerfile change -- and NOT when another file of the module does
#      (CONTROL: a hub-only change keeps the tag);
#   2. a dry run builds linux/amd64 <028 repo>/spool-pdf:<tag> from
#      pdf.Dockerfile (stub docker records the call) and makes no gcloud call,
#      no login and no push; the ref equals what 031's tfvars render once cnf
#      pdf.image.tag is that tag;
#   3. DRY_RUN=0 with the tag already in the registry (stub gcloud answers the
#      describe) stops before any build: nothing to build; a describe that
#      fails with anything but NOT_FOUND (permission) is refused, no build;
#   4. no pdf.Dockerfile (row P2 not landed) is refused, before any build.
#   5. workflow 20's pdf job runs this action and watches the same inputs.
# Fixture: a throwaway git repo with the real cnf and iac lib, synthetic
# renderer files. No cloud, no real docker build.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ACTION="$PROJ_ROOT/src/bash/run/build-push-pdf-image.func.sh"
[[ -f "$ACTION" ]] || { echo "FAIL: no $ACTION"; exit 1; }
export ENV=dev

# --- the fixture repo ---------------------------------------------------------
R="$T/app"
mkdir -p "$R/csi-spl-cnf/csi-spl" "$R/csi-spl-iac/lib/bash" "$R/csi-spl-api/src/docker" \
  "$R/csi-spl-api/src/go/spool-hub-api/cmd/spool-pdf" "$R/csi-spl-api/src/go/spool-hub-api/internal/topicpdf" \
  "$R/csi-spl-api/src/go/spool-hub-api/internal/hub"
cp "$APP_ROOT"/csi-spl-cnf/csi-spl/{all,dev,prd}.env.yaml "$R/csi-spl-cnf/csi-spl/"
cp -r "$APP_ROOT/csi-spl-iac/lib/bash/funcs" "$R/csi-spl-iac/lib/bash/"
G="$R/csi-spl-api/src/go/spool-hub-api"
echo 'module spool-hub-api' >"$G/go.mod"; : >"$G/go.sum"
echo 'package main' >"$G/cmd/spool-pdf/main.go"
echo 'package topicpdf' >"$G/internal/topicpdf/render.go"
echo 'package hub' >"$G/internal/hub/server.go"
printf 'FROM scratch\n' >"$R/csi-spl-api/src/docker/pdf.Dockerfile"
gitf() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }
gitf init -q && gitf add -A && gitf commit -qm fixture

# --- stubs --------------------------------------------------------------------
mkdir -p "$T/stub"
cat >"$T/stub/docker" <<'STUB'
#!/bin/sh
case "$1" in
  login|push|run) echo "docker $*" >>"$STUB_LOG"; exit 1;;
  build) echo "$*" >>"$BUILD_LOG"; exit 0;;
  image) echo "sha256:stub"; exit 0;;
esac
exit 0
STUB
# gcloud: `artifacts docker images describe` answers per GCLOUD_HAS_IMAGE;
# every call is recorded
cat >"$T/stub/gcloud" <<'STUB'
#!/bin/sh
echo "gcloud $*" >>"$STUB_LOG"
case "$*" in "artifacts docker images describe"*)
  case "${GCLOUD_HAS_IMAGE:-0}" in
    1) echo sha256:x; exit 0 ;;
    denied) echo "ERROR: (gcloud.artifacts.docker.images.describe) PERMISSION_DENIED: denied" >&2; exit 1 ;;
    *) echo "ERROR: (gcloud.artifacts.docker.images.describe) NOT_FOUND: image not found" >&2; exit 1 ;;
  esac;;
esac
exit 1
STUB
chmod +x "$T/stub/"*

run_action() { # <snippet> [env...]: runs it with orc's libs against the fixture repo
  local snip="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$R" SPL_STATE_DIR="$T/state" STUB_LOG="$T/calls.log" BUILD_LOG="$T/build.log" \
    SPL_PRIVATE_WARN=0 PATH="$T/stub:$PATH" SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}
tag_now() { run_action 'SPL_ORG_APP=csi-spl spl_pdf_image_tag "$APP_PATH"' 2>/dev/null | tail -1; }

# --- 1. the tag ------------------------------------------------------------------
t0="$(tag_now)"
[[ "$t0" =~ ^src-[0-9a-f]{12}$ ]] && pass "1. tag $t0 is src-<12 hex>" || fail "1. tag '$t0' is not src-<12 hex>"
[[ "$(tag_now)" == "$t0" ]] && pass "1. the same inputs give the same tag" || fail "1. the tag is not stable"
echo 'package hub // changed' >"$G/internal/hub/server.go"; gitf commit -qam hub
[[ "$(tag_now)" == "$t0" ]] && pass "1. CONTROL a hub-only change keeps the tag" || fail "1. CONTROL a hub-only change moved the tag"
prev="$t0"
for f in cmd/spool-pdf/main.go internal/topicpdf/render.go go.mod go.sum ../../docker/pdf.Dockerfile; do
  echo "# $f changed" >>"$G/$f"; gitf commit -qam "$f"
  t="$(tag_now)"
  [[ "$t" != "$prev" && "$t" =~ ^src- ]] && pass "1. a change to $(basename "$f") gives a new tag ($t)" || fail "1. a change to $f kept the tag $t"
  prev="$t"
done
echo '// dirty' >>"$G/cmd/spool-pdf/main.go"
[[ "$(tag_now)" == "$prev" ]] && pass "1. the tag reads committed content only (a dirty input does not move it)" || fail "1. a dirty input moved the tag"
out="$(run_action 'SPL_ORG_APP=csi-spl spl_pdf_inputs_dirty "$APP_PATH"' 2>&1)"
grep -q 'cmd/spool-pdf/main.go' <<<"$out" && pass "1. the dirty input is reported" || fail "1. the dirty input is not reported: $out"
gitf checkout -- .
tag="$(tag_now)"

# --- 2. dry run -------------------------------------------------------------------
: >"$T/calls.log"; : >"$T/build.log"
out="$(run_action 'do_build_push_pdf_image' 2>&1)"; rc=$?
repo="$(sed -nE 's/^image *= "(.*)\/spool-hub:.*"$/\1/p' "$APP_ROOT/csi-spl-cnf/csi-spl/dev/tf/030-cloud-run-hub.vars.tfvars")"
ref="$repo/spool-pdf:$tag"
b="$(cat "$T/build.log")"
[[ $rc -eq 0 ]] && pass "2. dry run exits 0" || fail "2. dry run rc=$rc: $(tail -3 <<<"$out" | tr '\n' ' ')"
[[ $(grep -c . "$T/build.log") -eq 1 && " $b " == *" --platform linux/amd64 "* && " $b " == *" -t $ref "* \
   && " $b " == *" -f $R/csi-spl-api/src/docker/pdf.Dockerfile $R "* ]] \
  && pass "2. builds linux/amd64 $ref from pdf.Dockerfile" || fail "2. build call '${b:-<none>}' (want -t $ref -f pdf.Dockerfile)"
[[ ! -s "$T/calls.log" ]] && pass "2. dry run: no gcloud, login or push" || fail "2. dry run made calls: $(tr '\n' ';' <"$T/calls.log")"
want031="$(sed -nE 's/^image *= "(.*):.*"$/\1/p' "$APP_ROOT/csi-spl-cnf/csi-spl/dev/tf/031-cloud-run-pdf.vars.tfvars")"
[[ -n "$want031" && "${ref%:*}" == "$want031" ]] && pass "2. the ref is 031's image ($want031:<cnf pdf.image.tag>)" \
  || fail "2. ref ${ref%:*} is not 031's image '$want031'"

# --- 3. DRY_RUN=0, the tag is already in the registry -------------------------------
: >"$T/calls.log"; : >"$T/build.log"
out="$(run_action 'do_build_push_pdf_image' DRY_RUN=0 GCP_ACCOUNT=ci@example.iam.gserviceaccount.com GCLOUD_HAS_IMAGE=1 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'already in the registry' <<<"$out" && [[ ! -s "$T/build.log" ]] \
  && pass "3. an image already in the registry is not rebuilt" || fail "3. rc=$rc build='$(cat "$T/build.log")': $(tail -2 <<<"$out" | tr '\n' ' ')"
grep -q 'artifacts docker images describe .*spool-pdf:src-.* --account=ci@example.iam.gserviceaccount.com' "$T/calls.log" \
  && pass "3. the registry check pins --account" || fail "3. the registry check: $(tr '\n' ';' <"$T/calls.log")"
: >"$T/calls.log"; : >"$T/build.log"
out="$(run_action 'do_build_push_pdf_image' DRY_RUN=0 GCP_ACCOUNT=ci@example.iam.gserviceaccount.com GCLOUD_HAS_IMAGE=denied 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'cannot read .* from the registry' <<<"$out" && [[ ! -s "$T/build.log" ]] \
  && pass "3. a describe denied (not NOT_FOUND) is refused before any build" || fail "3. denied describe: rc=$rc build='$(cat "$T/build.log")': $(tail -2 <<<"$out" | tr '\n' ' ')"

# --- 4. no pdf.Dockerfile -----------------------------------------------------------
gitf rm -q csi-spl-api/src/docker/pdf.Dockerfile && gitf commit -qm nodf
: >"$T/build.log"
out="$(run_action 'do_build_push_pdf_image' 2>&1)"; rc=$?
[[ $rc -ne 0 ]] && grep -q 'missing .*pdf.Dockerfile' <<<"$out" && [[ ! -s "$T/build.log" ]] \
  && pass "4. no pdf.Dockerfile is refused before any build" || fail "4. rc=$rc: $(tail -2 <<<"$out" | tr '\n' ' ')"

# --- 5. workflow 20 ------------------------------------------------------------------
WF="$APP_ROOT/.github/workflows/20_hub-build-deploy.yml"
job="$(yq -r '.jobs["pdf-image"].steps[].run // ""' "$WF")"
grep -q 'do_build_push_pdf_image' <<<"$job" && pass "5. wf 20 job pdf-image runs do_build_push_pdf_image" || fail "5. wf 20 has no pdf-image job running the action"
grep -q "csi-spl-api/src/docker/pdf.Dockerfile" <(yq -r '.on.push.paths[]' "$WF") && pass "5. wf 20 triggers on pdf.Dockerfile" \
  || fail "5. wf 20 does not trigger on pdf.Dockerfile"
want_in="$(run_action 'SPL_ORG_APP=csi-spl spl_pdf_inputs' 2>/dev/null | sort | paste -sd' ')"
got_in="$(yq -r '.jobs["pdf-image"].env.PDF_INPUTS // ""' "$WF" | tr ' ' '\n' | sed '/^$/d' | sort | paste -sd' ')"
[[ -n "$got_in" && "$got_in" == "$want_in" ]] && pass "5. wf 20's PDF_INPUTS = the action's inputs" || fail "5. wf PDF_INPUTS [$got_in] != action [$want_in]"

# the push identity's project comes from cnf, never a literal (R7 c-056 W2)
literal_project() { grep -E 'csi-spl-\$\{?ENV' <<<"$1" || grep -q 'do_spl_cloud_cnf' <<<"$1" || echo "no do_spl_cloud_cnf"; }
ident="$(yq -r '.jobs["pdf-image"].steps[] | select(.name == "Resolve the push identity") | .run // ""' "$WF")"
[[ -n "$ident" && -z "$(literal_project "$ident")" ]] && pass "5. wf 20 pdf-image reads its GCP project from cnf (do_spl_cloud_cnf)" \
  || fail "5. wf 20 pdf-image push identity: $(literal_project "$ident" | sed -n 1p)"
[[ -n "$(literal_project 'p="csi-spl-$ENV"')" ]] && pass "5. CONTROL a literal p=\"csi-spl-\$ENV\" is refused" \
  || fail "5. CONTROL a literal project id passed"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
