#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_pin_compose_images (SPL-2153) pins the root docker-compose.yml to
# a stable release's images by digest, from wf 56's spool-images.txt. Copies
# of the real compose file and .env.example, a fake gh; no network:
#   1. DRY_RUN=1 prints both pins and writes nothing
#   2. DRY_RUN=0 pins hub-init + hub to the hub digest, web to its own, and
#      .env.example names the tag (compose-pulls-images.tst.sh: a set
#      SPOOL_IMAGE_TAG replaces tag and digest together)
#   3. no PIN_IMAGES_FILE: the newest stable-* tag's release asset, via
#      gh release download
#   CONTROLS: nothing is written when the file
#     a. has a line with no digest
#     b. lacks the web line
#     c. names two different tags, or not PIN_TAG
#     d. no stable-* tag and no file -> FATAL, gh never called
#   4. the real tree is pinned: a DRY_RUN=0 run with the digests it already
#      carries changes nothing (the action and the file agree)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/pin-compose-images.func.sh"
[[ -f "$FUNC" ]] || { echo "FAIL: no $FUNC"; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
H=$(printf 'a%.0s' $(seq 64)) W=$(printf 'b%.0s' $(seq 64))

# tree <dir>: a git checkout holding copies of the real compose + env files
tree() {
  rm -rf "$1"; mkdir -p "$1"
  cp "$APP_ROOT/docker-compose.yml" "$APP_ROOT/.env.example" "$1/"
  git init -q "$1" && git -C "$1" add -A && git -C "$1" commit -qm init
}
pins() {  # <file> <hub tag> <web tag>
  printf 'ghcr.io/csitea/spool-hub:%s@sha256:%s\nghcr.io/csitea/spool-web:%s@sha256:%s\n' "$2" "$H" "$3" "$W" >"$1"
}

mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'G'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
[[ "$1 $2" == "release download" ]] || exit 1
d=""; while (($#)); do [[ "$1" == -D ]] && d="$2"; shift; done
cp "$GH_ASSET" "$d/spool-images.txt"
G
chmod +x "$T/bin/gh"

act() {  # <tree> env... -> stdout+stderr; rc kept
  local tr="$1"; shift
  env PATH="$T/bin:$PATH" GH_LOG="$T/gh.log" PROJ_PATH="$PROJ_ROOT" APP_PATH="$tr" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    source "$PROJ_PATH/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$PROJ_PATH/src/bash/run/pin-compose-images.func.sh"
    do_pin_compose_images' 2>&1
}
img() { grep -E "^ +image: .*/spool-$2:" "$1/docker-compose.yml" | sed 's/^ *image: //'; }
same() { git -C "$1" diff --quiet; }

# --- 1. dry run ------------------------------------------------------------------
tree "$T/w"; pins "$T/p" stable-2099-01-04 stable-2099-01-04
out=$(act "$T/w" PIN_IMAGES_FILE="$T/p"); rc=$?
[[ $rc == 0 ]] && grep -q "spool-hub: stable-2099-01-04@sha256:$H (2 lines)" <<<"$out" && grep -q "spool-web: stable-2099-01-04@sha256:$W (1 line)" <<<"$out" && same "$T/w" &&
  pass "1. dry run: both pins printed, nothing written" || fail "1. rc $rc: $out"

# --- 2. write ----------------------------------------------------------------------
out=$(act "$T/w" PIN_IMAGES_FILE="$T/p" DRY_RUN=0); rc=$?
want_hub='${SPOOL_IMAGE_REPO:-ghcr.io/csitea}/spool-hub:${SPOOL_IMAGE_TAG:-stable-2099-01-04@sha256:'"$H"'}'
want_web='${SPOOL_IMAGE_REPO:-ghcr.io/csitea}/spool-web:${SPOOL_IMAGE_TAG:-stable-2099-01-04@sha256:'"$W"'}'
[[ $rc == 0 && "$(img "$T/w" hub | sort -u)" == "$want_hub" && "$(img "$T/w" hub | wc -l)" == 2 && "$(img "$T/w" web)" == "$want_web" ]] &&
  pass "2. hub-init + hub pinned to the hub digest, web to its own" || fail "2. rc $rc: $out / $(img "$T/w" hub) $(img "$T/w" web)"
grep -qx '# SPOOL_IMAGE_TAG=stable-2099-01-04' "$T/w/.env.example" && pass "2. .env.example names the tag" || fail "2. .env.example: $(grep SPOOL_IMAGE_TAG= "$T/w/.env.example")"
[[ "$(git -C "$T/w" diff --numstat | awk '{a += $1} END {print a}')" == 4 ]] && pass "2. exactly 4 lines change (3 images + the env line)" || fail "2. diff: $(git -C "$T/w" diff --stat)"

# --- 3. the release asset ----------------------------------------------------------
tree "$T/w"; git -C "$T/w" tag stable-2099-01-04; git -C "$T/w" tag stable-2099-01-11
pins "$T/p11" stable-2099-01-11 stable-2099-01-11; : >"$T/gh.log"
out=$(act "$T/w" GH_ASSET="$T/p11" DRY_RUN=0); rc=$?
[[ $rc == 0 ]] && grep -q 'release download stable-2099-01-11 -p spool-images.txt' "$T/gh.log" && grep -qx '# SPOOL_IMAGE_TAG=stable-2099-01-11' "$T/w/.env.example" &&
  pass "3. no file: the newest stable-* tag's spool-images.txt via gh" || fail "3. rc $rc: $out / $(cat "$T/gh.log")"

# --- CONTROLS ----------------------------------------------------------------------
tree "$T/w"
printf 'ghcr.io/csitea/spool-hub:stable-2099-01-04\nghcr.io/csitea/spool-web:stable-2099-01-04@sha256:%s\n' "$W" >"$T/pa"
out=$(act "$T/w" PIN_IMAGES_FILE="$T/pa" DRY_RUN=0); rc=$?
[[ $rc != 0 ]] && same "$T/w" && grep -q 'FATAL' <<<"$out" && pass "CONTROL a. a line with no digest: FATAL, nothing written" || fail "CONTROL a. rc $rc: $out"
head -1 "$T/p" >"$T/pb"
out=$(act "$T/w" PIN_IMAGES_FILE="$T/pb" DRY_RUN=0); rc=$?
[[ $rc != 0 ]] && same "$T/w" && pass "CONTROL b. no web line: FATAL, nothing written" || fail "CONTROL b. rc $rc: $out"
pins "$T/pc" stable-2099-01-04 stable-2099-01-11
out=$(act "$T/w" PIN_IMAGES_FILE="$T/pc" DRY_RUN=0); rc=$?
out2=$(act "$T/w" PIN_IMAGES_FILE="$T/p" PIN_TAG=stable-2099-02-01 DRY_RUN=0); rc2=$?
[[ $rc != 0 && $rc2 != 0 ]] && same "$T/w" && pass "CONTROL c. two tags, or not PIN_TAG: FATAL, nothing written" || fail "CONTROL c. rc $rc/$rc2: $out / $out2"
: >"$T/gh.log"
out=$(act "$T/w" DRY_RUN=0); rc=$?
[[ $rc != 0 && ! -s "$T/gh.log" ]] && grep -q 'no stable-\* tag' <<<"$out" && pass "CONTROL d. no tag, no file: FATAL, gh never called" || fail "CONTROL d. rc $rc: $out"

# --- 4. the real tree agrees with the action -------------------------------------------
tree "$T/w"
hd=$(img "$T/w" hub | sed -n '1s/.*@sha256:\([0-9a-f]\{64\}\)}$/\1/p')
wd=$(img "$T/w" web | sed -n 's/.*@sha256:\([0-9a-f]\{64\}\)}$/\1/p')
tg=$(img "$T/w" web | sed -n 's/.*:-\(stable-[0-9-]*\)@.*/\1/p')
if [[ -n "$hd" && -n "$wd" && -n "$tg" ]]; then
  printf 'ghcr.io/csitea/spool-hub:%s@sha256:%s\nghcr.io/csitea/spool-web:%s@sha256:%s\n' "$tg" "$hd" "$tg" "$wd" >"$T/p4"
  out=$(act "$T/w" PIN_IMAGES_FILE="$T/p4" DRY_RUN=0); rc=$?
  [[ $rc == 0 ]] && same "$T/w" && pass "4. the real compose file is pinned ($tg) exactly as the action writes it" || fail "4. rc $rc: $out / $(git -C "$T/w" diff)"
else
  fail "4. the real docker-compose.yml has no stable-<date>@sha256 pin (hub '$hd' web '$wd' tag '$tg')"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
