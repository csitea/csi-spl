#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-2821, do_remove_tf_plugin_cache_per_step removes only the old
#          plugin-cache/<org>/<app>/<env>/<step> dirs.
#   1. DRY_RUN unset (=1): lists each per-step dir with its bytes and the
#      total, removes nothing.
#   2. DRY_RUN=0: the per-step dirs are gone; the shared cache's provider
#      tree (registry.terraform.io/...), a test-<pid> cache, a symlinked step
#      and a non-step dir stay.
#      CONTROL: the same tree, the dirs it keeps, would be removed by a plain
#      depth-4 find: the keep assertions can fail.
#   3. a bad DRY_RUN is refused; a missing root prints a zero total, exit 0.
#          No terraform, no network.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
SRC="$PROJ_ROOT/src/bash/run/remove-tf-plugin-cache-per-step.func.sh"
require_action "$SRC"
R="$T/plugin-cache"
prov=registry.terraform.io/hashicorp/google/6.50.0/linux_amd64

# a cache tree as sat had it, plus what must survive
mk() { mkdir -p "$R/$1/$prov"; head -c "$2" /dev/zero >"$R/$1/$prov/terraform-provider-google"; }
mk csi/spl/dev/000-gcp-remote-bucket 1000
mk csi/spl/dev/030-cloud-run-hub 2000
mk csi/spl/prd/030-cloud-run-hub 3000
mkdir -p "$R/$prov"; head -c 4000 /dev/zero >"$R/$prov/terraform-provider-google"
mk csi/spl/test-4242 500
mkdir -p "$R/csi/spl/dev/notes" "$T/elsewhere/keep"; touch "$T/elsewhere/keep/f"
ln -s "$T/elsewhere" "$R/csi/spl/dev/040-linked"

run() { env -i PATH=/usr/bin:/bin HOME="$T" TF_PLUGIN_CACHE_ROOT="$R" "$@" bash -c 'source "$0"; do_remove_tf_plugin_cache_per_step' "$SRC"; }

# --- 1. dry run ----------------------------------------------------------------
out=$(run); rc=$?
[[ $rc == 0 ]] && pass "dry run exits 0" || fail "dry run exits 0 (rc $rc)"
n=$(grep -c '^WOULD REMOVE ' <<<"$out")
[[ $n == 3 ]] && pass "dry run lists the 3 per-step dirs" || fail "dry run lists 3 dirs, got $n: $out"
grep -q 'dirs=3 bytes=' <<<"$out" && total=$(sed -n 's/.*dirs=3 bytes=\([0-9]*\).*/\1/p' <<<"$out")
[[ "${total:-0}" -ge 6000 ]] && pass "dry run prints the total bytes ($total)" || fail "total bytes >= 6000 (got: $out)"
grep -q 'dry_run=1' <<<"$out" && pass "dry run says dry_run=1" || fail "dry_run=1 in: $out"
[[ -d "$R/csi/spl/dev/000-gcp-remote-bucket" ]] && pass "dry run removes nothing" || fail "dry run removed a dir"

# --- 2. DRY_RUN=0 --------------------------------------------------------------
out=$(run DRY_RUN=0); rc=$?
[[ $rc == 0 && $(grep -c '^REMOVED ' <<<"$out") == 3 ]] && pass "DRY_RUN=0 removes 3 dirs" || fail "DRY_RUN=0 removes 3 dirs (rc $rc): $out"
gone=0; for s in dev/000-gcp-remote-bucket dev/030-cloud-run-hub prd/030-cloud-run-hub; do [[ -e "$R/csi/spl/$s" ]] || gone=$((gone + 1)); done
[[ $gone == 3 ]] && pass "the per-step dirs are gone" || fail "the per-step dirs are gone ($gone of 3)"
keep=("$prov/terraform-provider-google" "csi/spl/test-4242/$prov/terraform-provider-google" csi/spl/dev/notes csi/spl/dev/040-linked)
k=0; for p in "${keep[@]}"; do [[ -e "$R/$p" ]] && k=$((k + 1)) || echo "    lost: $p"; done
[[ $k == 4 && -f "$T/elsewhere/keep/f" ]] && pass "shared cache, test cache, non-step dir and symlinked step stay" \
  || fail "kept $k of 4 (and the symlink target: $([[ -f "$T/elsewhere/keep/f" ]] && echo ok || echo lost))"
out=$(run); grep -q 'dirs=0 bytes=0' <<<"$out" && pass "a second dry run finds nothing" || fail "second dry run: $out"

# CONTROL: a plain depth-4 find of this tree names the dirs kept above
naive=$(find "$R" -mindepth 4 -maxdepth 4 -type d -printf '%P\n')
grep -q '^registry.terraform.io/' <<<"$naive" && grep -q '^csi/spl/test-4242/' <<<"$naive" \
  && pass "control: a plain depth-4 find would hit the shared cache and the test cache" \
  || fail "control: the fixture does not expose the depth-4 trap ($naive)"

# --- 3. refusals and a missing root ------------------------------------------
out=$(run DRY_RUN=yes); [[ $? != 0 ]] && grep -q FATAL <<<"$out" && pass "DRY_RUN=yes is refused" || fail "DRY_RUN=yes refused: $out"
out=$(env -i PATH=/usr/bin:/bin HOME="$T" TF_PLUGIN_CACHE_ROOT="$T/none" bash -c 'source "$0"; do_remove_tf_plugin_cache_per_step' "$SRC"); rc=$?
[[ $rc == 0 ]] && grep -q 'dirs=0 bytes=0' <<<"$out" && pass "a missing root prints a zero total" || fail "missing root (rc $rc): $out"

echo "---"
((fails == 0)) && { echo "OK: remove-tf-plugin-cache-per-step"; exit 0; }
echo "FAILED: $fails"; exit 1
