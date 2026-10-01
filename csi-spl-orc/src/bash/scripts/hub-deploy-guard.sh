#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the ONE definition of "a hub input" and the forward-only decision of
#          workflow 20 (CLE-77918).
#
# The incident it closes (2026-10-01 ~19:00-19:50Z): both hubs served one
# commit for ~50 min although 20 was green on five later pushes. Each run's
# guard said "trunk head <x> changed hub inputs after <sha> -- standing down":
# it counted EVERY csi-spl-iac / -orc / -cnf change as a hub input and stood
# down whenever trunk had moved on, trusting the newer commit's run to deploy.
# With ~15 lanes pushing, trunk always moved on before a run reached its
# deploy job, so every run stood down and nothing shipped.
#
# Two fixes, both here so the workflow and its test read the same code:
#   1. hub inputs are what the hub IMAGE is built from (do_build_push_hub_image)
#      plus the cnf keys the deploy reads -- not whole trees;
#   2. the decision is made against what the env SERVES (GET /version .commit),
#      not against trunk head: a run deploys whenever its commit carries a hub
#      input the env does not serve yet, even if trunk has moved on. 20's deploy
#      job is serialised per env (concurrency group), so a later run sees the
#      earlier roll as SERVED and stands down only when it is already live --
#      forward-only without starving. Only when the served commit cannot be read
#      does the old trunk-head rule apply; 21 (the catch-up) covers that case.
#
# Usage:
#   hub-deploy-guard.sh paths                -> the hub image pathspecs, one a line
#   hub-deploy-guard.sh changed <from> <to>  -> exit 0 a hub input changed in
#                                               from..to, 1 none, 2 bad input
#   hub-deploy-guard.sh decide               -> "deploy|stand-down <why>";
#                                               exit 0 deploy, 10 stand down, 2 bad input
# Env:
#   APP_PATH    - optional: the repo root (default: the git top level of $PWD)
#   HUB_SQL_SRC - optional: the DDL dir the image bundles (default: cnf
#                 env.hub.image.sql_src in all.env.yaml, else the known dir)
#   SHA         - decide: required, the commit this run would deploy
#   TIP         - decide: optional, trunk head (default: SHA)
#   SERVED      - decide: optional, the commit the env serves now (40 hex), ""
#                 when it could not be read
#------------------------------------------------------------------------------
set -uo pipefail

app="${APP_PATH:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[[ -n "$app" && -d "$app" ]] || { echo "::error::APP_PATH is not a repo"; exit 2; }
cnf_dir="csi-spl-cnf/csi-spl"
cnf_files=(all.env.yaml dev.env.yaml prd.env.yaml)

sql_src() {
  local s="${HUB_SQL_SRC:-}"
  if [[ -z "$s" ]] && command -v yq >/dev/null; then
    s="$(yq -r '.env.hub.image.sql_src // ""' "$app/$cnf_dir/all.env.yaml" 2>/dev/null)"
  fi
  [[ -n "$s" && "$s" != null ]] || s="csi-spl-rdb/src/sql/postgres/spool-hub"
  echo "$s"
}

# What the hub IMAGE is built from (do_build_push_hub_image): the static binary
# (build.sh over the Go module, .version baked in), the DDL dir it bundles and
# the Dockerfile. NOT the api test scripts, NOT spool-hub-roles/, NOT the
# iac/orc/cnf trees as a whole: none of those is in the image.
hub_paths() {
  printf '%s\n' \
    csi-spl-api/src/go \
    csi-spl-api/src/bash/build.sh \
    "$(sql_src)" \
    csi-spl-orc/src/docker/spool-hub-api/Dockerfile \
    .version
}

# The cnf keys the deploy reads for the image: hub.image (name, floor tag,
# sql_src), hub.service_name and the migrations dir baked into the image.
cnf_keys() {  # <sha> <file> -> canonical json of those keys at <sha>
  git -C "$app" show "$1:$cnf_dir/$2" 2>/dev/null |
    yq -o=json -I=0 '[.env.hub.image, .env.hub.service_name, .env.hub.env.SPOOL_HUB_MIGRATIONS_DIR]' 2>/dev/null
}

is_commit() { git -C "$app" cat-file -e "$1^{commit}" 2>/dev/null; }

changed() {  # <from> <to>
  local from="$1" to="$2" f
  is_commit "$from" && is_commit "$to" || { echo "::error::not a commit: $from or $to"; return 2; }
  local -a p=()
  mapfile -t p < <(hub_paths)
  git -C "$app" diff --quiet "$from" "$to" -- "${p[@]}" || return 0
  command -v yq >/dev/null || return 1
  for f in "${cnf_files[@]}"; do
    [[ "$(cnf_keys "$from" "$f")" == "$(cnf_keys "$to" "$f")" ]] || return 0
  done
  return 1
}

decide() {
  local sha="${SHA:-}" tip="${TIP:-${SHA:-}}" served="${SERVED:-}" rc
  is_commit "$sha" || { echo "::error::SHA '$sha' is not a commit"; return 2; }
  is_commit "$tip" || { echo "::error::TIP '$tip' is not a commit"; return 2; }
  sha="$(git -C "$app" rev-parse "$sha^{commit}")"; tip="$(git -C "$app" rev-parse "$tip^{commit}")"
  if [[ "$served" =~ ^[0-9a-f]{40}$ ]] && is_commit "$served"; then
    if [[ "$served" == "$sha" ]] || git -C "$app" merge-base --is-ancestor "$sha" "$served"; then
      echo "stand-down served=${served:0:8} already contains ${sha:0:8}"; return 10
    fi
    if git -C "$app" merge-base --is-ancestor "$served" "$sha"; then
      changed "$served" "$sha"; rc=$?
      (( rc == 2 )) && return 2
      if (( rc == 1 )); then
        echo "stand-down no hub input changed between served=${served:0:8} and ${sha:0:8}"; return 10
      fi
      echo "deploy served=${served:0:8} lacks hub input in ${sha:0:8} (forward; trunk head ${tip:0:8} does not stop it)"
      return 0
    fi
    echo "::notice::served=${served:0:8} is not on the line of ${sha:0:8}; falling back to the trunk-head rule"
  else
    echo "::notice::the served commit is unknown ('${served:0:12}'); falling back to the trunk-head rule"
  fi
  if [[ "$tip" != "$sha" ]]; then
    changed "$sha" "$tip"; rc=$?
    (( rc == 2 )) && return 2
    if (( rc == 0 )); then
      echo "stand-down trunk head ${tip:0:8} changed hub inputs after ${sha:0:8}; its run (or the 21 catch-up) deploys it"
      return 10
    fi
  fi
  echo "deploy ${sha:0:8} (no newer hub input on trunk head ${tip:0:8})"
  return 0
}

case "${1:-}" in
  paths) hub_paths ;;
  changed) [[ $# -eq 3 ]] || { echo "usage: $0 changed <from> <to>"; exit 2; }; changed "$2" "$3" ;;
  decide) decide ;;
  *) echo "usage: $0 paths | changed <from> <to> | decide"; exit 2 ;;
esac
