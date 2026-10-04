#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_publish_docs, the WUI deploy step that uploads every repo .md
#          and tree.json to the env's docs bucket (the Docs section, owner,
#          prd t1 9f0d751c). Against a SYNTHETIC repo (no network, no GCP):
#   1. every tracked .md is staged at its repo path; tree.json lists each
#      with its first "# " heading as the title and names the commit
#   2. agent-instruction files, node_modules/, tpl-gen/, bin/, the WUI's
#      built help copy, an untracked file and a path the hub refuses are
#      left out
#   3. DRY_RUN (default) prints tree.json and uploads nothing
#   4. DRY_RUN=0 uploads the stage to the cnf bucket as the pinned SA
#   5. no docs bucket in cnf, or publish_enabled false: INFO, rc 0, no upload
#   6. ENV is validated
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
put csi-spl-doc/doc/md/csi-spl.feature.md $'intro\n# Spool feature  \n## part'
put csi-spl-doc/doc/help/how-to-post.md "# How to Post"
put csi-spl-doc/specs/072-rapid-deployability/spec.md "no heading"
put CLAUDE.md "# agent"
put csi-spl-wui/AGENTS.md "# agent"
put csi-spl-doc/GEMINI.md "# agent"
put csi-spl-wui/node_modules/x/README.md "# dep"
put tpl-gen/README.md "# tpl"
put csi-spl-iac/bin/x.md "# bin"
put csi-spl-wui/src/public/help-md/how-to-post.md "# copy"
put "csi-spl-doc/a b.md" "# space"
put csi-spl-doc/notes.txt "not md"
git -C "$REPO" commit -qm docs
SHA=$(git -C "$REPO" rev-parse HEAD)
echo "# untracked" >"$REPO/csi-spl-doc/untracked.md"
printf 'env:\n  steps:\n    051-gcs-docs:\n      docs_bucket_name: csi-spl-dev-docs\n      publish_enabled: true\n' >"$T/cnf.yaml"
printf 'env:\n  steps:\n    051-gcs-docs:\n      docs_bucket_name: csi-spl-dev-docs\n      publish_enabled: false\n' >"$T/cnf-off.yaml"
printf 'env:\n  steps: {}\n' >"$T/cnf-none.yaml"

# act <env...> -> stdout; stderr in $T/err; uploads logged to $UPLOADS
export UPLOADS="$T/uploads"
act() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" CNF="$T/cnf.yaml" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do [[ $b == gcloud ]] && continue; command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_cloud_cnf() { SPL_CNF="$CNF"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@test.invalid; }
    do_gcp_require_live_account() { :; }
    spl_docs_upload() {
      echo "$2 $GCP_ACCOUNT" >>"$UPLOADS"
      (cd "$1" && find . -type f | sed "s|^\./||" | sort) >>"$UPLOADS"
    }
    do_publish_docs' 2>"$T/err"
}

# --- 1 + 2 + 3. dry run: the tree, the titles, the skips ----------------------
out=$(act ENV=dev); rc=$?
paths=$(jq -r '.files[].path' <<<"$out" | sort | paste -sd' ')
want="README.md csi-spl-doc/doc/help/how-to-post.md csi-spl-doc/doc/md/csi-spl.feature.md csi-spl-doc/specs/072-rapid-deployability/spec.md"
[[ $rc == 0 && "$paths" == "$want" ]] && pass "tree.json lists the 4 publishable docs, nothing else" \
  || fail "paths: rc $rc '$paths' err '$(cat "$T/err")'"
[[ "$(jq -r '.sha' <<<"$out")" == "$SHA" && "$(jq -r '.v' <<<"$out")" == 1 ]] && pass "tree.json names v1 and the commit" || fail "sha/v: $out"
t=$(jq -r '.files[] | select(.path == "csi-spl-doc/doc/md/csi-spl.feature.md") | .title' <<<"$out")
[[ "$t" == "Spool feature" ]] && pass "title = the first # heading, trimmed" || fail "title '$t'"
[[ "$(jq -r '.files[] | select(.path | endswith("spec.md")) | has("title")' <<<"$out")" == false ]] && pass "no heading -> no title" || fail "untitled doc"
grep -q 'WARN skipped (not a docs path): csi-spl-doc/a b.md' "$T/err" && pass "CONTROL a path the hub refuses is skipped with a WARN" || fail "no WARN: $(cat "$T/err")"
[[ ! -s "$UPLOADS" ]] && pass "DRY_RUN (default) uploads nothing" || fail "dry run uploaded"

# --- 4. DRY_RUN=0 uploads to the cnf bucket as the pinned SA ------------------
out=$(act ENV=dev DRY_RUN=0); rc=$?
[[ $rc == 0 && "$(head -1 "$UPLOADS")" == "csi-spl-dev-docs sa@test.invalid" ]] && pass "uploads to the 051 bucket as the project SA" \
  || fail "upload: rc $rc '$(head -1 "$UPLOADS" 2>/dev/null)' err '$(cat "$T/err")'"
up=$(tail -n +2 "$UPLOADS" | paste -sd' ')
[[ "$up" == "README.md csi-spl-doc/doc/help/how-to-post.md csi-spl-doc/doc/md/csi-spl.feature.md csi-spl-doc/specs/072-rapid-deployability/spec.md tree.json" ]] \
  && pass "the upload holds the docs at their repo paths + tree.json" || fail "uploaded: '$up'"
[[ "$(jq -r .docs <<<"$out")" == 4 ]] && pass "the summary counts 4 docs" || fail "summary: $out"

# --- 5. no bucket in cnf: INFO, rc 0, nothing uploaded ------------------------
rm -f "$UPLOADS"
out=$(act ENV=prd DRY_RUN=0 CNF="$T/cnf-none.yaml"); rc=$?
[[ $rc == 0 && ! -s "$UPLOADS" ]] && grep -q 'INFO docs publish is off for prd' "$T/err" \
  && pass "no 051 bucket in cnf: INFO, rc 0, no upload" || fail "no bucket: rc $rc err '$(cat "$T/err")'"
out=$(act ENV=dev DRY_RUN=0 CNF="$T/cnf-off.yaml"); rc=$?
[[ $rc == 0 && ! -s "$UPLOADS" ]] && grep -q 'publish_enabled=false' "$T/err" \
  && pass "a bucket named but publish_enabled false (051 not applied): no upload" || fail "off: rc $rc err '$(cat "$T/err")'"

# --- 6. ENV is validated -------------------------------------------------------
act ENV=lde >/dev/null; rc=$?
[[ $rc != 0 ]] && grep -q 'FATAL ENV must be dev or prd' "$T/err" && pass "ENV=lde refused" || fail "ENV: rc $rc"

[[ $fails == 0 ]] && echo "publish-docs: all passed" || { echo "publish-docs: $fails FAILED"; exit 1; }
