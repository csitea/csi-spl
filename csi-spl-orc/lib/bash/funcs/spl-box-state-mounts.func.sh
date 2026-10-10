#!/bin/bash
#------------------------------------------------------------------------------
# @description THE resolver of the two box state folder names (owner msg
# @description ec950b4b: "They will have a certain name from the point of view
# @description of the Spool codebase"). Exports SPL_BOX_STATE_RO,
# @description SPL_BOX_STATE_RW and SPL_BOX_STATE_RW_PREFIX from cnf
# @description env.box.box_state_mount of $ENV ("~/" = $HOME, %env% = $ENV);
# @description scripts read and write through these names, never a literal
# @description path. Refuses a relative path, "..", and RO / RW that are equal
# @description or nested. Reads $SPL_CNF, merging it first when unset.
# @param ENV - required: dev or prd
# @example spl_box_state_mounts && ls "$SPL_BOX_STATE_RO"
#------------------------------------------------------------------------------
spl_box_state_mounts() {
  spl_require_cloud_env || return 1
  [[ -n "${SPL_CNF:-}" && -s "${SPL_CNF:-}" ]] || do_spl_cloud_cnf || return 1
  local -a v=()
  mapfile -t v < <(yq -r '.env.box.box_state_mount | [.ro_dir, .rw_dir, .rw_prefix] | .[] | (. // "")' "$SPL_CNF")
  [[ ${#v[@]} -eq 3 && -n "${v[0]}" && -n "${v[1]}" && -n "${v[2]}" ]] ||
    { do_log "FATAL cnf env.box.box_state_mount.{ro_dir,rw_dir,rw_prefix} must all be set for $ENV" >&2; return 1; }
  local ro rw pre="${v[2]}"
  ro="$(spl_box_state_dir "${v[0]}")" || return 1
  rw="$(spl_box_state_dir "${v[1]}")" || return 1
  [[ "$ro" != "$rw" && "$ro/" != "$rw"/* && "$rw/" != "$ro"/* ]] ||
    { do_log "FATAL the RO dir $ro and the RW dir $rw must be two separate folders" >&2; return 1; }
  [[ "$pre" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
    { do_log "FATAL cnf env.box.box_state_mount.rw_prefix must be one plain name ([a-z0-9._-]), got: '$pre'" >&2; return 1; }
  export SPL_BOX_STATE_RO="$ro" SPL_BOX_STATE_RW="$rw" SPL_BOX_STATE_RW_PREFIX="$pre"
}

# spl_box_state_dir <cnf value> -> the absolute dir: "~/" = $HOME, %env% =
# $ENV; refused unless absolute and free of ".."
spl_box_state_dir() {
  local d="$1"
  # shellcheck disable=SC2088 # a literal "~/" in the cnf value, expanded here
  [[ "$d" == "~/"* ]] && d="${HOME:?HOME unset}/${d#"~/"}"
  d="${d//%env%/$ENV}"
  d="${d%/}"
  [[ "$d" == /?* && "/$d/" != */../* ]] ||
    { do_log "FATAL a box state mount dir must be absolute (or start ~/) with no '..', got: '$1'" >&2; return 1; }
  printf '%s' "$d"
}

# spl_box_state_which -> "ro", "rw" or "ro rw" from MOUNT (default both)
spl_box_state_which() {
  case "${MOUNT:-both}" in
    ro) echo ro ;; rw) echo rw ;; both) echo "ro rw" ;;
    *) do_log "FATAL MOUNT must be ro, rw or both, got: '${MOUNT:-}'" >&2; return 1 ;;
  esac
}


#------------------------------------------------------------------------------
# @description The shared start of do_spl_box_state_{ls,get,put,sync}: the
# @description names (spl_box_state_mounts), then SPL_BOX_STATE_BUCKET and
# @description SPL_BOX_STATE_WRITER from cnf step 056. With "gcloud" as $1 it
# @description also pins GCP_ACCOUNT to the env's project SA in a throwaway
# @description CLOUDSDK_CONFIG (never the owner account, never the shared one).
# @param $1 (optional) - gcloud: pin the account too (a real run, not a dry one)
#------------------------------------------------------------------------------
spl_box_state_gs_begin() {
  spl_box_state_mounts || return 1
  SPL_BOX_STATE_BUCKET="$(spl_box_state_cnf state_bucket_name)" || return 1
  SPL_BOX_STATE_WRITER="$(spl_box_state_cnf writer_sa_account_id)@$SPL_PROJECT.iam.gserviceaccount.com" || return 1
  export SPL_BOX_STATE_BUCKET SPL_BOX_STATE_WRITER
  [[ "${1:-}" == gcloud ]] || return 0
  do_require_bin gcloud || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
}

# spl_box_state_rel <name> <value> [empty-ok] -> 0 when value is a relative
# object path: [A-Za-z0-9._/-], no leading /, no "..", no "//"
spl_box_state_rel() {
  local n="$1" v="$2"
  [[ -z "$v" && "${3:-}" == empty-ok ]] && return 0
  [[ "$v" =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]*$ && "/$v/" != */../* && "$v" != *//* ]] ||
    { do_log "FATAL $n must be a relative object path ([A-Za-z0-9._/-], no leading /, no '..'), got: '$v'"; return 1; }
}

# spl_box_state_dest <PREFIX> -> gs://<bucket>/<rw_prefix>/<PREFIX>/: every
# put and sync lands under the RW prefix, never beside a backup
spl_box_state_dest() {
  local p="${1%/}"
  printf 'gs://%s/%s/%s' "$SPL_BOX_STATE_BUCKET" "$SPL_BOX_STATE_RW_PREFIX" "${p:+$p/}"
}

#------------------------------------------------------------------------------
# @description Refuse an upload that would carry a secret (owner rule csitea
# @description fc0119cd msg 072a9990: keys and secrets stay on the box). The
# @description verdict is c-846's box-state-pack.sh, the one exclude list of
# @description the nightly backup: a path it would DROP (.gcp, .ssh, key
# @description files, tokens, .env, NetVisor / bank credentials, a 0600 file
# @description under a home's dot-dirs, key material, unreadable) refuses the
# @description whole upload. A single file is scanned through a symlink at
# @description its own absolute path, so the path rules still see it; a 0600
# @description file is refused outright. Only counts per reason are printed:
# @description a name can say more than it should.
# @param $1 - the local file or dir to upload
# @example spl_box_state_upload_scan "$SRC" || return 3
#------------------------------------------------------------------------------
spl_box_state_upload_scan() {
  local src="$1" pack work dir drops n
  pack="$PROJ_PATH/src/bash/scripts/box-state-pack.sh"
  work="$(umask 077 && mktemp -d)" || return 1
  if [[ -d "$src" ]]; then
    dir="$src"
  else
    [[ "$(stat -c %a "$src")" == *600 ]] &&
      { rm -rf "$work"; do_log "FATAL $src is a 0600 file: secrets stay on the box, upload REFUSED"; return 3; }
    src="$(readlink -f "$src")"
    mkdir -p "$work/f${src%/*}" && ln -s "$src" "$work/f$src" || { rm -rf "$work"; return 1; }
    dir="$work/f"
  fi
  bash "$pack" tar "$dir" >/dev/null 2>"$work/drops"
  n="$(grep -c '^DROP ' "$work/drops")"
  if (( n > 0 )); then
    drops="$(awk '/^DROP /{print $NF}' "$work/drops" | sort | uniq -c | awk '{printf "%s%s=%s", (NR>1?" ":""), $2, $1}')"
    rm -rf "$work"
    do_log "FATAL $n file(s) under $1 must never leave the box ($drops): upload REFUSED, nothing sent. Move them out and retry."
    return 3
  fi
  rm -rf "$work"
}

# spl_box_state_detached <cmd>... -> runs cmd with every fd above 2 closed: the
# gcsfuse daemon must not inherit ./run's tee pipes (it would hold the action
# open for as long as the mount lives)
spl_box_state_detached() {
  (
    local f n
    for f in /proc/self/fd/*; do
      n="${f##*/}"
      (( n > 2 )) && eval "exec $n>&-"
    done 2>/dev/null
    exec "$@" </dev/null
  )
}
