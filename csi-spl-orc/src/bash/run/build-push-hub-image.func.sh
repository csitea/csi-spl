#!/bin/bash
#------------------------------------------------------------------------------
# @description Build the spool hub image for a cloud env and (DRY_RUN=0 only)
# @description push it to the 028 Artifact Registry repository, as exactly the
# @description reference 030 runs: cnf env.hub.image.ref =
# @description <region>-docker.pkg.dev/<project>/<repo>/<hub.image.name>:<hub.image.tag>.
# @description
# @description The image is the lde one (src/docker/spool-hub-api/Dockerfile):
# @description a static `spool` from csi-spl-api + the csi-spl-rdb DDL at
# @description SPOOL_HUB_MIGRATIONS_DIR, built for linux/amd64 (Cloud Run).
# @description
# @description DRY_RUN=1 (default): build locally, print the push, touch no
# @description cloud. DRY_RUN=0: prove GCP_ACCOUNT is live, then push with a
# @description THROWAWAY docker config (the token never lands in
# @description ~/.docker/config.json). The repository's tags are immutable:
# @description re-pushing an existing tag fails, so a new build means a new
# @description hub.image.tag in <env>.env.yaml (re-render, then 030 plan + apply).
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT - required when DRY_RUN=0: the identity that pushes (artifactregistry.writer)
# @param DRY_RUN (optional) - 1 (default): build only. 0: build + push.
# @example ENV=dev ./run -a do_build_push_hub_image
# @example ENV=dev DRY_RUN=0 GCP_ACCOUNT=<OPERATOR>@example.com ./run -a do_build_push_hub_image
#------------------------------------------------------------------------------
do_build_push_hub_image() {
  do_require_bin docker yq git || return 1
  do_spl_cloud_cnf || return 1
  local dry=1 rc=0
  # not `if ! spl_dry_run; then rc=$?`: after `!` $? is the NEGATED status
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )); then
    do_require_var GCP_ACCOUNT "${GCP_ACCOUNT:-}"
    command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  fi

  local build="$APP_PATH/$SPL_ORG_APP-api/src/bash/build.sh"
  local dockerfile="$PROJ_PATH/src/docker/spool-hub-api/Dockerfile"
  local ctx="$SPL_STATE_DIR/hub-ctx" rev
  [[ -f "$build" && -f "$dockerfile" ]] || { do_log "FATAL missing $build or $dockerfile"; return 1; }
  [[ -d "$SPL_IMAGE_SQL_SRC" ]] || { do_log "FATAL no DDL dir $SPL_IMAGE_SQL_SRC (cnf hub.image.sql_src)"; return 1; }
  rev="$(git -C "$APP_PATH" rev-parse HEAD)"
  if [[ -n "$(git -C "$APP_PATH" status --porcelain -- "$SPL_ORG_APP-api" "$SPL_ORG_APP-rdb" "$dockerfile")" ]]; then
    (( dry )) || { do_log "FATAL the api / rdb / Dockerfile tree is dirty: push only a committed build (image label = $rev)"; return 1; }
    do_log "WARN the api / rdb / Dockerfile tree is dirty: this image is not exactly $rev"
  fi

  rm -rf "$ctx" && mkdir -p "$ctx/sql" || return 1
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 bash "$build" "$ctx/spool" >/dev/null || { do_log "FATAL static spool build failed"; return 1; }
  cp -p "$SPL_IMAGE_SQL_SRC"/*.sql "$ctx/sql/" || { do_log "FATAL no .sql in $SPL_IMAGE_SQL_SRC"; return 1; }
  docker build -q --platform linux/amd64 \
    --build-arg "MIGRATIONS_DIR=$SPL_MIGRATIONS_DIR" \
    --label "org.opencontainers.image.revision=$rev" \
    --label "org.opencontainers.image.title=$SPL_ORG_APP-hub" \
    -t "$SPL_IMAGE_REF" -f "$dockerfile" "$ctx" >/dev/null || { do_log "FATAL hub image build failed"; return 1; }
  local id
  id="$(docker image inspect -f '{{.Id}}' "$SPL_IMAGE_REF")"
  do_log "INFO built $SPL_IMAGE_REF ($id, $(find "$ctx/sql" -name '*.sql' | wc -l) sql file(s), revision $rev)"

  if (( dry )); then
    do_log "INFO DRY_RUN would run: docker push $SPL_IMAGE_REF   (login: oauth2accesstoken @ $SPL_REGISTRY_HOST as \$GCP_ACCOUNT, throwaway DOCKER_CONFIG)"
    do_log "OK DRY_RUN build of $SPL_IMAGE_REF complete: nothing was pushed. Re-run with DRY_RUN=0 GCP_ACCOUNT=... to push."
    return 0
  fi

  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local dcfg
  dcfg="$(mktemp -d)" || return 1
  gcloud auth print-access-token --account="$GCP_ACCOUNT" |
    DOCKER_CONFIG="$dcfg" docker login -u oauth2accesstoken --password-stdin "https://$SPL_REGISTRY_HOST" >/dev/null 2>&1 ||
    { rm -rf "$dcfg"; do_log "FATAL docker login to $SPL_REGISTRY_HOST as $GCP_ACCOUNT failed"; return 1; }
  DOCKER_CONFIG="$dcfg" docker push -q "$SPL_IMAGE_REF" || rc=$?
  rm -rf "$dcfg"
  (( rc == 0 )) || { do_log "FATAL push of $SPL_IMAGE_REF failed (rc=$rc; an existing tag is immutable: bump hub.image.tag)"; return 1; }
  do_log "OK pushed $SPL_IMAGE_REF; next: ENV=$ENV STEP=030-cloud-run-hub ./run -a do_tf_plan in csi-spl-iac"
}
