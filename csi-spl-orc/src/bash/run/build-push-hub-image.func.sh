#!/bin/bash
#------------------------------------------------------------------------------
# @description Build the spool hub image for a cloud env and (DRY_RUN=0 only)
# @description push it to the 028 Artifact Registry repository, as exactly the
# @description reference 030 runs: cnf env.hub.image.ref =
# @description <region>-docker.pkg.dev/<project>/<repo>/<hub.image.name>:<tag>.
# @description
# @description The image is THE hub image (specs/072 A21), the one the root
# @description docker-compose.yml and the lde stack run too:
# @description csi-spl-api/src/docker/hub.Dockerfile, built in Docker from the
# @description repo root (no Go toolchain on this machine), for linux/amd64
# @description (Cloud Run). Its entrypoint runs plain `spool serve` on Cloud Run.
# @description The version baked in = the image tag (minus a -c<N> cycle
# @description suffix): SPL_HUB_IMAGE_TAG (minted by do_release_version), else
# @description the cnf hub.image.tag floor.
# @description
# @description DRY_RUN=1 (default): build locally, print the push, touch no
# @description cloud. DRY_RUN=0: prove GCP_ACCOUNT is live, then push with a
# @description THROWAWAY docker config (the token never lands in
# @description ~/.docker/config.json). The repository's tags are immutable:
# @description re-pushing an existing tag fails; a deploy pushes the version
# @description it minted (workflow 20).
# @param ENV - required: dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account): the identity that pushes (artifactregistry.writer)
# @param SPL_HUB_IMAGE_TAG (optional) - the release version CI minted (do_release_version): the image tag AND the version baked into the binary (a cycle suffix -c<N> is dropped from the baked version: tag 1.0.1-c2 bakes 1.0.1); unset = cnf hub.image.tag / .version
# @param DRY_RUN (optional) - 1 (default): build only. 0: build + push.
# @example ENV=dev ./run -a do_build_push_hub_image
# @example ENV=dev DRY_RUN=0 ./run -a do_build_push_hub_image
#------------------------------------------------------------------------------
do_build_push_hub_image() {
  do_require_bin docker yq git || return 1
  do_spl_cloud_cnf || return 1
  local dry=1 rc=0
  # not `if ! spl_dry_run; then rc=$?`: after `!` $? is the NEGATED status
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )); then
    do_gcp_pin_account "$SPL_CNF" || return 1
    command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  fi

  local api="$SPL_ORG_APP-api/src/docker"
  local dockerfile="$APP_PATH/$api/hub.Dockerfile" rev
  [[ -f "$dockerfile" ]] || { do_log "FATAL missing $dockerfile"; return 1; }
  spl_hub_image_matches_cnf "$dockerfile" || return 1
  rev="$(git -C "$APP_PATH" rev-parse HEAD)"
  if [[ -n "$(git -C "$APP_PATH" status --porcelain -- "$SPL_ORG_APP-api/src/go" "$api" "$SPL_ORG_APP-rdb" .version)" ]]; then
    (( dry )) || { do_log "FATAL the api / rdb / Dockerfile tree is dirty: push only a committed build (image label = $rev)"; return 1; }
    do_log "WARN the api / rdb / Dockerfile tree is dirty: this image is not exactly $rev"
  fi

  # the image tag may carry the release cycle (1.0.1-c2); the binary bakes the plain 1.0.1
  local tag="${SPL_IMAGE_REF##*:}"
  local version="${SPOOL_BUILD_VERSION:-${tag%%-c*}}"
  docker build -q --platform linux/amd64 \
    --build-arg "SPOOL_VERSION=$version" \
    --build-arg "SPOOL_COMMIT=$rev" \
    --label "org.opencontainers.image.revision=$rev" \
    --label "org.opencontainers.image.title=$SPL_ORG_APP-hub" \
    -t "$SPL_IMAGE_REF" -f "$dockerfile" "$APP_PATH" >/dev/null || { do_log "FATAL hub image build failed"; return 1; }
  local id
  id="$(docker image inspect -f '{{.Id}}' "$SPL_IMAGE_REF")"
  do_log "INFO built $SPL_IMAGE_REF ($id, version $version, $(find "$SPL_IMAGE_SQL_SRC" -maxdepth 1 -name '*.sql' | wc -l) sql file(s), revision $rev)"

  if (( dry )); then
    do_log "INFO DRY_RUN would run: docker push $SPL_IMAGE_REF   (login: oauth2accesstoken @ $SPL_REGISTRY_HOST as \$GCP_ACCOUNT, throwaway DOCKER_CONFIG)"
    do_log "OK DRY_RUN build of $SPL_IMAGE_REF complete: nothing was pushed. Re-run with DRY_RUN=0 to push."
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
  (( rc == 0 )) || { do_log "FATAL push of $SPL_IMAGE_REF failed (rc=$rc; an existing tag is immutable)"; return 1; }
  do_log "OK pushed $SPL_IMAGE_REF"
}

# spl_hub_image_matches_cnf <dockerfile>: the DDL the image bundles and the
# dir `spool migrate` reads in it are fixed in hub.Dockerfile; the cnf names
# them too (hub.image.sql_src, hub.env.SPOOL_HUB_MIGRATIONS_DIR, which 030
# sets on Cloud Run). Refuse a build where the two disagree, instead of a hub
# that migrates from an empty dir.
spl_hub_image_matches_cnf() {
  local dockerfile="$1" rel="${SPL_IMAGE_SQL_SRC#"$APP_PATH"/}"
  [[ -d "$SPL_IMAGE_SQL_SRC" ]] || { do_log "FATAL no DDL dir $SPL_IMAGE_SQL_SRC (cnf hub.image.sql_src)"; return 1; }
  grep -qE "^COPY $rel/ $SPL_MIGRATIONS_DIR/\$" "$dockerfile" ||
    { do_log "FATAL $dockerfile does not COPY cnf hub.image.sql_src ($rel/) to cnf SPOOL_HUB_MIGRATIONS_DIR ($SPL_MIGRATIONS_DIR/)"; return 1; }
  grep -qE "SPOOL_HUB_MIGRATIONS_DIR=$SPL_MIGRATIONS_DIR( |\$)" "$dockerfile" ||
    { do_log "FATAL $dockerfile does not set SPOOL_HUB_MIGRATIONS_DIR=$SPL_MIGRATIONS_DIR (cnf)"; return 1; }
}
