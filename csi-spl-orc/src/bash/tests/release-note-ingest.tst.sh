#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_release_note_ingest (spec 065 L5), the step that fills the
#          release notes table the version pop-up's "Release notes" modal
#          reads. Without it the modal was empty (owner, HUM-10, 2026-10-03).
#          Against a SYNTHETIC repo (no network, no GCP, no hub):
#   1. every first-parent commit becomes one row, newest first, carrying its
#      full message, so the hub stores its Lay-* / Tech-* description
#   2. the version is the FIRST v-tag that contains the commit (annotated and
#      lightweight tags; a non d.d.d tag is ignored); an untagged commit has
#      no version
#   3. a refs/notes/release-notes note rides along; a .md-only commit is
#      doc_only; one top-level dir -> area, two -> none
#   4. RELEASE_NOTE_DEPTH bounds the window, RELEASE_NOTE_BATCH splits it
#   5. DRY_RUN=0 POSTs every batch to /v1/operator/release-notes and sums the
#      hub's answers; a rejected row is a WARN, not a failure
#   6. a hub answering non-200 -> FATAL, rc 1
#   7. argument validation: ENV, RELEASE_SHA, DEPTH, BATCH
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

REPO="$T/repo"
git init -q -b master "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
commit() {  # <path> <message> -> full sha
  mkdir -p "$REPO/$(dirname "$1")"
  echo "$2" >>"$REPO/$1"; git -C "$REPO" add "$1" && git -C "$REPO" commit -qm "$2" && git -C "$REPO" rev-parse HEAD
}
C1=$(commit csi-spl-wui/a.ts "fix(wui): the unread badge stays

Lay-What: The red dot now disappears once you have read a channel.
Lay-How: The app tells the server the moment you open it.
Lay-Why: You saw a dot for messages you had already read.
Tech-What: WUI marks the channel read on open.
Tech-How: ChannelView posts the read call on mount.
Tech-Why: The read call was only sent on scroll.")
C2=$(commit csi-spl-doc/b.md "docs: two")
C3=$(commit csi-spl-api/c.go "feat(hub): three")
mkdir -p "$REPO/csi-spl-orc" "$REPO/csi-spl-iac"
echo y >"$REPO/csi-spl-orc/d.sh"; echo z >"$REPO/csi-spl-iac/e.sh"
git -C "$REPO" add csi-spl-orc/d.sh csi-spl-iac/e.sh && git -C "$REPO" commit -qm "chore: four, two dirs, not deployed yet"
C4=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" tag -a v1.0.1 -m "release" "$C2"
git -C "$REPO" tag v1.0.2 "$C3"
git -C "$REPO" tag v1.0.0-junk "$C1"
git -C "$REPO" notes --ref=release-notes add -m "Lay-What: A note written after the fact." "$C4"

# act <env...> -> stdout = the action's stdout; stderr in $T/err; rc kept
act() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" RELEASE_REMOTE=no-such-remote "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    # the cloud side, stubbed: only the hub call is observed
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.invalid; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@test.invalid; }
    do_gcp_require_live_account() { :; }
    spl_hub_operator_call() {
      echo "$1 $2" >>"$CALLS"; jq -c . "${3#@}" >>"$BODIES"
      SPL_HUB_OP_STATUS="${STUB_CODE:-200}"
      SPL_HUB_OP_BODY="$(jq -c --argjson r "${STUB_REJECT:-0}" '"'"'{stored: ((.notes | length) - $r), redacted: 0, states: {}, rejected: [range($r) | {sha: "0123456789", why: "test"}]}'"'"' "${3#@}")"
    }
    do_release_note_ingest' 2>"$T/err"
}
export CALLS="$T/calls" BODIES="$T/bodies"
row() { jq -c --arg s "$1" '.notes[] | select(.sha == $s)' <<<"$out"; }

# --- 1. one row per commit, newest first, the full message -------------------
out=$(act ENV=dev); rc=$?
shas=$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')
[[ $rc == 0 && "$shas" == "$C4 $C3 $C2 $C1" ]] && pass "DRY_RUN default: 4 rows, newest first, one request" \
  || fail "rows: rc $rc shas '$shas' err '$(cat "$T/err")'"
