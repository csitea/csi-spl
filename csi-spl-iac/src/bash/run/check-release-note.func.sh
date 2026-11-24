#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The pre-push part `release-note` (spec 065 L2, L11 the refusal):
# @description every commit in the pushed range must carry its release note as
# @description the six trailers of csi-spl-doc/doc/help/release-notes.md
# @description (Lay-What, Lay-How, Lay-Why, Tech-What, Tech-How, Tech-Why), one
# @description line each and never empty, in the LAST paragraph of the message --
# @description or one of that doc's special forms (section 3, spec 065 section 5.2):
# @description   merge      skipped (trunk is linear)
# @description   revert     the git revert message + Lay-Why
# @description   skip       'Release-Note: skip' + Lay-Why (test-, CI-only, baselines)
# @description   doc-only   every touched path is .md: Lay-What + Lay-Why
# @description REFUSE mode (spec 065 L11; owner HUM-10, t1 5a91349c, 2026-11-24:
# @description "Notes should be always required"): a commit that lacks its note
# @description fails the part, so the pre-push hook (and so do_spl_push_master)
# @description refuses the push, and the CI job `release-note` of workflow 10
# @description turns red on a push that skipped the hook. Each refusal names the
# @description commit, its kind and the missing or empty trailers. The L2 week of
# @description warnings is over; RELEASE_NOTE_MODE=warn is left for a measurement
# @description by hand only, the pre-push part never reads it.
# @description One machine-readable line per run:
# @description   RELEASE_NOTE_CHECK mode=<refuse|warn> base=<sha> head=<sha> commits=<n>
# @description     ok=<n> doc=<n> skip=<n> revert=<n> merge=<n> warn=<n>
# @description   (commits excludes merges; warn = the commits that lack their
# @description   note; compliance = (commits - warn) / commits)
# @description A git note on refs/notes/release-notes (release-notes.md section 4,
# @description the fix for a commit already on master) stands in for the
# @description message's trailers, as it does for the ingest.
# @description CI (workflow 10, job release-note) runs it with
# @description RELEASE_NOTE_BASE=switch: every commit after the one that made the
# @description part refuse (the commit that added _RN_SWITCH_MARK to this file).
# @description No cache: it reads only the messages of the pushed commits (one
# @description git call each, well under a second), and it is selected by the
# @description range having commits, not by paths.
# @param RELEASE_NOTE_TREE (optional) - checkout root, default $APP_PATH
# @param RELEASE_NOTE_BASE (optional) - range base, default $PRE_PUSH_BASE or origin/master; 'switch' = the commit that made the part refuse
# @param RELEASE_NOTE_MODE (optional) - refuse (default, exit 1 when a commit lacks its note) or warn (exit 0, a measurement)
# @example ./run -a do_check_release_note
# @example RELEASE_NOTE_BASE=switch ./run -a do_check_release_note

_RN_KEYS="Lay-What Lay-How Lay-Why Tech-What Tech-How Tech-Why"
_RN_DOC="csi-spl-doc/doc/help/release-notes.md"
_RN_NOTES_REF="release-notes"
# The commit that adds this line made the part refuse (spec 065 L11): the
# anchor of RELEASE_NOTE_BASE=switch. Keep the line; renaming it moves the anchor.
_RN_SWITCH_MARK="release notes required"

