#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The WUI-LANG-REVIEW part of do_check_pre_push (SPL-5551, csitea
# @description weekly item 11): new WUI text gets its language check
# @description BEFORE it lands, not after. 15 language-fix commits followed a
# @description land (c-518's count in SPL-5505, e.g. 15151a0e8, 8ad692de1).
# @description The language rule itself (the check is Google Cloud
# @description Translation since SPL-6174, owner msg 36b3ff7f; agy optional)
# @description lives in the fleet CLAUDE.md source 20-spawn-an-agent.md; this
# @description part only checks the record of it.
# @description Per non-merge commit of the range that touches
# @description csi-spl-wui/i18n/locales/*.json and carries no review line,
# @description it compares each changed locale file at the commit and at its
# @description parent key by key (../scripts/lang-review-keys.py, one process
# @description per range). A key that is new, or whose value changed, COUNTS.
# @description A commit with counted keys needs a body or trailer line
# @description   Lang-review: gct <run id>
# @description (SPL-6174: the run of csi-spl-orc do_spl_lang_review_gct; its
# @description report csi-spl-wui/i18n/lang-review/<run id>.json must be in
# @description the commit's tree, mark no placeholder failure, hold rows as
# @description the action writes them (mark match/differs; en, text,
# @description reference, back non-empty) and cover every non-English key the
# @description commit adds or changes, and every en key it adds or changes for
# @description each locale holding it, with the en and locale text as
# @description committed; the {placeholders} are checked again against
# @description en.json: ../scripts/lang-review-gct-check.py), or
# @description   Lang-review: a-NNN <msg id>
# @description (an agy seat that reviewed the text, its message id, 8+ hex).
# @description A Claude seat stands in only with the owner's waiver on the
# @description same line (SPL-5767; first case: answer B, t1 028ac340 msg
# @description 3a71dac1, for SPL-5706 + SPL-5707), and the agy review still
# @description follows:
# @description   Lang-review: c-NNN <msg id> waiver <owner msg id>
# @description A bare c-NNN line, a waiver with no id or any other seat
# @description prefix does not count.
# @description Exempt: a commit that only removes keys; a commit whose every
# @description counted key is in en.json and listed under 'keys' of
# @description csi-spl-wui/i18n/i18n-lang-review-exempt.json (en-only typo
# @description fixes); a commit listed by its full sha under 'commits' there
# @description (a landed commit whose review was recorded afterwards, so CI
# @description goes green again without rewriting history). The list is read
# @description at the tree's HEAD. A locale file that is not valid JSON at the
# @description commit counts as changed. Exit 1 prints one line per refused
# @description commit, saying how to get the review.
# @description Two callers: the pre-push part (PRE_PUSH_BASE..HEAD, every
# @description tier, selected when the push touches the locales, never
# @description cached) and CI workflow 10 job wui-lang-review, which checks
# @description every commit since the gate landed (the commit that added the
# @description exempt list), so a hook bypass still turns CI red.
# @param LANG_REVIEW_TREE (optional) - checkout root, default $APP_PATH
# @param LANG_REVIEW_RANGE (optional) - the commits to check, default <the
# @param        commit that added the exempt list>..HEAD (needs fetch-depth 0)
# @example ./run -a do_check_pre_push_lang_review
# @example LANG_REVIEW_RANGE=origin/master..HEAD ./run -a do_check_pre_push_lang_review
#------------------------------------------------------------------------------

