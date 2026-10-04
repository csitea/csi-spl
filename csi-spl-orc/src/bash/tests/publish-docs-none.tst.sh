#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_publish_docs under cloud provider none (spec 076 T007): the docs
#          publish routes through do_spl_cloud_dispatch, and a self-host box
#          mirrors the stage into a local dir instead of a bucket. Against a
#          SYNTHETIC repo, with a gcloud stub on PATH that records every call:
#   1. DRY_RUN (default) prints tree.json and writes nothing
#   2. DRY_RUN=0 copies every staged .md at its repo path + tree.json into
#      DOCS_DIR (SPOOL_HUB_DOCS_DIR when DOCS_DIR is unset)
#   3. it mirrors: a .md the repo no longer holds is removed, the dir that
#      leaves empty pruned; a non-.md file in the dir is left alone
#   4. the provider comes from SPOOL_CLOUD_PROVIDER or cnf env.cloud.provider
#   5. no dir, a relative dir or / is refused
#   6. zero gcloud calls and no gcp adapter step; CONTROL: under gcp the same
#      stub does record the upload
#------------------------------------------------------------------------------
set -uo pipefail
export LC_ALL=C
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

REPO="$T/repo"
git init -q -b master "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
put() { mkdir -p "$REPO/$(dirname "$1")"; printf '%s\n' "$2" >"$REPO/$1"; git -C "$REPO" add -- "$1"; }
put README.md "# Spool"
put csi-spl-doc/doc/help/how-to-post.md "# How to Post"
put csi-spl-doc/specs/072-rapid-deployability/spec.md "# 072"
put CLAUDE.md "# agent"
git -C "$REPO" commit -qm docs
SHA=$(git -C "$REPO" rev-parse HEAD)
printf 'env:\n  steps:\n    051-gcs-docs:\n      docs_bucket_name: csi-spl-dev-docs\n      publish_enabled: true\n' >"$T/cnf.yaml"
printf 'env:\n  cloud:\n    provider: none\n' >"$T/cnf-cloud-none.yaml"

# The gcloud stub: any call is recorded in $GCLOUD_CALLS and fails.
mkdir -p "$T/stub"
printf '#!/bin/sh\necho "gcloud $*" >>"$GCLOUD_CALLS"\nexit 1\n' >"$T/stub/gcloud"
chmod +x "$T/stub/gcloud"
export GCLOUD_CALLS="$T/gcloud-calls" GCP_STEPS="$T/gcp-steps"
OUT="$T/docs"

# act <env...> -> stdout; stderr in $T/err. Only the cnf merge is stubbed; the
# gcp adapter's account steps record that they ran.
act() {
  env PATH="$T/stub:$PATH" PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" CNF="$T/cnf.yaml" \
    SPOOL_CLOUD_PROVIDER=none "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF="$CNF"; }
    do_gcp_pin_account() { echo pin >>"$GCP_STEPS"; GCP_ACCOUNT=sa@test.invalid; }
    do_gcp_require_live_account() { echo live >>"$GCP_STEPS"; }
    do_publish_docs' 2>"$T/err"
}
files() { (cd "$1" && find . -type f | sed 's|^\./||' | sort | paste -sd' '); }
WANT="README.md csi-spl-doc/doc/help/how-to-post.md csi-spl-doc/specs/072-rapid-deployability/spec.md keep.txt tree.json"

# --- 1. dry run --------------------------------------------------------------
out=$(act ENV=dev DOCS_DIR="$OUT"); rc=$?
[[ $rc == 0 && "$(jq -r .sha <<<"$out")" == "$SHA" && ! -e "$OUT" ]] && pass "DRY_RUN (default) prints tree.json, writes nothing" \
  || fail "dry run: rc $rc err '$(cat "$T/err")'"

# --- 2. DRY_RUN=0 copies the stage --------------------------------------------
mkdir -p "$OUT/csi-spl-doc/old" && echo "# stale" >"$OUT/csi-spl-doc/old/gone.md" && echo keep >"$OUT/keep.txt"
out=$(act ENV=dev DRY_RUN=0 DOCS_DIR="$OUT/"); rc=$?
[[ $rc == 0 && "$(files "$OUT")" == "$WANT" ]] && pass "the docs land at their repo paths + tree.json" \
  || fail "copy: rc $rc files '$(files "$OUT")' err '$(cat "$T/err")'"