[[ ! -s "$CALLS" ]] && pass "DRY_RUN (default) calls nothing" || fail "dry run called: $(cat "$CALLS")"
[[ "$(row "$C1" | jq -r .message)" == *"Lay-What: The red dot now disappears once you have read a channel."* ]] &&
  pass "C1 carries its full message: the Lay-What description the modal shows" || fail "C1 message: $(row "$C1")"
[[ "$(row "$C1" | jq -r .committed_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]] && pass "committed_at is ISO 8601" || fail "committed_at: $(row "$C1")"

# --- 2. versions -------------------------------------------------------------
v() { row "$1" | jq -r '.version // "none"'; }
[[ "$(v "$C1")" == v1.0.1 ]] && pass "C1 -> v1.0.1, the first tag containing it (v1.0.0-junk ignored)" || fail "C1 version $(v "$C1")"
[[ "$(v "$C2")" == v1.0.1 ]] && pass "C2 -> v1.0.1 (annotated tag on it)" || fail "C2 version $(v "$C2")"
[[ "$(v "$C3")" == v1.0.2 ]] && pass "C3 -> v1.0.2 (lightweight tag on it)" || fail "C3 version $(v "$C3")"
[[ "$(v "$C4")" == none ]] && pass "C4, in no tag yet -> no version" || fail "C4 version $(v "$C4")"

# --- 3. note, doc_only, area -------------------------------------------------
[[ "$(row "$C4" | jq -r '.note // ""')" == "Lay-What: A note written after the fact." ]] && pass "C4 carries its refs/notes/release-notes note" \
  || fail "C4 note: $(row "$C4")"
[[ "$(row "$C1" | jq -r '.note // "none"')" == none ]] && pass "C1 has no note field" || fail "C1 note: $(row "$C1")"
[[ "$(row "$C2" | jq -r '.doc_only // false')" == true && "$(row "$C1" | jq -r '.doc_only // false')" == false ]] &&
  pass "C2 (.md only) is doc_only, C1 is not" || fail "doc_only: $(row "$C2") / $(row "$C1")"
[[ "$(row "$C1" | jq -r '.area // ""')" == csi-spl-wui && "$(row "$C4" | jq -r '.area // "none"')" == none ]] &&
  pass "one top-level dir -> area; two -> none" || fail "area: $(row "$C1") / $(row "$C4")"

# --- 4. depth and batch ------------------------------------------------------
out=$(act ENV=dev RELEASE_NOTE_DEPTH=2); rc=$?
[[ $rc == 0 && "$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')" == "$C4 $C3" ]] && pass "RELEASE_NOTE_DEPTH=2 -> the 2 newest" \
  || fail "depth: rc $rc out '$out'"
out=$(act ENV=dev RELEASE_SHA="${C3:0:10}" RELEASE_NOTE_BATCH=2); rc=$?
[[ $rc == 0 && "$(wc -l <<<"$out")" == 2 && "$(jq -r '.notes | length' <<<"$out" | paste -sd' ')" == "2 1" ]] &&
  pass "RELEASE_SHA=C3, BATCH=2 -> 3 rows in 2 requests" || fail "batch: rc $rc out '$out'"

# --- 5. DRY_RUN=0 posts every batch ------------------------------------------
: >"$CALLS"; : >"$BODIES"
out=$(act ENV=prd DRY_RUN=0 RELEASE_NOTE_BATCH=3 STUB_REJECT=1); rc=$?
if [[ $rc == 0 && "$(grep -c 'POST /v1/operator/release-notes' "$CALLS")" == 2 && "$(jq -s '[.[].notes[]] | length' "$BODIES")" == 4 ]]; then
  pass "DRY_RUN=0 -> 2 POSTs to /v1/operator/release-notes carrying all 4 rows"
else fail "post: rc $rc calls '$(cat "$CALLS")' err '$(cat "$T/err")'"; fi
[[ "$(jq -r '"\(.env) \(.commits) \(.stored) \(.rejected)"' <<<"$out")" == "prd 4 2 2" ]] && grep -q 'WARN rejected' "$T/err" &&
  pass "summary sums the hub's answers; a rejected row is a WARN, rc 0" || fail "summary: '$out' err '$(cat "$T/err")'"

# --- 6. hub refuses -----------------------------------------------------------
out=$(act ENV=dev DRY_RUN=0 STUB_CODE=503); rc=$?
[[ $rc == 1 ]] && grep -q 'FATAL POST /v1/operator/release-notes (request 1) answered HTTP 503' "$T/err" &&
  pass "hub HTTP 503 -> FATAL, rc 1" || fail "503: rc $rc err '$(cat "$T/err")'"

# --- 7. argument validation ----------------------------------------------------
for bad in "ENV=lde" "ENV=" "ENV=dev RELEASE_SHA=0123456789abcdef0123456789abcdef01234567" \
  "ENV=dev RELEASE_NOTE_DEPTH=0" "ENV=dev RELEASE_NOTE_DEPTH=x" "ENV=dev RELEASE_NOTE_BATCH=501"; do
  # shellcheck disable=SC2086 # the case is a word list on purpose
  out=$(act $bad); rc=$?
  [[ $rc == 1 && -z "$out" ]] && pass "$bad -> rc 1" || fail "$bad: rc $rc out '$out'"
done

# --- 8. across the 9.9.9 -> 1.0.1 wrap (cycle 2 tags are v<X.Y.Z>-c2) -----------
C5=$(commit csi-spl-api/w.go "fix(hub): last of cycle 1")
C6=$(commit csi-spl-api/w.go "fix(hub): first of cycle 2")
C7=$(commit csi-spl-api/w.go "fix(hub): second of cycle 2")
git -C "$REPO" tag v9.9.9 "$C5"; git -C "$REPO" tag v1.0.1-c2 "$C6"; git -C "$REPO" tag v1.0.2-c2 "$C7"
out=$(act ENV=dev); rc=$?
[[ $rc == 0 && "$(v "$C5")" == v9.9.9 ]] && pass "C5, in v9.9.9 and every cycle-2 tag -> v9.9.9 (cycle first)" || fail "C5 version $(v "$C5")"
[[ "$(v "$C6")" == v1.0.1-c2 && "$(v "$C7")" == v1.0.2-c2 ]] && pass "cycle-2 rows carry the full key v1.0.1-c2 / v1.0.2-c2 (never merged with cycle 1's v1.0.1)" \
  || fail "C6/C7 versions $(v "$C6") $(v "$C7")"
[[ "$(v "$C4")" == v9.9.9 ]] && pass "C4, first shipped in v9.9.9 -> v9.9.9" || fail "C4 after the wrap $(v "$C4")"

# --- 9. do_release_note_backfill: the same ingest, back to the first commit ----
act_backfill() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" SPL_STATE_DIR="$T/state" RELEASE_REMOTE=no-such-remote "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_note_backfill' 2>"$T/err"
}
all=$(git -C "$REPO" rev-list --first-parent HEAD | paste -sd' ')
out=$(act_backfill ENV=dev RELEASE_NOTE_DEPTH=2); rc=$?
[[ $rc == 0 && "$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')" == "$all" ]] && grep -q "back to ${C1:0:8}" "$T/err" &&
  pass "backfill sends every first-parent commit back to the first one (a set RELEASE_NOTE_DEPTH does not cut it)" \
  || fail "backfill: rc $rc shas '$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')' err '$(cat "$T/err")'"
out=$(act_backfill ENV=dev RELEASE_SHA="${C2:0:10}"); rc=$?
[[ $rc == 0 && "$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')" == "$C2 $C1" ]] && pass "backfill from RELEASE_SHA=C2 -> C2, C1" \
  || fail "backfill sha: rc $rc out '$out'"
out=$(act_backfill ENV=dev RELEASE_SHA=0123456789abcdef0123456789abcdef01234567); rc=$?
[[ $rc == 1 && -z "$out" ]] && pass "backfill of an unknown RELEASE_SHA -> rc 1" || fail "backfill bad sha: rc $rc out '$out'"

echo "release-note-ingest: $fails failure(s)"
((fails == 0))
