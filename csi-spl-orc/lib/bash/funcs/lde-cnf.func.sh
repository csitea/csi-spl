#!/bin/bash
#------------------------------------------------------------------------------
# @description Resolve the LOCAL (lde) stack's settings for THIS git tree and
# @description export them as LDE_* variables. The values come from
# @description csi-spl-cnf/csi-spl/lde.env.yaml deep-merged over all.env.yaml
# @description (csi-spl-iac's do_spl_merged_cnf, the one merge every consumer
# @description uses); nothing here restates a cnf value.
# @description
# @description ORG and APP are read from this project's own directory name
# @description (<org>-<app>-orc), never from the checkout's basename: in a git
# @description worktree the checkout is named after the branch.
# @description
# @description Per tree: the compose project and the state dir carry a tree
# @description slug, so two checkouts never share containers or volumes. Host
# @description ports come from cnf and can be overridden per tree with
# @description LDE_PG_PORT / LDE_GCS_PORT / LDE_HUB_PORT when two trees run at once.
# @param PROJ_PATH - set by run.sh: the csi-spl-orc dir
# @param APP_PATH - set by run.sh: the checkout root
# @param LDE_STATE_DIR (optional) - default: $HOME/.local/share/<org>-<app>/lde/<tree-slug>
# @example do_lde_cnf && echo "$LDE_COMPOSE_PROJECT $LDE_HUB_PORT"
#------------------------------------------------------------------------------
do_lde_cnf() {
  local proj_base
  proj_base="$(basename "${PROJ_PATH:?PROJ_PATH unset}")"
  [[ "$proj_base" =~ ^([a-z]+)-([a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH (expected <org>-<app>-orc)"; return 1; }
  LDE_ORG="${BASH_REMATCH[1]}" LDE_APP="${BASH_REMATCH[2]}"
  LDE_ORG_APP="$LDE_ORG-$LDE_APP"
  LDE_CNF_DIR="$APP_PATH/$LDE_ORG_APP-cnf/$LDE_ORG_APP"
  local merge_fn="$APP_PATH/$LDE_ORG_APP-iac/lib/bash/funcs/spl-merged-cnf.func.sh"
  [[ -f "$merge_fn" ]] || { do_log "FATAL missing $merge_fn"; return 1; }
  # shellcheck disable=SC1090
  source "$merge_fn"

  local tree_base slug
  tree_base="$(basename "$APP_PATH")"
  # the main checkout is named <org>-<app>; a worktree is named after its lane
  if [[ "$tree_base" == "$LDE_ORG_APP" ]]; then slug=main
  else slug="$(tr '[:upper:]' '[:lower:]' <<<"$tree_base" | tr -c 'a-z0-9\n' '-')"; fi
  LDE_TREE_SLUG="$slug"
  LDE_STATE_DIR="${LDE_STATE_DIR:-$HOME/.local/share/$LDE_ORG_APP/lde/$slug}"
  mkdir -p "$LDE_STATE_DIR" || return 1
  LDE_CNF="$LDE_STATE_DIR/lde.env.yaml"
  do_spl_merged_cnf "$LDE_CNF_DIR" lde "$LDE_CNF" || { do_log "FATAL cannot merge the lde cnf"; return 1; }

  _lde_get() { yq -r "$1 // \"\"" "$LDE_CNF"; }
  LDE_COMPOSE_PROJECT="$(_lde_get .env.lde.compose_project)-$slug"
  LDE_PG_IMAGE="$(_lde_get .env.lde.pg.image)"
  LDE_PG_PORT="${LDE_PG_PORT:-$(_lde_get .env.lde.pg.host_port)}"
  LDE_PG_DB="$(_lde_get .env.lde.pg.db)"
  LDE_PG_USER="$(_lde_get .env.lde.pg.user)"
  LDE_PG_PASSWORD="$(_lde_get .env.lde.pg.password)"
  LDE_GCS_IMAGE="$(_lde_get .env.lde.gcs.image)"
  LDE_GCS_PORT="${LDE_GCS_PORT:-$(_lde_get .env.lde.gcs.host_port)}"
  LDE_HUB_PORT="${LDE_HUB_PORT:-$(_lde_get .env.lde.hub.host_port)}"
  LDE_HUB_CONTAINER_PORT="$(_lde_get .env.hub.cloud_run.port)"
  LDE_SMOKE_TENANT="$(_lde_get .env.lde.smoke_tenant)"
  LDE_FILES_BUCKET="$(_lde_get .env.hub.env.SPOOL_HUB_FILES_BUCKET)"
  LDE_MIGRATIONS_DIR="$(_lde_get .env.hub.env.SPOOL_HUB_MIGRATIONS_DIR)"
  LDE_SQL_SRC="$APP_PATH/$(_lde_get .env.lde.hub.sql_src)"
  LDE_HUB_IMAGE="$LDE_ORG_APP-hub-lde:$slug"
  LDE_COMPOSE_ENV="$LDE_STATE_DIR/compose.env"
  LDE_HUB_ENV_FILE="$LDE_STATE_DIR/hub.env"
  LDE_DOCKER_DIR="$PROJ_PATH/src/docker"
  unset -f _lde_get

  local v
  for v in LDE_PG_IMAGE LDE_PG_PORT LDE_PG_DB LDE_PG_USER LDE_PG_PASSWORD LDE_GCS_IMAGE LDE_GCS_PORT \
           LDE_HUB_PORT LDE_HUB_CONTAINER_PORT LDE_SMOKE_TENANT LDE_FILES_BUCKET LDE_MIGRATIONS_DIR LDE_SQL_SRC; do
    [[ -n "${!v}" && "${!v}" != null ]] || { do_log "FATAL $v is empty: check lde.env.yaml / all.env.yaml"; return 1; }
  done
  export LDE_ORG LDE_APP LDE_ORG_APP LDE_CNF_DIR LDE_TREE_SLUG LDE_STATE_DIR LDE_CNF LDE_COMPOSE_PROJECT \
    LDE_PG_IMAGE LDE_PG_PORT LDE_PG_DB LDE_PG_USER LDE_PG_PASSWORD LDE_GCS_IMAGE LDE_GCS_PORT LDE_HUB_PORT \
    LDE_HUB_CONTAINER_PORT LDE_SMOKE_TENANT LDE_FILES_BUCKET LDE_MIGRATIONS_DIR LDE_SQL_SRC LDE_HUB_IMAGE LDE_COMPOSE_ENV \
    LDE_HUB_ENV_FILE LDE_DOCKER_DIR
}

# lde_compose <args...> -- docker compose over the three lde files, this tree's
# project name and the generated interpolation env.
lde_compose() {
  docker compose -p "$LDE_COMPOSE_PROJECT" --env-file "$LDE_COMPOSE_ENV" \
    -f "$LDE_DOCKER_DIR/docker-compose-infra.yaml" \
    -f "$LDE_DOCKER_DIR/docker-compose-rdb.yaml" \
    -f "$LDE_DOCKER_DIR/docker-compose-api.yaml" "$@"
}
