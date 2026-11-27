#!/bin/bash
#------------------------------------------------------------------------------
# @description On the fleet box a laptop box pulls its Claude login from (the
# @description move box): let ONE laptop key read that login, and nothing else
# @description (SPL-6680, spec 037 "Laptop box"; owner answer Q1 = PUL, the
# @description laptop pulls over ssh, read-only; the laptop is behind her home
# @description network, so this box cannot push). Run on that box as its user
# @description whose sudo -n reaches the agent user (do_spl_agent_cred_sync's
# @description peer rule). grant:
# @description   1. root-owned copies of laptop-login-serve.sh and
# @description      agent-login-cred.sh in LAPTOP_SERVE_LIB (sudo -n), so the
# @description      key's command cannot be changed by this box's users;
# @description   2. one authorized_keys line for the key, tagged
# @description      spl-laptop-box:<tag>: restrict (no shell, no pty, no
# @description      forwarding) + command= that forced command, serving the
# @description      read ops on the cnf's claude login files only
# @description      (env.box.agent_cred_sync.claude.main files + account).
# @description   grant-move: one PLAIN line for the laptop's move key, tagged
# @description   spl-laptop-box-move:<tag>: a shell for do_spl_lane_handover
# @description   (owner HUM-10, form 1cf6af26 = A: "Shell key to sat on her
# @description   laptop: the same session resumes on sat").
# @description   revoke: removes both lines. Idempotent: a second grant
# @description   replaces the line. Dry run unless DRY_RUN=0 (prints the line
# @description   without the key). Needs the owner's go on a live box.
# @param BOX_TAG (required) - the laptop box's tag
# @param LAPTOP_PUBKEY (optional) - the laptop's public key line (do_spl_laptop_box_install prints it); needed by grant
# @param LAPTOP_GRANT_CMD (optional) - grant (default), grant-move or revoke
# @param LAPTOP_SERVE_LIB (optional) - default /usr/local/lib/spl-laptop-box
# @param LAPTOP_AUTH_KEYS (optional) - default $HOME/.ssh/authorized_keys
# @param LAPTOP_ROOT_RUN (tests) - the root runner, default _spool_root_run_as_root
# @param DRY_RUN (optional) - 1 (default) or 0
# @example BOX_TAG=lap-a LAPTOP_PUBKEY="ssh-ed25519 AAAA... spl-laptop-box:lap-a" ./run -a do_spl_laptop_box_login_grant
# @example BOX_TAG=lap-a LAPTOP_GRANT_CMD=revoke DRY_RUN=0 ./run -a do_spl_laptop_box_login_grant
#------------------------------------------------------------------------------
do_spl_laptop_box_login_grant() {
  local tag="${BOX_TAG:-}" cmd="${LAPTOP_GRANT_CMD:-grant}" key="${LAPTOP_PUBKEY:-}" lib="${LAPTOP_SERVE_LIB:-/usr/local/lib/spl-laptop-box}"
  local ak="${LAPTOP_AUTH_KEYS:-$HOME/.ssh/authorized_keys}" dry=1 files line mark tmp
  spl_laptop_box_tag_ok "$tag" || { do_log "FATAL BOX_TAG must be a box tag, got '$tag'"; return 2; }
  [[ "$cmd" =~ ^(grant|grant-move|revoke)$ ]] || { do_log "FATAL LAPTOP_GRANT_CMD must be grant, grant-move or revoke, got '$cmd'"; return 2; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 2; dry=0; fi
  mark="spl-laptop-box:$tag"; [[ "$cmd" == grant-move ]] && mark="spl-laptop-box-move:$tag"
  if [[ "$cmd" == grant-move ]]; then
    [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || { do_log "FATAL LAPTOP_PUBKEY must be one ssh-ed25519 public key line"; return 2; }
    line="${key%% *} $(awk '{print $2}' <<<"$key") $mark"
  fi
  if [[ "$cmd" == grant ]]; then
    [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || { do_log "FATAL LAPTOP_PUBKEY must be one ssh-ed25519 public key line"; return 2; }
    files="$(spl_laptop_serve_files)" || return 1
    line="restrict,command=\"LAPTOP_SERVE_FILES='$files' bash $lib/laptop-login-serve.sh\" ${key%% *} $(awk '{print $2}' <<<"$key") $mark"
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN $cmd for $tag in $ak${files:+: restrict,command=<serve the read ops on $(wc -w <<<"$files") cnf login file(s)>}${line:+ <key> $mark}"
    do_log "OK DRY_RUN nothing was touched; re-run with DRY_RUN=0 (owner's go)"; return 0
  fi
  if [[ "$cmd" == grant ]]; then
    "${LAPTOP_ROOT_RUN:-_spool_root_run_as_root}" "install -d -o root -g root -m 0755 '$lib'" \
      "install -o root -g root -m 0755 '$PROJ_PATH/src/bash/features/laptop-box/laptop-login-serve.sh' '$lib/laptop-login-serve.sh'" \
      "install -o root -g root -m 0755 '$PROJ_PATH/src/bash/scripts/agent-login-cred.sh' '$lib/agent-login-cred.sh'" || return 1
  fi
  mkdir -p "$(dirname "$ak")" && touch "$ak" && chmod 600 "$ak" || return 1
  tmp="$(mktemp "$ak.XXXXXX")" || return 1
  if [[ "$cmd" == revoke ]]; then grep -vE " spl-laptop-box(-move)?:$tag\$" "$ak" >"$tmp"; else grep -v " $mark\$" "$ak" >"$tmp"; fi
  [[ "$cmd" == revoke ]] || printf '%s\n' "$line" >>"$tmp"
  chmod 600 "$tmp" && mv -f "$tmp" "$ak" || { rm -f "$tmp"; return 1; }
  local what="has no key here any more"
  [[ "$cmd" == grant ]] && what="may read this box's Claude login, nothing else"
  [[ "$cmd" == grant-move ]] && what="may hand its lanes over to this box (a shell as this user)"
  do_log "OK $cmd: laptop box $tag $what"
}

# spl_laptop_serve_files: the cnf's claude login files, space-separated (the
# main slot's files plus its account file), each a plain relative path.
spl_laptop_serve_files() {
  local cnf f out=""
  [[ "$(basename "${PROJ_PATH:?}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || { do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  cnf="${LAPTOP_SERVE_CNF:-$APP_PATH/${BASH_REMATCH[1]}-cnf/${BASH_REMATCH[1]}/all.env.yaml}"
  while read -r f; do
    [[ "$f" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ && "$f" != *..* ]] || { do_log "FATAL a cnf login file is not a plain path: '$f'"; return 1; }
    out+="${out:+ }$f"
  done < <(yq -o json '.env.box.agent_cred_sync.claude.main // {}' "$cnf" 2>/dev/null | jq -r '(.files // []) + [.account // empty] | .[]' 2>/dev/null)
  [[ -n "$out" ]] || { do_log "FATAL no cnf env.box.agent_cred_sync.claude.main files in $cnf"; return 1; }
  echo "$out"
}