# The trailers of a message: '<Key>\t<value>' for each 'Key: value' line of its
# LAST paragraph (trailing blank lines ignored). Parsed here rather than by
# 'git interpret-trailers' so an EMPTY 'Lay-How:' is seen and reported as empty
# instead of vanishing into "missing".
_rn_trailers() {  # <message on stdin>
  awk '
    { lines[NR] = $0 }
    END {
      n = NR; while (n > 0 && lines[n] ~ /^[[:space:]]*$/) n--
      s = n; while (s > 0 && lines[s] !~ /^[[:space:]]*$/) s--
      for (i = s + 1; i <= n; i++)
        if (match(lines[i], /^[A-Za-z][A-Za-z0-9-]*:/)) {
          k = substr(lines[i], 1, RLENGTH - 1); v = substr(lines[i], RLENGTH + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          printf "%s\t%s\n", k, v
        }
    }'
}

# The value of trailer <key> (case-insensitive) in a '<Key>\t<value>' list;
# returns 1 when the key is absent.
_rn_val() {  # <key> <trailers>
  awk -F'\t' -v k="$1" 'tolower($1) == tolower(k) { print $2; f = 1; exit } END { exit !f }' <<<"$2"
}

# The verdict of one commit: prints '<kind>' and, when the note falls short,
# '<kind>\t<what is wrong>'. kind = merge | revert | skip | doc | full.
_rn_commit() {  # <tree> <sha>
  local tree="$1" sha="$2" msg tr kind need k v missing="" empty="" files
  if [[ "$(git -C "$tree" rev-list --parents -n1 "$sha" | wc -w)" -gt 2 ]]; then
    echo merge; return 0
  fi
  msg="$(git -C "$tree" log -1 --format=%B "$sha")"
  # a note on refs/notes/release-notes (the fix after the push) wins
  if ! tr="$(git -C "$tree" notes --ref="$_RN_NOTES_REF" show "$sha" 2>/dev/null | _rn_trailers)" || [[ -z "$tr" ]]; then
    tr="$(_rn_trailers <<<"$msg")"
  fi
  if grep -qE '^This reverts commit [0-9a-f]{7,}' <<<"$msg" || [[ "$msg" == 'Revert "'* ]]; then
    kind=revert need="Lay-Why"
  elif [[ "$(_rn_val Release-Note "$tr" | tr '[:upper:]' '[:lower:]')" == skip ]]; then
    kind=skip need="Lay-Why"
  else
    files="$(git -C "$tree" diff-tree --no-commit-id --name-only -r --root "$sha")"
    if [[ -n "$files" ]] && ! grep -qvE '\.md$' <<<"$files"; then
      kind=doc need="Lay-What Lay-Why"
    else
      kind=full need="$_RN_KEYS"
    fi
  fi
  for k in $need; do
    if ! v="$(_rn_val "$k" "$tr")"; then
      missing+="${missing:+ }$k"
    elif [[ -z "$v" ]]; then
      empty+="${empty:+ }$k"
    fi
  done
  if [[ -z "$missing$empty" ]]; then echo "$kind"; return 0; fi
  printf '%s\t%s%s%s\n' "$kind" "${missing:+missing $missing}" "${missing:+${empty:+; }}" "${empty:+empty $empty}"
}


# The copy-paste template the refusal prints: the six trailers, one line each,
# to fill in and paste as the LAST paragraph of the message.
_rn_template() {
  echo "release-note template (paste as the LAST paragraph of the message, one line each, none empty):"
  echo "Lay-What: <what changed, in words a non-developer understands>"
  echo "Lay-How: <how it works now, no code names, ids or jargon>"
  echo "Lay-Why: <why it was needed>"
  echo "Tech-What: <the module and what changed in it>"
  echo "Tech-How: <the mechanism>"
  echo "Tech-Why: <the root cause>"
}

# Check base..HEAD. Prints the per-commit verdicts and the RELEASE_NOTE_CHECK
# line; sets _RN_COMMITS and _RN_WARN for the caller. Returns 1 when <mode> is
# refuse and a commit lacks its note (or the base does not resolve), else 0.
_rn_check() {  # <tree> <base> [refuse|warn]
  local tree="$1" base="$2" mode="${3:-refuse}" sha out kind why subj bsha hsha lvl=WARN
  local ok=0 doc=0 skip=0 revert=0 merge=0
  [[ "$mode" == refuse ]] && lvl=FAIL
  _RN_COMMITS=0 _RN_WARN=0
  if ! bsha="$(git -C "$tree" rev-parse -q --verify --short "$base^{commit}" 2>/dev/null)"; then
    echo "RELEASE_NOTE_CHECK mode=$mode base=unknown head=? commits=0 ok=0 doc=0 skip=0 revert=0 merge=0 warn=0"
    do_log "$lvl release-note: cannot resolve the base '$base' -- nothing checked"
    [[ "$mode" == refuse ]] && return 1
    return 0
  fi
  hsha="$(git -C "$tree" rev-parse --short HEAD 2>/dev/null || echo '?')"
  while IFS= read -r sha; do
    [[ -n "$sha" ]] || continue
    out="$(_rn_commit "$tree" "$sha")"
    kind="${out%%$'\t'*}"
    [[ "$kind" == merge ]] && { merge=$((merge + 1)); continue; }
    _RN_COMMITS=$((_RN_COMMITS + 1))
    if [[ "$out" == *$'\t'* ]]; then
      why="${out#*$'\t'}"; _RN_WARN=$((_RN_WARN + 1))
      subj="$(git -C "$tree" log -1 --format=%s "$sha" | cut -c1-72)"
      do_log "$lvl release-note: ${sha:0:8} ($kind) $why -- $subj"
      continue
    fi
    case "$kind" in
      doc) doc=$((doc + 1)) ;; skip) skip=$((skip + 1)) ;; revert) revert=$((revert + 1)) ;; *) ok=$((ok + 1)) ;;
    esac
  done < <(git -C "$tree" rev-list --reverse "$base..HEAD" 2>/dev/null)
  echo "RELEASE_NOTE_CHECK mode=$mode base=$bsha head=$hsha commits=$_RN_COMMITS ok=$ok doc=$doc skip=$skip revert=$revert merge=$merge warn=$_RN_WARN"
  [[ "$_RN_WARN" -gt 0 ]] || return 0
  if [[ "$mode" != refuse ]]; then
    do_log "WARN release-note: $_RN_WARN of $_RN_COMMITS commit(s) lack their release note (RELEASE_NOTE_MODE=warn, a measurement). The rule: $_RN_DOC"
    return 0
  fi
  do_log "FAIL release-note: $_RN_WARN of $_RN_COMMITS commit(s) lack their release note -- the push is REFUSED (spec 065 L11). Add the trailers named above as the LAST paragraph of each message: the last commit with 'git commit --amend', an older one with 'git rebase -i $bsha' and 'reword' on its line; then push again. The six trailers and the special forms (doc-only, Release-Note: skip, revert): $_RN_DOC"
  _rn_template
  return 1
}

