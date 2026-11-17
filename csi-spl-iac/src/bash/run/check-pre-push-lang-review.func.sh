#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The WUI-LANG-REVIEW part of do_check_pre_push (SPL-5551, csitea
# @description weekly item 11): new WUI text gets the agy language review
# @description BEFORE it lands, not after. 15 language-fix commits followed a
# @description land (c-518's count in SPL-5505, e.g. 15151a0e8, 8ad692de1).
# @description The language rule itself (agy has the final word on
# @description multilingual text) lives in the fleet CLAUDE.md source
# @description 20-spawn-an-agent.md; this part only checks the record of it.
# @description Per non-merge commit of the range that touches
# @description csi-spl-wui/i18n/locales/*.json and carries no review line,
# @description it compares each changed locale file at the commit and at its
# @description parent key by key (../scripts/lang-review-keys.py, one process
# @description per range). A key that is new, or whose value changed, COUNTS.
# @description A commit with counted keys needs a body or trailer line
# @description   Lang-review: a-NNN <msg id>
# @description (the agy seat that reviewed the text, its message id, 8+ hex).
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
_PPR_KEYS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/lang-review-keys.py"
# a-NNN[@box] <msg id>, or c-NNN[@box] <msg id> waiver <owner msg id> (SPL-5767).
# Both callers (the pre-push range and the CI range) read this one pattern.
_PPR_LINE_RX='^Lang-review:[[:space:]]+(a-[0-9]{3}(@[A-Za-z0-9._-]+)?[[:space:]]+[0-9a-f]{8}|c-[0-9]{3}(@[A-Za-z0-9._-]+)?[[:space:]]+[0-9a-f]{8}[0-9a-f-]*[[:space:]]+waiver[[:space:]]+[0-9a-f]{8})'

# The keys each commit adds or changes, "<sha><TAB><file><TAB><key>" per line
# (lang-review-keys.py, one process for the whole list).
_ppr_keys() {  # <tree> <sha>...
  local tree="$1"; shift
  [[ "$#" -gt 0 ]] || return 0
  python3 "$_PPR_KEYS_PY" "$tree" "$_PPR_LOCALES" "$@"
}

# Does the commit message carry the review line?
_ppr_has_line() {  # <tree> <sha>
  local l
  while IFS= read -r l; do
    [[ "$l" =~ $_PPR_LINE_RX ]] && return 0
  done < <(git -C "$1" log -1 --format=%B "$2")
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
  local tree="$1" range="$2" c keys all n first subj bad=0 seen=0
  local -a shas=() todo=()
  mapfile -t shas < <(git -C "$tree" rev-list --reverse --no-merges "$range" -- "$_PPR_LOCALES" 2>/dev/null)
  for c in "${shas[@]}"; do _ppr_has_line "$tree" "$c" || todo+=("$c"); done
  all="$(_ppr_keys "$tree" "${todo[@]}")" ||
    { echo "wui-lang-review: FAIL the key diff (lang-review-keys.py) failed on $range"; return 1; }
  for c in "${shas[@]}"; do
    subj="$(git -C "$tree" log -1 --format=%s "$c")"
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
      echo "wui-lang-review: FAIL ${c:0:9} adds or changes $n locale key(s) (first: $first) with no 'Lang-review: a-NNN <msg id>' line -- send the new text to an agy seat for review (/agy-spawn, LANE_MIX_KIND=i18n), apply its verdict, then add its seat id and message id as that line in the commit body (a Claude review counts only with the owner's waiver: 'Lang-review: c-NNN <msg id> waiver <owner msg id>', and the agy review still follows): $subj"
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
    do_log "FATAL wui-lang-review: new or changed WUI text without its agy language review (see the FAIL lines)"
    return 1
  fi
  do_log "INFO wui-lang-review: every locale change in $range carries its language review or is exempt"
}
