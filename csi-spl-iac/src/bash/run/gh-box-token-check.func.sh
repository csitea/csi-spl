#!/bin/bash
#------------------------------------------------------------------------------
# @description One fine-grained GitHub token per box (SPL-2897; the runbook:
# @description secret-rotation.md section 5.2, row 3 of the SPL-1945 order).
# @description The writer is do_gh_box_token_put (gh-box-token-put.func.sh);
# @description this file also holds the gh_box_token_* helpers both share. The
# @description file and the variable: lib/bash/funcs/gh-box-token.func.sh
# @description ($HOME/.github/.csi/crs, ALL_CSI_GITHUB_TOKEN; SPL-5366).
# @description
# @description do_gh_box_token_check - read-only. Calls GitHub with the file's
# @description token and prints the login, the token type (fine-grained,
# @description classic, oauth, app, unknown), its expiry and the repo
# @description permissions it grants; then gh's stored login: its type and
# @description whether it is the same token as the file. Exit 0 only when the
# @description file holds a fine-grained token GitHub answers to and gh's login
# @description is absent or the same token. Never prints the token. gh's login
# @description is read only to compare it: no reader takes the token from it.
# @param GH_BOX_TOKEN_REPO (optional) - <owner>/<repo> to read the permissions
# @param        of, default: parsed from the checkout's `origin` remote
# @example ./run -a do_gh_box_token_check
#------------------------------------------------------------------------------
do_gh_box_token_check() {
  local file tok="" login="" gtok same rc=0
  (( $# == 0 )) || { do_log "FATAL do_gh_box_token_check takes no argument"; return 2; }
  do_require_bin gh || return 1
  file="$(gh_box_token_file)"
  if tok="$(gh_box_token_read 2>/dev/null)"; then
    login="$(gh_box_token_check_file "$file" "$tok")" || rc=1
  else
    do_log "FAIL no readable $(gh_box_token_var) in $file on this box"; rc=1
  fi

  if gtok="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token -h github.com 2>/dev/null </dev/null)" && [[ -n "$gtok" ]]; then
    if [[ "$gtok" == "$tok" ]]; then same=yes; else same=no; fi
    do_log "INFO gh stored login: type=$(gh_box_token_type "$gtok") same-as-file=$same"
    [[ "$same" == yes ]] || { do_log "FAIL gh's stored login is another token than the file: git on this box uses another token than the readers"; rc=1; }
  else
    do_log "INFO gh stored login: none"
  fi
  [[ -e "$file.prev" ]] && do_log "INFO $file.prev is still on this box (drop it once the old token is revoked)"
  (( rc == 0 )) && do_log "OK this box answers GitHub with its own fine-grained token as $login"
  return $rc
}

# gh_box_token_check_file <file> <token> - logs what GitHub says of the file's
# token; prints the login on stdout; non-zero unless it is a fine-grained
# token GitHub answers to, in a file other users cannot read
gh_box_token_check_file() {
  local file="$1" tok="$2" type login hdr exp repo perms mode rc=0
  mode="$(stat -c %a "$file")"
  [[ "${mode: -1}" == 0 ]] || { do_log "FAIL $file has mode $mode: other users can read it" >&2; rc=1; }
  type="$(gh_box_token_type "$tok")"
  login="$(GH_TOKEN="$tok" gh api user --jq .login 2>/dev/null </dev/null)" && [[ -n "$login" ]] ||
    { do_log "FAIL file token: type=$type, GitHub does not answer to it (gh api user failed)" >&2; return 1; }
  hdr="$(GH_TOKEN="$tok" gh api -i user 2>/dev/null </dev/null)" || hdr=""
  exp="$(sed -nE 's/^[Gg]ithub-[Aa]uthentication-[Tt]oken-[Ee]xpiration: *(.*[^[:space:]])[[:space:]]*$/\1/p' <<<"$hdr")"
  exp="${exp%%$'\n'*}"
  repo="$(gh_box_token_repo)"
  if [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    perms="$(GH_TOKEN="$tok" gh api "repos/$repo" --jq '.permissions | to_entries | map(select(.value) | .key) | join(",")' 2>/dev/null </dev/null)" || perms="cannot read the repo"
  else
    perms="no repo (set GH_BOX_TOKEN_REPO)"; repo="-"
  fi
  do_log "INFO file token: login=$login type=$type expires=${exp:-never} repo=$repo permissions=${perms:-none}" >&2
  [[ "$type" == fine-grained ]] || { do_log "FAIL file token is $type, not fine-grained: row 3 is not done on this box" >&2; rc=1; }
  printf '%s\n' "$login"
  return $rc
}

# gh_box_token_type <token> - from its documented prefix only; prints no part of it
gh_box_token_type() {
  case "$1" in
    github_pat_*) echo fine-grained ;;
    ghp_*) echo classic ;;
    gho_*) echo oauth ;;
    ghs_* | ghu_*) echo app ;;
    *) echo unknown ;;
  esac
}

# the repo: GH_BOX_TOKEN_REPO, else the origin remote of the checkout
gh_box_token_repo() {
  if [[ -n "${GH_BOX_TOKEN_REPO:-}" ]]; then printf '%s\n' "$GH_BOX_TOKEN_REPO"; return 0; fi
  local url; url="$(git -C "${APP_PATH:-.}" remote get-url origin 2>/dev/null)" || return 0
  sed -nE 's#^.*github\.com[:/]([^/]+/[^/]+)$#\1#p' <<<"${url%.git}"
}
