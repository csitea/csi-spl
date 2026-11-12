#!/bin/bash
# The box's one GitHub credential: the file $HOME/.github/.csi/crs and, in it,
# the one variable ALL_CSI_GITHUB_TOKEN (owner HUM-10, t1 2afa48b4, SPL-5366;
# secrets-round-1.md section 6). Every reader in this repo takes the token
# from here; GH_TOKEN / GITHUB_TOKEN are only set FROM it, for the tools that
# need that exact name. No fallback to another file or to gh's stored login.
# Identical copies: csi-spl-{iac,orc,utl}/lib/bash/funcs/gh-box-token.func.sh
# (gh-box-token-lib.tst.sh keeps them equal). Never prints the token.

# gh_box_token_file - the credential file; GH_BOX_TOKEN_FILE only for tests
gh_box_token_file() { printf '%s\n' "${GH_BOX_TOKEN_FILE:-$HOME/.github/.csi/crs}"; }

# gh_box_token_var - the one variable the file holds the token in
gh_box_token_var() { printf '%s\n' ALL_CSI_GITHUB_TOKEN; }

# gh_box_token_read - prints the token (stdout, for a $(...) only). The file
# is parsed, never sourced: the last `[export ]ALL_CSI_GITHUB_TOKEN=<v>` line,
# <v> unquoted. A missing file or variable fails with the reason on stderr.
gh_box_token_read() {
  local f v tok; f="$(gh_box_token_file)"; v="$(gh_box_token_var)"
  [[ -r "$f" ]] || { echo "FATAL no readable GitHub credential file $f (secrets-round-1.md section 6)" >&2; return 1; }
  tok="$(sed -nE "s/^[[:space:]]*(export[[:space:]]+)?$v=//p" "$f" | tail -n 1)"
  tok="${tok//[[:space:]]/}"; tok="${tok#[\"\']}"; tok="${tok%[\"\']}"
  [[ -n "$tok" ]] || { echo "FATAL $f has no $v=<token> line (secrets-round-1.md section 6)" >&2; return 1; }
  printf '%s\n' "$tok"
}

# gh_box_token_export - a GH_TOKEN the caller already set is kept; else
# GH_TOKEN is exported from the file. Fails (the reason on stderr) when the
# file or the variable is missing.
gh_box_token_export() {
  [[ -n "${GH_TOKEN:-}" ]] && return 0
  local tok; tok="$(gh_box_token_read)" || return 1
  GH_TOKEN="$tok"; export GH_TOKEN
}
