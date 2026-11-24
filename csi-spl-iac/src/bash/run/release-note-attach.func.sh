#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description Attach the release note to a commit already on master (spec 065
# @description L11, release-notes.md section 4; R7 c-890 W1): the one sanctioned
# @description push of refs/notes/release-notes. A pushed message is never
# @description reworded, so a landed commit without its note turns the CI job
# @description `release-note` (workflow 10) red until a git note carrying the
# @description trailers reaches origin; this is that fix.
# @description Steps: fetch origin's master and its notes ref; refuse a SHA that
# @description is not on origin/master; write the note from RELEASE_NOTE_FILE on
# @description a scratch ref built on origin's notes (never the local
# @description refs/notes/release-notes, which may hold unpushed notes); check
# @description it with the same rule as CI (_rn_commit); push it as a
# @description fast-forward, no force. A push that loses a race re-fetches and
# @description retries, up to 3 tries.
# @param SHA (required) - the commit on origin/master, 7..40 hex
# @param RELEASE_NOTE_FILE (required) - the note: the six trailers (or a form of release-notes.md section 3), one per line
# @param DRY_RUN (optional) - 1 (default): build and check the note, push nothing; 0: push it
# @param RELEASE_REMOTE (optional) - default origin
# @param RELEASE_NOTE_TREE (optional) - checkout root, default $APP_PATH
# @example SHA=9f175b2e RELEASE_NOTE_FILE=/tmp/note.txt ./run -a do_release_note_attach
# @example SHA=9f175b2e RELEASE_NOTE_FILE=/tmp/note.txt DRY_RUN=0 ./run -a do_release_note_attach
#------------------------------------------------------------------------------
# shellcheck source=check-release-note.func.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-release-note.func.sh"

_RNA_REF="release-notes-attach"

do_release_note_attach() {
  local rc=0
  _rna_attach || rc=$?
  # the scratch ref is this action's own; never leave it in a shared checkout
  git -C "${RELEASE_NOTE_TREE:-$APP_PATH}" update-ref -d "refs/notes/$_RNA_REF" 2>/dev/null
  return "$rc"
}

_rna_attach() {
  local tree="${RELEASE_NOTE_TREE:-$APP_PATH}" sha="${SHA:-}" file="${RELEASE_NOTE_FILE:-}"
  local remote="${RELEASE_REMOTE:-origin}" dry="${DRY_RUN:-1}" full verdict try base master
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || { do_log "FATAL release-note-attach: SHA must be 7..40 hex (got '$sha')"; return 1; }
  [[ -s "$file" ]] || { do_log "FATAL release-note-attach: RELEASE_NOTE_FILE is not a non-empty file: '$file'"; return 1; }
  for try in 1 2 3; do
    git -C "$tree" fetch -q "$remote" master \
      || { do_log "FATAL release-note-attach: cannot fetch $remote master"; return 1; }
    master="$(git -C "$tree" rev-parse FETCH_HEAD)"
    git -C "$tree" update-ref -d "refs/notes/$_RNA_REF" 2>/dev/null
    # origin may have no notes ref yet: then the scratch ref starts empty
    git -C "$tree" fetch -q "$remote" "+refs/notes/$_RN_NOTES_REF:refs/notes/$_RNA_REF" 2>/dev/null || true
    full="$(git -C "$tree" rev-parse -q --verify "$sha^{commit}")" \
      || { do_log "FATAL release-note-attach: $sha is not a commit in $tree"; return 1; }
    git -C "$tree" merge-base --is-ancestor "$full" "$master" 2>/dev/null \
      || { do_log "FATAL release-note-attach: ${full:0:9} is not on $remote/master: fix its message before the push instead (git commit --amend, or the scripted reword the pre-push refusal prints)"; return 1; }
    base="$(git -C "$tree" rev-parse -q --verify "refs/notes/$_RNA_REF" || echo none)"
    git -C "$tree" notes --ref="$_RNA_REF" add -f -F "$file" "$full" \
      || { do_log "FATAL release-note-attach: git notes add failed"; return 1; }
    verdict="$(_RN_NOTES_REF="$_RNA_REF" _RN_USE_NOTES=1 _rn_commit "$tree" "$full")"
    if [[ "$verdict" == *$'\t'* ]]; then
      do_log "FATAL release-note-attach: the note for ${full:0:9} (${verdict%%$'\t'*}) falls short: ${verdict#*$'\t'} -- the rule: $_RN_DOC"
      _rn_template
      return 1
    fi
    if [[ "$dry" != 0 ]]; then
      do_log "INFO release-note-attach: DRY_RUN -- the note for ${full:0:9} ($verdict) passes; DRY_RUN=0 pushes it onto $remote refs/notes/$_RN_NOTES_REF (base ${base:0:9})"
      return 0
    fi
    if git -C "$tree" push -q "$remote" "refs/notes/$_RNA_REF:refs/notes/$_RN_NOTES_REF"; then
      do_log "OK release-note-attach: note for ${full:0:9} ($verdict) pushed to $remote refs/notes/$_RN_NOTES_REF"
      return 0
    fi
    do_log "WARN release-note-attach: push $try of 3 refused (someone pushed a note first?); re-fetching"
  done
  do_log "FATAL release-note-attach: 3 pushes refused; nothing was force-pushed"
  return 1
}
