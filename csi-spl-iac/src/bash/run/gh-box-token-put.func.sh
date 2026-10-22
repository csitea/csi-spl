#!/bin/bash
#------------------------------------------------------------------------------
# @description One fine-grained GitHub token per box (SPL-2897; the runbook:
# @description secret-rotation.md section 5.2, row 3 of the SPL-1945 order).
# @description Every reader on a box takes the token from one of two places:
# @description the box user's token file $HOME/.github/token (the git
# @description credential helper, the crons' GH_TOKEN, the box playbooks) or
# @description gh's own stored login (gh auth login --with-token). This action
# @description writes both; the proof is do_gh_box_token_check
# @description (gh-box-token-check.func.sh, which also holds the shared
# @description gh_box_token_* helpers). It never prints the token.
# @description
# @description do_gh_box_token_put - reads the NEW token from STDIN only (a
# @description hidden prompt on a terminal); a token on argv is refused, since
# @description ./run logs its argv to the run log. Refuses a token that is not
# @description fine-grained (github_pat_) or that GitHub does not answer to.
# @description DRY_RUN=0 writes the token file (mode 600, atomic), keeps the old
# @description one beside it as token.prev (mode 600, the undo), and re-logs gh
# @description in with the new token when gh holds a stored login.
# @description GH_BOX_TOKEN_DROP_PREV=1 removes token.prev once the old token
# @description is revoked (a dry run unless DRY_RUN=0).
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GH_BOX_TOKEN_DROP_PREV (optional) - 1: remove token.prev, nothing else
# @example DRY_RUN=0 ./run -a do_gh_box_token_put        (paste at the hidden prompt)
#------------------------------------------------------------------------------
do_gh_box_token_put() {
  local dry="${DRY_RUN:-1}" file tok type login
  (( $# == 0 )) || { do_log "FATAL do_gh_box_token_put takes no argument: the token goes on stdin only (./run logs its argv). Nothing written."; return 2; }
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: $dry"; return 2; }
  do_require_bin gh || return 1
  file="$(gh_box_token_file)"
  [[ "${GH_BOX_TOKEN_DROP_PREV:-0}" == 1 ]] && { gh_box_token_drop_prev "$file" "$dry"; return $?; }

  if [[ -t 0 ]]; then
    printf 'Paste the new fine-grained token (not shown), then Enter: ' >&2
    IFS= read -rs tok; printf '\n' >&2
  else
    IFS= read -r tok
  fi
  tok="${tok//[[:space:]]/}"
  [[ -n "$tok" ]] || { do_log "FATAL no token on stdin. Nothing written."; return 1; }
  type="$(gh_box_token_type "$tok")"
  [[ "$type" == fine-grained ]] ||
    { do_log "FATAL the token on stdin is $type, not fine-grained (github_pat_): row 3 puts only a fine-grained token. Nothing written."; return 1; }
  login="$(GH_TOKEN="$tok" gh api user --jq .login 2>/dev/null </dev/null)" && [[ -n "$login" ]] ||
    { do_log "FATAL GitHub does not answer to the token on stdin (gh api user failed): expired, revoked or mistyped. Nothing written."; return 1; }

  if [[ "$dry" == 1 ]]; then
    do_log "INFO DRY_RUN would write $file (mode 600; the old one kept as $file.prev) and re-log gh in when it holds a stored login"
    do_log "OK DRY_RUN the token is fine-grained and answers as $login; nothing written. Re-run with DRY_RUN=0."
    return 0
  fi
  gh_box_token_write "$file" "$tok" || return 1
  do_log "OK wrote $file (mode $(stat -c %a "$file")), a fine-grained token answering as $login"

  if env -u GH_TOKEN -u GITHUB_TOKEN gh auth token -h github.com >/dev/null 2>&1 </dev/null; then
    env -u GH_TOKEN -u GITHUB_TOKEN gh auth login -h github.com --with-token <"$file" >/dev/null 2>&1 ||
      { do_log "FAIL the file is written, but gh's stored login could not be replaced: run ./run -a do_gh_box_token_check"; return 1; }
    do_log "OK gh's stored login now holds the same token"
  else
    do_log "INFO gh holds no stored login on this box: its readers take the file"
  fi
  do_log "OK next: ./run -a do_gh_box_token_check on this box, as every box user that runs agents"
}

# gh_box_token_write <file> <token> - atomic, mode 600; the old file kept as <file>.prev
gh_box_token_write() {
  local file="$1" dir tmp; dir="$(dirname "$1")"
  [[ -e "$file.prev" ]] &&
    { do_log "FATAL $file.prev exists: the last put is not finished. Revoke the old token, then GH_BOX_TOKEN_DROP_PREV=1 DRY_RUN=0 ./run -a do_gh_box_token_put. Nothing written."; return 1; }
  [[ -L "$file" ]] && { do_log "FATAL $file is a symlink. Nothing written."; return 1; }
  ( umask 077; mkdir -p "$dir" ) || { do_log "FATAL cannot create $dir"; return 1; }
  tmp="$(umask 077; mktemp "$dir/.token.XXXXXX")" || { do_log "FATAL cannot write in $dir"; return 1; }
  if ! ( umask 077; printf '%s\n' "$2" >"$tmp" ) || ! chmod 600 "$tmp"; then
    rm -f "$tmp"; do_log "FATAL cannot write the token file"; return 1
  fi
  if [[ -e "$file" ]] && ! { cp -p "$file" "$file.prev" && chmod 600 "$file.prev"; }; then
    rm -f "$tmp"; do_log "FATAL cannot keep the old token as $file.prev. Nothing written."; return 1
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; do_log "FATAL cannot move the new token into $file"; return 1; }
}

# gh_box_token_drop_prev <file> <dry> - remove <file>.prev, the undo copy of the old token
gh_box_token_drop_prev() {
  [[ -e "$1.prev" ]] || { do_log "OK no $1.prev on this box: nothing to drop"; return 0; }
  [[ "$2" == 1 ]] && { do_log "OK DRY_RUN would remove $1.prev. Re-run with DRY_RUN=0."; return 0; }
  rm -f "$1.prev" && do_log "OK removed $1.prev"
}