_PPR_LOCALES=csi-spl-wui/i18n/locales
_PPR_EXEMPT=csi-spl-wui/i18n/i18n-lang-review-exempt.json
_PPR_REPORTS=csi-spl-wui/i18n/lang-review
_PPR_KEYS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lang-review-keys.py"
_PPR_GCT_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lang-review-gct-check.py"
# a-NNN[@box] <msg id>, or c-NNN[@box] <msg id> waiver <owner msg id> (SPL-5767).
# Both callers (the pre-push range and the CI range) read this one pattern.
# gct <run id> (SPL-6174) is the other form; it holds only with its report.
_PPR_GCT_RX='^Lang-review:[[:space:]]+gct[[:space:]]+([0-9]{8}T[0-9]{6}Z-[0-9a-f]{8})([[:space:]]|$)'
_PPR_LINE_RX='^Lang-review:[[:space:]]+(a-[0-9]{3}(@[A-Za-z0-9._-]+)?[[:space:]]+[0-9a-f]{8}|c-[0-9]{3}(@[A-Za-z0-9._-]+)?[[:space:]]+[0-9a-f]{8}[0-9a-f-]*[[:space:]]+waiver[[:space:]]+[0-9a-f]{8})'

# The keys each commit adds or changes, "<sha><TAB><file><TAB><key>" per line
# (lang-review-keys.py, one process for the whole list).
_ppr_keys() {  # <tree> <sha>...
  local tree="$1"; shift
  [[ "$#" -gt 0 ]] || return 0
  python3 "$_PPR_KEYS_PY" "$tree" "$_PPR_LOCALES" "$@"
}

# Does the commit message carry an agy review line?
_ppr_has_line() {  # <tree> <sha>
  local l
  while IFS= read -r l; do
    [[ "$l" =~ $_PPR_LINE_RX ]] && return 0
  done < <(git -C "$1" log -1 --format=%B "$2")
  return 1
}