cmp -s "$REPO/csi-spl-doc/doc/help/how-to-post.md" "$OUT/csi-spl-doc/doc/help/how-to-post.md" && pass "a doc's bytes are the repo's" || fail "content differs"
[[ "$(jq -r '.files | length' "$OUT/tree.json")" == 3 && "$(jq -r .sha "$OUT/tree.json")" == "$SHA" ]] && pass "tree.json in the dir names 3 docs and the commit" || fail "tree.json: $(cat "$OUT/tree.json")"
[[ "$(jq -c . <<<"$out")" == "{\"env\":\"dev\",\"dir\":\"$OUT\",\"sha\":\"${SHA:0:8}\",\"docs\":3}" ]] && pass "the summary names the dir and counts 3 docs" || fail "summary: $out"

# --- 3. mirror: removals --------------------------------------------------------
[[ ! -e "$OUT/csi-spl-doc/old" ]] && pass "a stale .md is removed and its empty dir pruned" || fail "stale left: $(files "$OUT")"
[[ -f "$OUT/keep.txt" ]] && pass "a non-.md file in the dir is left alone" || fail "keep.txt deleted"
git -C "$REPO" rm -q csi-spl-doc/specs/072-rapid-deployability/spec.md && git -C "$REPO" commit -qm rm
out=$(act ENV=prd DRY_RUN=0 DOCS_DIR="$OUT"); rc=$?
[[ $rc == 0 && "$(files "$OUT")" == "README.md csi-spl-doc/doc/help/how-to-post.md keep.txt tree.json" && ! -e "$OUT/csi-spl-doc/specs" ]] \
  && pass "a doc removed from the repo is removed from the dir on the next publish" || fail "removal: rc $rc files '$(files "$OUT")'"
[[ "$(jq -r '.files | length' "$OUT/tree.json")" == 2 ]] && pass "tree.json follows the removal" || fail "tree.json after removal"

# --- 4. SPOOL_HUB_DOCS_DIR, and the provider from cnf ---------------------------
out=$(act ENV=dev DRY_RUN=0 SPOOL_HUB_DOCS_DIR="$T/hubdocs"); rc=$?
[[ $rc == 0 && -f "$T/hubdocs/tree.json" ]] && pass "no DOCS_DIR: SPOOL_HUB_DOCS_DIR, the hub's docs dir" || fail "hub dir: rc $rc err '$(cat "$T/err")'"
out=$(act ENV=dev DRY_RUN=0 SPOOL_CLOUD_PROVIDER= CNF="$T/cnf-cloud-none.yaml" DOCS_DIR="$T/cnfdocs"); rc=$?
[[ $rc == 0 && -f "$T/cnfdocs/tree.json" ]] && pass "cnf env.cloud.provider none selects the local publish" || fail "cnf provider: rc $rc err '$(cat "$T/err")'"

# --- 5. refusals ----------------------------------------------------------------
act ENV=dev DRY_RUN=0 >/dev/null; rc=$?
[[ $rc == 1 ]] && grep -q 'FATAL provider none publishes to a local dir' "$T/err" && pass "no dir: FATAL, rc 1" || fail "no dir: rc $rc err '$(cat "$T/err")'"
for bad in rel/docs /; do
  act ENV=dev DRY_RUN=0 DOCS_DIR="$bad" >/dev/null; rc=$?
  [[ $rc == 1 ]] && grep -q 'FATAL DOCS_DIR must be an absolute path' "$T/err" && pass "DOCS_DIR '$bad' refused" || fail "DOCS_DIR '$bad': rc $rc"
done
act ENV=dev DRY_RUN=0 SPOOL_CLOUD_PROVIDER=nope DOCS_DIR="$OUT" >/dev/null; rc=$?
[[ $rc == 1 ]] && grep -q "FATAL cloud provider must be gcp, none or aws" "$T/err" && pass "an unknown provider is refused, no publish" || fail "unknown provider: rc $rc"

# --- 6. zero gcloud, and the CONTROL that the stub sees one ----------------------
[[ ! -s "$GCLOUD_CALLS" && ! -s "$GCP_STEPS" ]] && pass "provider none: zero gcloud calls, no gcp adapter step" \
  || fail "cloud touched: '$(cat "$GCLOUD_CALLS" "$GCP_STEPS" 2>/dev/null)'"
act ENV=dev DRY_RUN=0 SPOOL_CLOUD_PROVIDER=gcp >/dev/null; rc=$?
[[ $rc == 1 ]] && grep -q '^gcloud storage rsync .* gs://csi-spl-dev-docs .*--account=sa@test.invalid' "$GCLOUD_CALLS" \
  && pass "CONTROL provider gcp: the stub records the bucket upload" || fail "control: rc $rc calls '$(cat "$GCLOUD_CALLS" 2>/dev/null)'"

[[ $fails == 0 ]] && echo "publish-docs-none: all passed" || { echo "publish-docs-none: $fails FAILED"; exit 1; }
