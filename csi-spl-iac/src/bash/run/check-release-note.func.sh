#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The pre-push part `release-note` (spec 065 L2), WARNING mode: every
# @description commit in the pushed range must carry its release note as the six
# @description trailers of csi-spl-doc/doc/help/release-notes.md (Lay-What,
# @description Lay-How, Lay-Why, Tech-What, Tech-How, Tech-Why), one line each
# @description and never empty, in the LAST paragraph of the message -- or one
# @description of that doc's special forms (section 3, spec 065 section 5.2):
# @description   merge      skipped (trunk is linear)
# @description   revert     the git revert message + Lay-Why
# @description   skip       'Release-Note: skip' + Lay-Why (test-, CI-only, baselines)
# @description   doc-only   every touched path is .md: Lay-What + Lay-Why
# @description WARNING mode (owner answer Q4, 2026-10-03: one week of warnings,
# @description then refuse -- spec 065 L11 flips it): it prints which commit
# @description lacks which trailer and ALWAYS returns 0; it never blocks a push.
# @description One machine-readable line per run, the week's compliance n:
# @description   RELEASE_NOTE_CHECK mode=warn base=<sha> head=<sha> commits=<n>
# @description     ok=<n> doc=<n> skip=<n> revert=<n> merge=<n> warn=<n>
# @description   (commits excludes merges; compliance = (commits - warn) / commits)
# @description No cache: it reads only the messages of the pushed commits (one
# @description git call each, well under a second), and it is selected by the
# @description range having commits, not by paths.
# @param RELEASE_NOTE_TREE (optional) - checkout root, default $APP_PATH
# @param RELEASE_NOTE_BASE (optional) - range base, default $PRE_PUSH_BASE or origin/master
# @example ./run -a do_check_release_note
# @example RELEASE_NOTE_BASE=HEAD~5 ./run -a do_check_release_note
#------------------------------------------------------------------------------

_RN_KEYS="Lay-What Lay-How Lay-Why Tech-What Tech-How Tech-Why"
_RN_DOC="csi-spl-doc/doc/help/release-notes.md"

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
  tr="$(_rn_trailers <<<"$msg")"
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

# Check base..HEAD. Prints the per-commit warnings and the RELEASE_NOTE_CHECK
# line; sets _RN_COMMITS and _RN_WARN for the caller. Always returns 0.
_rn_check() {  # <tree> <base>
  local tree="$1" base="$2" sha out kind why subj bsha hsha
  local ok=0 doc=0 skip=0 revert=0 merge=0
  _RN_COMMITS=0 _RN_WARN=0
  if ! bsha="$(git -C "$tree" rev-parse -q --verify --short "$base^{commit}" 2>/dev/null)"; then
    echo "RELEASE_NOTE_CHECK mode=warn base=unknown head=? commits=0 ok=0 doc=0 skip=0 revert=0 merge=0 warn=0"
    do_log "WARN release-note: cannot resolve the base '$base' -- nothing checked (WARN only)"
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
      do_log "WARN release-note: ${sha:0:8} ($kind) $why -- $subj"
      continue
    fi
    case "$kind" in
      doc) doc=$((doc + 1)) ;; skip) skip=$((skip + 1)) ;; revert) revert=$((revert + 1)) ;; *) ok=$((ok + 1)) ;;
    esac
  done < <(git -C "$tree" rev-list --reverse "$base..HEAD" 2>/dev/null)
  echo "RELEASE_NOTE_CHECK mode=warn base=$bsha head=$hsha commits=$_RN_COMMITS ok=$ok doc=$doc skip=$skip revert=$revert merge=$merge warn=$_RN_WARN"
  if [[ "$_RN_WARN" -gt 0 ]]; then
    do_log "WARN release-note: $_RN_WARN of $_RN_COMMITS commit(s) lack their release note (WARNING mode, not blocking). The rule, and how to fix a pushed commit with a git note: $_RN_DOC"
  fi
  return 0
}

# The pre-push part: one verdict line in the pre-push log and one summary row.
# Called by do_check_pre_push; never fails the push.
_pp_release_note() {  # <tree> <base>
  local start="$SECONDS" el
  if [[ -z "$(git -C "$1" rev-list -n1 "$2..HEAD" 2>/dev/null)" ]]; then
    _pp_verdict release-note SKIP-untouched 0
    return 0
  fi
  _rn_check "$1" "$2"
  el=$((SECONDS - start))
  if [[ "$_RN_WARN" -gt 0 ]]; then
    _pp_verdict release-note WARN-release-note "$el" "commits=$_RN_COMMITS warn=$_RN_WARN"
    _pp_record "release-note (WARN only: $_RN_WARN of $_RN_COMMITS commits lack the note)" WARN "$el"
  else
    _pp_verdict release-note PASS "$el" "commits=$_RN_COMMITS warn=0"
    _pp_record "release-note ($_RN_COMMITS commits)" PASS "$el"
  fi
  return 0
}

do_check_release_note() {
  local tree="${RELEASE_NOTE_TREE:-$APP_PATH}"
  local base="${RELEASE_NOTE_BASE:-${PRE_PUSH_BASE:-origin/master}}"
  git -C "$tree" rev-parse --git-dir >/dev/null 2>&1 \
    || { do_log "FATAL release-note: $tree is not a git checkout"; return 2; }
  _rn_check "$tree" "$base"
}
