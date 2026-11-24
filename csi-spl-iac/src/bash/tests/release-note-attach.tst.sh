#!/usr/bin/env bash
#------------------------------------------------------------------------------
# release-note-attach.tst.sh -- do_release_note_attach (spec 065 L11, R7 c-890
# W1): the sanctioned push of refs/notes/release-notes for a landed commit.
#   1. a SHA not on origin/master is refused, nothing pushed
#   2. a note that falls short is refused with the template, nothing pushed
#   3. DRY_RUN (default) checks the note and pushes nothing
#   4. DRY_RUN=0 pushes the note; a fresh clone's CI check then passes
#   5. it builds on origin's notes: a note another clone pushed first is kept,
#      the local refs/notes/release-notes (unpushed notes) is untouched, and
#      the action's scratch ref is gone
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

R=$(mktemp -d); trap 'rm -rf "$R"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q --bare -b master "$R/origin.git"
git clone -q "$R/origin.git" "$R/a" 2>/dev/null
echo s >"$R/a/seed.txt"; git -C "$R/a" add -A; git -C "$R/a" commit -qm seed
echo x >"$R/a/a.sh"; git -C "$R/a" add -A; git -C "$R/a" commit -qm "fix: landed without a note"
echo y >>"$R/a/a.sh"; git -C "$R/a" add -A; git -C "$R/a" commit -qm "fix: another landed one"
git -C "$R/a" push -q origin master
echo z >>"$R/a/a.sh"; git -C "$R/a" add -A; git -C "$R/a" commit -qm "fix: local only"
LANDED="$(git -C "$R/a" rev-parse HEAD~2)" OTHER="$(git -C "$R/a" rev-parse HEAD~1)" LOCAL="$(git -C "$R/a" rev-parse HEAD)"

do_log() { echo "$*"; }
# shellcheck source=../run/release-note-attach.func.sh
. "$PROJ_ROOT/src/bash/run/release-note-attach.func.sh"

FULL=$'Lay-What: a thing changed\nLay-How: it was changed\nLay-Why: it was wrong\nTech-What: t\nTech-How: t\nTech-Why: t'
printf '%s\n' "$FULL" >"$R/full.txt"; printf 'Lay-What: only one\n' >"$R/short.txt"
attach() { rc=0; out="$( export RELEASE_NOTE_TREE="$R/a"; local kv; for kv in "$@"; do export "${kv?}"; done; do_release_note_attach 2>&1)" || rc=$?; }
remote_note() { git -C "$R/origin.git" notes --ref=release-notes show "$1" 2>/dev/null; }

# 1. not on origin/master
attach SHA="$LOCAL" RELEASE_NOTE_FILE="$R/full.txt" DRY_RUN=0
{ [[ "$rc" -eq 1 ]] && grep -q 'is not on origin/master' <<<"$out" && ! git -C "$R/origin.git" rev-parse -q --verify refs/notes/release-notes >/dev/null; } \
  && pass "1. a SHA not on origin/master is refused, nothing pushed" || fail "1. not on master" "rc=$rc $out"

# 2. a short note
attach SHA="${LANDED:0:9}" RELEASE_NOTE_FILE="$R/short.txt" DRY_RUN=0
{ [[ "$rc" -eq 1 ]] && grep -q 'falls short: missing Lay-How' <<<"$out" && grep -q '^Tech-Why: <' <<<"$out" \
  && ! git -C "$R/origin.git" rev-parse -q --verify refs/notes/release-notes >/dev/null; } \
  && pass "2. a note that falls short is refused with the template, nothing pushed" || fail "2. short note" "rc=$rc $out"

# 3. DRY_RUN default
attach SHA="$LANDED" RELEASE_NOTE_FILE="$R/full.txt"
{ [[ "$rc" -eq 0 ]] && grep -q 'DRY_RUN' <<<"$out" && ! git -C "$R/origin.git" rev-parse -q --verify refs/notes/release-notes >/dev/null; } \
  && pass "3. DRY_RUN (default) checks the note and pushes nothing" || fail "3. dry run" "rc=$rc $out"

# 5 (setup). another clone pushes a note on OTHER first; a local unpushed note
git clone -q "$R/origin.git" "$R/b" 2>/dev/null
git -C "$R/b" notes --ref=release-notes add -m "$FULL" "$OTHER"
git -C "$R/b" push -q origin refs/notes/release-notes
git -C "$R/a" notes --ref=release-notes add -m "Lay-What: a local draft" "$LOCAL"
localref="$(git -C "$R/a" rev-parse refs/notes/release-notes)"

# 4. DRY_RUN=0 pushes it; the CI check of a fresh clone passes
attach SHA="$LANDED" RELEASE_NOTE_FILE="$R/full.txt" DRY_RUN=0
{ [[ "$rc" -eq 0 ]] && grep -q 'OK release-note-attach' <<<"$out" && [[ "$(remote_note "$LANDED")" == "$FULL" ]]; } \
  && pass "4. DRY_RUN=0 pushes the note onto origin" || fail "4. push" "rc=$rc $out"
git clone -q "$R/origin.git" "$R/c" 2>/dev/null
git -C "$R/c" fetch -q origin refs/notes/release-notes:refs/notes/release-notes
rc=0; out="$(RELEASE_NOTE_TREE="$R/c" RELEASE_NOTE_BASE="$(git -C "$R/c" rev-list --max-parents=0 HEAD)" do_check_release_note 2>&1)" || rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q 'commits=2 ok=2 ' <<<"$out"; } \
  && pass "4. a fresh clone with origin's notes passes the CI check" || fail "4. CI check" "rc=$rc $out"
# red control: without the notes the same clone refuses
rc=0; out="$(RELEASE_NOTE_TREE="$R/c" RELEASE_NOTE_BASE="$(git -C "$R/c" rev-list --max-parents=0 HEAD)" _RN_NOTES_REF=none do_check_release_note 2>&1)" || rc=$?
[[ "$rc" -eq 1 ]] && pass "4. control: without the notes the CI check refuses" || fail "4. control" "rc=$rc $out"

# 5. origin's earlier note kept, the local notes ref untouched
{ [[ "$(remote_note "$OTHER")" == "$FULL" && "$(git -C "$R/a" rev-parse refs/notes/release-notes)" == "$localref" ]] \
  && [[ -z "$(remote_note "$LOCAL")" ]] && ! git -C "$R/a" rev-parse -q --verify refs/notes/release-notes-attach >/dev/null; } \
  && pass "5. builds on origin's notes; the local notes ref and its draft stay local" || fail "5. no clobber" "$(git -C "$R/origin.git" notes --ref=release-notes list)"

echo ""
if [[ "$fails" -gt 0 ]]; then echo "release-note-attach: $fails FAILED"; exit 1; fi
echo "release-note-attach: all PASSED"