# The pre-push part: one verdict line in the pre-push log and one summary row.
# Called by do_check_pre_push; a commit without its note is a FAIL counted in
# _PP_FAILED, so the push is refused. Returns 1 on that refusal.
_pp_release_note() {  # <tree> <base>
  local start="$SECONDS" el rc=0
  if [[ -z "$(git -C "$1" rev-list -n1 "$2..HEAD" 2>/dev/null)" ]]; then
    _pp_verdict release-note SKIP-untouched 0
    return 0
  fi
  _rn_check "$1" "$2" refuse || rc=$?
  el=$((SECONDS - start))
  if [[ "$rc" -ne 0 ]]; then
    _pp_verdict release-note FAIL "$el" "commits=$_RN_COMMITS warn=$_RN_WARN"
    _pp_record "release-note ($_RN_WARN of $_RN_COMMITS commits lack the note: $_RN_DOC)" FAIL "$el"
    _PP_FAILED=$((_PP_FAILED + 1))
    return 1
  fi
  _pp_verdict release-note PASS "$el" "commits=$_RN_COMMITS warn=0"
  _pp_record "release-note ($_RN_COMMITS commits)" PASS "$el"
  return 0
}

# The commit that made the part refuse: the oldest one that added the
# _RN_SWITCH_MARK line to this file. Empty when the history does not hold it.
_rn_switch_anchor() {  # <tree>
  git -C "$1" log --format=%H -S"_RN_SWITCH_MARK=\"$_RN_SWITCH_MARK\"" \
    -- ':/csi-spl-iac/src/bash/run/check-release-note.func.sh' 2>/dev/null | tail -n 1
}

do_check_release_note() {
  local tree="${RELEASE_NOTE_TREE:-$APP_PATH}"
  local base="${RELEASE_NOTE_BASE:-${PRE_PUSH_BASE:-origin/master}}"
  local mode="${RELEASE_NOTE_MODE:-refuse}"
  case "$mode" in refuse|warn) ;; *) do_log "FATAL release-note: RELEASE_NOTE_MODE must be refuse or warn (got '$mode')"; return 2 ;; esac
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 \
    || { do_log "FATAL release-note: $tree is not a git checkout"; return 2; }
  if [[ "$base" == switch ]]; then
    base="$(_rn_switch_anchor "$tree")"
    [[ -n "$base" ]] \
      || { do_log "FATAL release-note: no commit adds _RN_SWITCH_MARK in $tree (a shallow clone? fetch-depth: 0)"; return 2; }
    do_log "INFO release-note: checking every commit since the switch ${base:0:9}"
  fi
  _rn_check "$tree" "$base" "$mode"
}
