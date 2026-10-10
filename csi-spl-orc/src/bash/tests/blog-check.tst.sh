#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 111 T004 / test 9-b, do_spl_blog_check (4.4), CALLED on a
#          throwaway repo (its own origin/master, a v1.2.3 tag, the real 10 ci
#          Sweep and the real cnf) with gcloud stubbed by a file-backed slot.
#          - a valid news post and a valid 23:30 digest pass; a resolvable sha
#            and a tag on origin/master pass; no post file reads no secret
#          CONTROLS, one per 4.4 row (each one file, one mutation, exit 1 and
#          the row named): a 451-word body, a planted personal name (taken
#          from the Sweep, never written here), an email, an unresolvable
#          8-hex token, a uuid, a box name, an unknown tag, a second digest
#          for a date, a 10:00 digest, image without image_alt, a person in
#          image_prompt, a copy without agy_review, an empty and an unreadable
#          ban list (fail closed), a post commit with a second path, plus a
#          ban-list hit whose pattern never reaches the output, a hand-set
#          published, id/lang/type/author/summary/phone/host/home refusals.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
R="$T/repo" P="csi-spl-doc/blog/posts"
# 2026-10-09T20:30:00Z = 23:30 in Europe/Helsinki (EEST): the stand-in for now
NOW_ISO=2026-10-09T20:30:00Z
NOW=$(date -u -d "$NOW_ISO" +%s)

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE 2>/dev/null || true
mkdir -p "$R/.github/workflows" "$R/csi-spl-cnf/csi-spl" "$R/$P/en" "$R/$P/fi" "$R/doc" "$T/store" "$T/home"
cp "$WF" "$R/.github/workflows/"
cp "$APP_ROOT"/csi-spl-cnf/csi-spl/{dev,prd}.env.yaml "$R/csi-spl-cnf/csi-spl/"
git -C "$R" init -q && git -C "$R" add -A && git -C "$R" commit -qm seed
SHA=$(git -C "$R" rev-parse --short=9 HEAD)
git -C "$R" tag v1.2.3
git -C "$R" update-ref refs/remotes/origin/master HEAD

# A planted personal name: the first plain alternative of the Sweep's own
# "personal name" pattern, so no name is written in this file.
NAME=$(yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$WF" |
  sed -nE "s/^sweep \"personal name\"[[:space:]]+'\(\?i\)([a-z]+)\|.*/\1/p")