# The run id of the commit's first 'Lang-review: gct <run id>' line, or
# nothing (return 1).
_ppr_gct_id() {  # <tree> <sha>
  local l
  while IFS= read -r l; do
    [[ "$l" =~ $_PPR_GCT_RX ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  done < <(git -C "$1" log -1 --format=%B "$2")
  return 1
}

# A gct line holds when its report does (lang-review-gct-check.py); one line.
_ppr_check_gct() {  # <tree> <sha> <run id> <subject>
  local why
  if why="$(python3 "$_PPR_GCT_PY" "$1" "$_PPR_LOCALES" "$_PPR_REPORTS" "$2" "$3" 2>&1)"; then
    echo "wui-lang-review: PASS ${2:0:9} checked by gct $3: $4"; return 0
  fi
  why="${why//$'\n'/; }"
  echo "wui-lang-review: FAIL ${2:0:9} 'Lang-review: gct $3' does not hold: ${why:-the check failed} -- run cd csi-spl-orc && ./run -a do_spl_lang_review_gct again on the committed text and commit its report: $4"
  return 1
}

# Exempt by the list at HEAD: the commit's full sha under 'commits', or every
# counted key in en.json and under 'keys'.
_ppr_exempt() {  # <tree> <sha> <keys>
  local list f k
  list="$(git -C "$1" show "HEAD:$_PPR_EXEMPT" 2>/dev/null)" || return 1
  jq -e --arg c "$2" '(.commits // {}) | has($c)' <<<"$list" >/dev/null 2>&1 && return 0
  while IFS=$'\t' read -r f k; do
    [[ "$f" == "$_PPR_LOCALES/en.json" ]] || return 1
    jq -e --arg k "$k" '(.keys // {}) | has($k)' <<<"$list" >/dev/null 2>&1 || return 1
  done <<<"$3"
  return 0
}

# Check every commit of <range> that touches the locales; one line each. A
# commit with the line needs no key diff, so the CI range (every commit since
# the gate landed) costs a key diff only for the commits without it.
_ppr_check_range() {  # <tree> <range>
  local tree="$1" range="$2" c keys all n first subj gid bad=0 seen=0
  local -a shas=() todo=()
  local -A gct=()
  mapfile -t shas < <(git -C "$tree" rev-list --reverse --no-merges "$range" -- "$_PPR_LOCALES" 2>/dev/null)
  for c in "${shas[@]}"; do
    _ppr_has_line "$tree" "$c" && continue
    if gid="$(_ppr_gct_id "$tree" "$c")"; then gct[$c]="$gid"; else todo+=("$c"); fi
  done
  all="$(_ppr_keys "$tree" "${todo[@]}")" ||
    { echo "wui-lang-review: FAIL the key diff (lang-review-keys.py) failed on $range"; return 1; }
  for c in "${shas[@]}"; do
    subj="$(git -C "$tree" log -1 --format=%s "$c")"
    if [[ -n "${gct[$c]:-}" ]]; then
      seen=$((seen + 1)); _ppr_check_gct "$tree" "$c" "${gct[$c]}" "$subj" || bad=$((bad + 1)); continue
    fi
    if [[ " ${todo[*]} " != *" $c "* ]]; then
      seen=$((seen + 1)); echo "wui-lang-review: PASS ${c:0:9} reviewed: $subj"; continue
    fi
    keys="$(awk -F'\t' -v s="$c" '$1 == s { print $2 "\t" $3 }' <<<"$all")"
    if [[ -z "$keys" ]]; then
      echo "wui-lang-review: PASS ${c:0:9} removes keys only: $subj"; continue
    fi
    seen=$((seen + 1))
    n="$(wc -l <<<"$keys")"; first="${keys%%$'\n'*}"; first="${first/$'\t'/ }"
    if _ppr_exempt "$tree" "$c" "$keys"; then
      echo "wui-lang-review: PASS ${c:0:9} $n key(s), exempt by $_PPR_EXEMPT: $subj"
    else
      bad=$((bad + 1))
      echo "wui-lang-review: FAIL ${c:0:9} adds or changes $n locale key(s) (first: $first) with no 'Lang-review: gct <run id>' line -- run the language check (cd csi-spl-orc && ENV=dev ./run -a do_spl_lang_review_gct), fold its references in, run it again on the final text, commit its report (csi-spl-wui/i18n/lang-review/<run id>.json) with the change and put its printed 'Lang-review: gct <run id>' line in the commit body (an agy review still counts: 'Lang-review: a-NNN <msg id>'): $subj"
    fi
  done
  echo "WUI_LANG_REVIEW range=$range commits=$seen refused=$bad"
  [[ "$bad" -eq 0 ]]
}

# The pre-push part: this push's commits. On the base worktree HEAD is the
# base, so the range is empty and a refusal is never "pre-existing".
_pp_part_wui_lang_review() {  # <tree>
  local tree="$1" base="${PRE_PUSH_BASE:-origin/master}"
  git -C "$tree" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 ||
    { echo "wui-lang-review: WARN unknown base '$base' -- no outgoing commits to check"; return 0; }
  _ppr_check_range "$tree" "$base..HEAD"
}

# The commit that added the exempt list: where the gate starts (CI).
_ppr_anchor() {  # <tree>
  git -C "$1" log --diff-filter=A --format=%H -- "$_PPR_EXEMPT" 2>/dev/null | tail -n 1
}

do_check_pre_push_lang_review() {
  local tree="${LANG_REVIEW_TREE:-$APP_PATH}" range="${LANG_REVIEW_RANGE:-}" anchor
  local t; for t in jq python3; do
    command -v "$t" >/dev/null 2>&1 || { do_log "FATAL wui-lang-review: $t not found (apt-get install $t)"; return 1; }
  done
  if [[ -z "$range" ]]; then
    anchor="$(_ppr_anchor "$tree")"
    [[ -n "$anchor" ]] ||
      { do_log "FATAL wui-lang-review: no commit adds $_PPR_EXEMPT in $tree (a shallow clone? fetch-depth: 0)"; return 1; }
    range="$anchor..HEAD"
  fi
  if ! _ppr_check_range "$tree" "$range"; then
    do_log "FATAL wui-lang-review: new or changed WUI text without its language check (see the FAIL lines)"
    return 1
  fi
  do_log "INFO wui-lang-review: every locale change in $range carries its language review or is exempt"
}
