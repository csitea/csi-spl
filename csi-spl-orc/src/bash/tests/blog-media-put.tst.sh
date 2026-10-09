#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_blog_media_put (spec 111, the blog-media bucket of iac 054),
# offline, gcloud stubbed by a fake bucket dir:
#   1. a good webp with DRY_RUN=0 is put and read back: OK line with the
#      gs:// path (bucket from cnf) and the sha256; every gcloud call --account
#   2. DRY_RUN (default) writes nothing
#   3. the same object again: OK, not written again
#   4. refused BEFORE any gcloud call, each with a reason: a PNG renamed .webp,
#      a 301 KB file, an empty file, a bad name (and ../ in it)
#   5. an existing object with another sha256: refused (3), BLOG_IMG_REPLACE=1
#      puts it
#   6. CONTROL: a read-back whose sha256 differs is exit 4, never OK
#   7. a gcloud refusal on the existence check is not read as "absent"
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# The stub bucket: gs://<b>/<n> is the file $T/gcs/<b>/<n>.
# CORRUPT=1 makes a download return other bytes; LS_DENIED=1 makes ls fail
# with a permission error.
mkdir -p "$T/stub" "$T/gcs"
cat >"$T/stub/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
local_of() { local p="${1#gs://}"; printf '%s/gcs/%s' "$T" "$p"; }
case "$1 $2" in
  "auth print-access-token") echo tok-xxxxxxxx; exit 0 ;;
  "storage ls")
    [[ "${LS_DENIED:-0}" == 1 ]] && { echo "ERROR: (gcloud.storage.ls) HTTPError 403: denied" >&2; exit 1; }
    f=$(local_of "$3"); [[ -f "$f" ]] && { echo "$3"; exit 0; }
    echo "ERROR: (gcloud.storage.ls) One or more URLs matched no objects." >&2; exit 1 ;;
  "storage cp")
    if [[ "$3" == gs://* ]]; then
      f=$(local_of "$3"); [[ -f "$f" ]] || exit 1
      if [[ "${CORRUPT:-0}" == 1 ]]; then echo garbage >"$4"; else cp "$f" "$4"; fi
    else
      f=$(local_of "$4"); mkdir -p "$(dirname "$f")"; cp "$3" "$f"; echo "put $4" >>"$T/puts.log"
    fi
    exit 0 ;;
esac
exit 0
STUB
chmod +x "$T/stub/gcloud"

PIN='do_gcp_pin_account(){ export GCP_ACCOUNT=tester@example.com; };'
run_put() { SNIPPET="$PIN do_spl_blog_media_put" in_orc T="$T" HOME="$T/home" "$@" 2>&1; }
reset() { : >"$T/calls.log"; : >"$T/puts.log"; rm -rf "$T/gcs"; mkdir -p "$T/gcs"; }

# Fixtures: a minimal RIFF....WEBP file, a second one with other bytes, a PNG.
webp() { { printf 'RIFF\x20\x00\x00\x00WEBPVP8 '; printf '%s' "$1"; } >"$2"; }
webp body-one "$T/good.webp"
webp body-two "$T/other.webp"
printf '\x89PNG\r\n\x1a\n0000IHDR' >"$T/png.webp"
: >"$T/empty.webp"
{ printf 'RIFF\x20\x00\x00\x00WEBP'; head -c $((301 * 1024 - 12)) /dev/zero; } >"$T/big.webp"
SHA=$(sha256sum <"$T/good.webp" | awk '{print $1}')
NAME=2026-10-09-hello-world.webp
URI=gs://csi-spl-dev-blog-media/$NAME

# --- 1. a good webp is put and verified -------------------------------------------
reset
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0); rc=$?
(( rc == 0 )) && pass "good webp: exit 0" || fail "good rc=$rc: $o"
grep -q "OK dev $URI sha256=$SHA\$" <<<"$o" && pass "OK line names env, gs:// path (bucket from cnf) and sha256" || fail "OK line: $o"
cmp -s "$T/good.webp" "$T/gcs/csi-spl-dev-blog-media/$NAME" && pass "the object holds the source bytes" || fail "object bytes"
[[ "$(grep -c "^gcloud storage cp gs://" "$T/calls.log")" == 1 ]] && pass "it read the object back once" || fail "no read-back: $(cat "$T/calls.log")"
grep -q -- '--content-type=image/webp' "$T/calls.log" && pass "put as image/webp" || fail "no content type"
[[ -n "$(grep '^gcloud storage' "$T/calls.log" | grep -v -- '--account=tester@example.com')" ]] \
  && fail "a gcloud storage call without --account" || pass "every gcloud storage call carries --account"

# --- 2. DRY_RUN writes nothing ----------------------------------------------------
reset
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME"); rc=$?
(( rc == 0 )) && grep -q 'DRY_RUN=1, nothing written' <<<"$o" && pass "DRY_RUN default: exit 0, says so" || fail "dry rc=$rc: $o"
[[ -s "$T/puts.log" || -n "$(ls -A "$T/gcs")" ]] && fail "DRY_RUN wrote an object" || pass "DRY_RUN: no put, bucket untouched"

# --- 3. the same object again: OK, not written again ---------------------------------
reset
run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0 >/dev/null; : >"$T/puts.log"
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0); rc=$?
(( rc == 0 )) && grep -q 'already there' <<<"$o" && [[ ! -s "$T/puts.log" ]] \
  && pass "same sha256 already there: OK, no second put" || fail "same again rc=$rc: $o"

# --- 4. local refusals, before any gcloud call ---------------------------------------
refused() {  # <label> <expected text> <args...>
  local label="$1" want="$2" o rc; shift 2
  reset
  o=$(run_put DRY_RUN=0 "$@"); rc=$?
  (( rc == 2 )) && grep -q "$want" <<<"$o" && pass "$label: refused (2) with the reason" || fail "$label rc=$rc: $o"
  grep -q gcloud "$T/calls.log" && fail "$label: gcloud was called" || pass "$label: no gcloud call"
}
refused "a PNG renamed .webp" "not a webp" BLOG_IMG_SRC="$T/png.webp" BLOG_IMG_NAME="$NAME"
refused "a 301 KB file" "over the 300 KB" BLOG_IMG_SRC="$T/big.webp" BLOG_IMG_NAME="$NAME"
refused "an empty file" "is empty" BLOG_IMG_SRC="$T/empty.webp" BLOG_IMG_NAME="$NAME"
refused "a bad name" "must be YYYY-MM-DD" BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME=hello-world.webp
refused "a ../ name" "must be YYYY-MM-DD" BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME=2026-10-09-../x.webp
refused "a .png name" "must be YYYY-MM-DD" BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME=2026-10-09-hello.png
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME=2026-10-09-hello-world-og.webp); rc=$?
(( rc == 0 )) && pass "control: a -og name passes the name check" || fail "og name rc=$rc: $o"

# --- 5. an existing object with another sha256 ------------------------------------
reset
run_put BLOG_IMG_SRC="$T/other.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0 >/dev/null; : >"$T/puts.log"
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0); rc=$?
(( rc == 3 )) && grep -q 'BLOG_IMG_REPLACE=1 overwrites' <<<"$o" && pass "another sha256 there: refused (3)" || fail "other rc=$rc: $o"
[[ -s "$T/puts.log" ]] && fail "the refusal still put" || pass "refused: no put"
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0 BLOG_IMG_REPLACE=1); rc=$?
(( rc == 0 )) && cmp -s "$T/good.webp" "$T/gcs/csi-spl-dev-blog-media/$NAME" \
  && pass "control: BLOG_IMG_REPLACE=1 replaces it, verified" || fail "replace rc=$rc: $o"

# --- 6. CONTROL: a read-back mismatch is never OK ------------------------------------
reset
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0 CORRUPT=1); rc=$?
(( rc == 4 )) && grep -q 'read-back of' <<<"$o" && pass "read-back sha256 mismatch: exit 4" || fail "mismatch rc=$rc: $o"
grep -q '^OK\|OK dev' <<<"$o" && fail "a mismatch printed OK" || pass "a mismatch prints no OK"

# --- 7. a denied ls is not "absent" ---------------------------------------------
reset
o=$(run_put BLOG_IMG_SRC="$T/good.webp" BLOG_IMG_NAME="$NAME" DRY_RUN=0 LS_DENIED=1); rc=$?
(( rc == 1 )) && grep -q 'cannot list' <<<"$o" && [[ ! -s "$T/puts.log" ]] \
  && pass "denied existence check: exit 1, no put" || fail "denied rc=$rc: $o"

echo "blog-media-put: $fails failure(s)"
(( fails == 0 ))