BOX=$(sed -nE 's/^[[:space:]]*vm_hostname:[[:space:]]*"?([A-Za-z0-9-]+).*/\1/p' "$R"/csi-spl-cnf/csi-spl/*.env.yaml | sed -n 1p)
BAN_WORD=zqxblorp
printf '(?i)\\b%s\\b\n' "$BAN_WORD" >"$T/store/csi-spl-hub-release-note-bans"

post() {  # <lang> <id> <type> [<extra frontmatter line>...] -> a valid post on stdout
  local lang="$1" id="$2" type="$3"; shift 3
  printf -- '---\nid: %s\nlang: %s\ntype: %s\ntitle: "A title"\nsummary: "One sentence."\ndate: %s\npublished: %s\nauthor: m-004\nagy_review: a-004\ntags: [fleet]\nimage: %s.webp\nimage_alt: "A test image"\n' \
    "$id" "$lang" "$type" "${id:0:10}" "$NOW_ISO" "$id"
  local l; for l in "$@"; do printf '%s\n' "$l"; done
  printf -- 'draft: false\n---\nThe fleet shipped %s, tagged v1.2.3.\n' "$SHA"
}

run_check() {  # [VAR=value ...] -> output; rc of the action
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" HOME="$T/home" SPL_STATE_DIR="$T/state" \
      STORE="$T/store" ARGV="$T/argv" ENV=dev GCP_ACCOUNT=stub-sa@example.com \
      BLOG_TREE="$R" BLOG_CHECK_NOW="$NOW" SPOOL_BOX_TAG= BOX_TAGS= "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    gcloud() {
      echo "$*" >>"$ARGV"
      case "$*" in
        "secrets versions access latest --secret="*)
          local s="${5#--secret=}"; [[ "${NO_SLOT:-0}" == 1 ]] && return 1
          [[ -f "$STORE/$s" ]] || return 1; cat "$STORE/$s" ;;
        *) return 0 ;;
      esac
    }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_blog_check' 2>&1
}

# put <rel> - stdin into the repo file (untracked: a new post)
put() { mkdir -p "$R/$(dirname "$1")"; cat >"$R/$1"; }
clean() { git -C "$R" clean -fdq -- "$P" >/dev/null 2>&1; }

# refused <label> <row> <rel> [VAR=value ...] - exit 1 and a REFUSE line for <rel> on <row>
refused() {
  local label="$1" row="$2" rel="$3" out rc; shift 3
  out=$(run_check BLOG_FILES="$rel" "$@"); rc=$?
  if [[ $rc -eq 1 ]] && grep -qE "^REFUSE ${rel//./\\.}:[0-9]+ ${row}:" <<<"$out"; then pass "refused: $label ($row)"
  else fail "not refused: $label ($row) rc=$rc: $(grep -E '^(REFUSE|FATAL|OK|FAIL)' <<<"$out" | sed -n 1,5p)"; fi
}

N="$P/en/2026-10-09-hello.md" D="$P/en/2026-10-09-digest.md"

# ---- 0. preconditions ------------------------------------------------------
[[ -n "$NAME" && -n "$BOX" ]] && pass "a personal name (from the Sweep) and a box name (from cnf) to plant" ||
  fail "no planted name ($NAME) or box ($BOX)"

# ---- 1. the valid posts pass -----------------------------------------------
post en 2026-10-09-hello news | put "$N"
out=$(run_check BLOG_FILES="$N"); rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK blog check: 1 post file' <<<"$out" && pass "a valid news post passes (sha $SHA and v1.2.3 resolve)" ||
  fail "valid news post: rc=$rc $out"
post en 2026-10-09-digest digest | put "$D"
post "fi" 2026-10-09-hello news | put "$P/fi/2026-10-09-hello.md"
out=$(run_check); rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK blog check: 3 post file' <<<"$out" && pass "a 23:30 digest, a news post and its fi copy pass (every post file by default)" ||
  fail "valid set: rc=$rc $out"
grep -q -- "--account=stub-sa@example.com" "$T/argv" && pass "the ban list is read with --account (the pinned SA)" || fail "no --account on the gcloud call: $(cat "$T/argv")"
clean; : >"$T/argv"
out=$(run_check); rc=$?
[[ $rc -eq 0 && ! -s "$T/argv" ]] && pass "no post file: exit 0, no secret read" || fail "no post: rc=$rc argv=$(cat "$T/argv") $out"

# ---- 2. fail closed --------------------------------------------------------
post en 2026-10-09-hello news | put "$N"
cp "$T/store/csi-spl-hub-release-note-bans" "$T/bans.keep"
: >"$T/store/csi-spl-hub-release-note-bans"
out=$(run_check BLOG_FILES="$N"); rc=$?
[[ $rc -eq 1 ]] && grep -q 'ban list .* is empty: fail closed' <<<"$out" && pass "control: an empty ban list fails closed" || fail "empty ban list: rc=$rc $out"
cp "$T/bans.keep" "$T/store/csi-spl-hub-release-note-bans"
out=$(run_check BLOG_FILES="$N" NO_SLOT=1); rc=$?
[[ $rc -eq 1 ]] && grep -q 'unreadable .* fail closed' <<<"$out" && pass "control: an unreadable ban list fails closed" || fail "unreadable ban list: rc=$rc $out"

# ---- 3. one control per row ------------------------------------------------
words=$(for _ in $(seq 451); do printf 'word '; done)
{ post en 2026-10-09-hello news; echo "$words"; } | sed '/^The fleet/d' | put "$N";   refused "a 451-word body" size "$N"
{ post en 2026-10-09-hello news; echo "$words" | cut -d' ' -f1-440; } | put "$N"
out=$(run_check BLOG_FILES="$N"); [[ $? -eq 0 ]] && pass "a 447-word body passes" || fail "447 words: $out"
post en 2026-10-09-hello news | sed 's/^summary: .*/summary: "'"$(printf 'x%.0s' $(seq 161))"'"/' | put "$N"; refused "a 161-char summary" size "$N"
{ post en 2026-10-09-hello news; echo "Written with ${NAME^}."; } | put "$N";             refused "a planted personal name" hygiene "$N"
{ post en 2026-10-09-hello news; echo "Mail me at someone@example.com."; } | put "$N";  refused "an email" public-safe "$N"
{ post en 2026-10-09-hello news; echo "Call +358 40 123 4567."; } | put "$N";           refused "a phone number" public-safe "$N"
{ post en 2026-10-09-hello news; echo "It runs on hub.csi-spl-all.internal."; } | put "$N"; refused "an internal host" public-safe "$N"
{ post en 2026-10-09-hello news; echo "It ran on ${BOX}."; } | put "$N";                refused "a box name" public-safe "$N"
{ post en 2026-10-09-hello news; echo "c-601@${BOX^} did it."; } | put "$N";           refused "an agent id at a box" public-safe "$N"
{ post en 2026-10-09-hello news; hp=/home; echo "See ${hp}/someone/x."; } | put "$N";             refused "a /home/ path" public-safe "$N"
{ post en 2026-10-09-hello news; echo "Owner msg 3e9fa1c7 asked for it."; } | put "$N"; refused "an unresolvable 8-hex token" "hex tokens" "$N"
{ post en 2026-10-09-hello news; echo "Topic d49b6b76-1234-4abc-8def-0123456789ab."; } | put "$N"; refused "a uuid" "hex tokens" "$N"
{ post en 2026-10-09-hello news; echo "The words defaced and acceded are not tokens."; } | put "$N"
out=$(run_check BLOG_FILES="$N"); [[ $? -eq 0 ]] && pass "letters-only hex words pass" || fail "hex words: $out"
{ post en 2026-10-09-hello news; echo "Released as v9.9.9."; } | put "$N";              refused "an unknown tag" facts "$N"
post en 2026-10-09-hello news | sed 's/^author: .*/author: m-004@x/' | put "$N";       refused "an author with a box" author "$N"
post en 2026-10-09-hello news | sed 's/^type: .*/type: rumour/' | put "$N";            refused "an unknown type" frontmatter "$N"
post en 2026-10-09-hello news | sed 's/^id: .*/id: 2026-10-09-other/' | put "$N";     refused "an id that is not the file name" frontmatter "$N"
post en 2026-10-09-hello news | sed 's/^lang: .*/lang: fi/' | put "$N";                refused "a lang that is not the dir" frontmatter "$N"
post en 2026-10-09-hello news 'image: 2026-10-09-hello.webp' | sed '/^image_alt:/d' | put "$N"; refused "image without image_alt" frontmatter "$N"
post en 2026-10-09-hello news 'image: ../x.webp' 'image_alt: "x"' | put "$N";          refused "a bad image key" frontmatter "$N"
post en 2026-10-09-hello news 'image_prompt: "a portrait of a smiling woman at a desk"' | put "$N"; refused "a person in image_prompt" public-safe "$N"
post en 2026-10-09-hello news 'image_prompt: "a server rack at dusk, in the style of Ansel Adams"' | put "$N"; refused "a named person in image_prompt" public-safe "$N"
post en 2026-10-09-hello news 'image_prompt: "an isometric server rack at dusk"' 'image: 2026-10-09-hello.webp' 'image_alt: "a rack"' | put "$N"
out=$(run_check BLOG_FILES="$N"); [[ $? -eq 0 ]] && pass "a picture with alt and a no-people prompt passes" || fail "picture: $out"
post en 2026-10-09-hello news | sed 's/^published: .*/published: 2026-10-01T08:00:00Z/' | put "$N"; refused "a hand-set (back-dated) published" frontmatter "$N"
post en 2026-10-09-hello news | put "$N"
post "fi" 2026-10-09-hello news | sed '/^agy_review:/d' | put "$P/fi/2026-10-09-hello.md"; refused "a copy without agy_review" frontmatter "$P/fi/2026-10-09-hello.md"
post "fi" 2026-10-09-hello news | sed 's/^published: .*/published: 2026-10-09T20:31:00Z/' | put "$P/fi/2026-10-09-hello.md"; refused "a copy with its own published" frontmatter "$P/fi/2026-10-09-hello.md"
clean
post en 2026-10-09-digest digest | put "$D"
post en 2026-10-09-digest digest | sed 's/^id: .*/id: 2026-10-09-digest2/' | put "$P/en/2026-10-09-digest2.md"
refused "a second digest for a date" digest "$D"
clean
post en 2026-10-09-digest digest | sed 's/^published: .*/published: 2026-10-09T07:00:00Z/' | put "$D"
refused "a 10:00 digest" digest "$D" BLOG_CHECK_NOW="$(date -u -d 2026-10-09T07:00:00Z +%s)"
clean

# ---- 4. the ban list hit never echoes the pattern ---------------------------
{ post en 2026-10-09-hello news; echo "A word: ${BAN_WORD}."; } | put "$N"
out=$(run_check BLOG_FILES="$N"); rc=$?
[[ $rc -eq 1 ]] && grep -qE "^REFUSE ${N//./\\.}:[0-9]+ hygiene: a release-note ban list pattern matches" <<<"$out" && pass "a ban-list hit names file:line" ||
  fail "ban hit: rc=$rc $out"
grep -qi "$BAN_WORD" <<<"$out" && fail "the ban pattern reached the output" || pass "the ban pattern is never in the output"
clean

# ---- 5. commit shape -------------------------------------------------------
git -C "$R" checkout -qb shape
post en 2026-10-09-hello news | put "$N"
echo x >"$R/doc/other.md"
git -C "$R" add -A && git -C "$R" commit -qm "post + other"
out=$(run_check BLOG_FILES="$N" BLOG_CHECK_RANGE=origin/master..HEAD); rc=$?
[[ $rc -eq 1 ]] && grep -qE '^REFUSE commit:[0-9a-f]+:0 commit shape: a post commit also touches 1 other' <<<"$out" &&
  pass "control: a post commit with a second path is refused" || fail "shape 2nd path: rc=$rc $out"
git -C "$R" reset -q --hard origin/master
post en 2026-10-09-hello news | put "$N"; post en 2026-10-09-digest digest | put "$D"
git -C "$R" add -A && git -C "$R" commit -qm "two posts"
out=$(run_check BLOG_FILES="$N" BLOG_CHECK_RANGE=origin/master..HEAD); rc=$?
[[ $rc -eq 1 ]] && grep -q 'commit shape: a post commit touches 2 post ids' <<<"$out" && pass "control: a commit with two post ids is refused" || fail "shape 2 ids: rc=$rc $out"
git -C "$R" reset -q --hard origin/master
post en 2026-10-09-hello news | put "$N"; post "fi" 2026-10-09-hello news | put "$P/fi/2026-10-09-hello.md"
git -C "$R" add -A && git -C "$R" commit -qm "one post, two locales"
out=$(run_check BLOG_CHECK_RANGE=origin/master..HEAD); rc=$?
[[ $rc -eq 0 ]] && pass "one post id in two locales is one commit shape" || fail "shape ok: rc=$rc $out"

# ---- 6. image required for non-draft posts ------------------------------------
post en 2026-10-09-hello news | sed '/^image:/d' | put "$N"
refused "a non-draft post without image" frontmatter "$N"

post en 2026-10-09-hello news 'draft: true' | put "$N"
out=$(run_check BLOG_FILES="$N"); rc=$?
[[ $rc -eq 0 ]] && pass "a draft post without image passes" || fail "draft no image: rc=$rc $out"

post en 2026-10-09-hello news 'image: 2026-10-09-hello.webp' 'image_alt: "A test image"' | put "$N"
out=$(run_check BLOG_FILES="$N"); rc=$?
[[ $rc -eq 0 ]] && pass "a non-draft post with image passes" || fail "non-draft with image: rc=$rc $out"

# ---- 7. an edit keeps its published ----------------------------------------
git -C "$R" update-ref refs/remotes/origin/master HEAD
out=$(run_check BLOG_FILES="$N" BLOG_CHECK_NOW="$((NOW + 86400))"); rc=$?
[[ $rc -eq 0 ]] && pass "a landed post re-checked a day later passes (its stamp is the trunk's)" || fail "landed: rc=$rc $out"
sed -i 's/^published: .*/published: 2026-10-10T20:30:00Z/' "$R/$N"
refused "an edit that moves published" frontmatter "$N" BLOG_CHECK_NOW="$((NOW + 86400))"

[[ $fails -eq 0 ]] && echo "ALL PASS" || { echo "$fails FAIL"; exit 1; }
