#!/bin/bash
#------------------------------------------------------------------------------
# @description Build the topic PDF renderer image (spec 183 7.1.6) for a cloud
# @description env and (DRY_RUN=0 only) push it to the 028 Artifact Registry
# @description repository, beside the hub image:
# @description <region>-docker.pkg.dev/<project>/<repo>/<pdf.image.name>:src-<12 hex>.
# @description
# @description The tag is a hash of the renderer's committed inputs
# @description (cmd/spool-pdf, internal/topicpdf, the module's go.mod and go.sum,
# @description csi-spl-api/src/docker/pdf.Dockerfile), so it changes exactly when
# @description they do: the same tag in dev and prd, and an image already in the
# @description registry is never rebuilt (DRY_RUN=0 checks first and stops).
# @description The image is built from the repo root in Docker for linux/amd64
# @description (Cloud Run), as do_build_push_hub_image builds the hub.
# @description
# @description Terraform step 031-cloud-run-pdf runs cnf pdf.image.tag: after a
# @description push, a new renderer is that tag in cnf, a re-render and an
# @description apply of 031 with the owner's go. Nothing here rolls a service.
# @description DRY_RUN=1 (default): build locally, print the push, touch no
# @description cloud. DRY_RUN=0: prove GCP_ACCOUNT is live, then push with a
# @description THROWAWAY docker config (the token never lands in
# @description ~/.docker/config.json).
# @param ENV (required) - dev or prd
# @param GCP_ACCOUNT (optional) - overrides the per-env project SA from its key (do_gcp_account; never the owner account): the identity that pushes (artifactregistry.writer)
# @param DRY_RUN (optional) - 1 (default): build only. 0: build + push, unless the tag is already in the registry.
# @example ENV=dev ./run -a do_build_push_pdf_image
# @example ENV=dev DRY_RUN=0 ./run -a do_build_push_pdf_image
#------------------------------------------------------------------------------
do_build_push_pdf_image() {
  do_require_bin docker yq git || return 1
  do_spl_cloud_cnf || return 1
  local dry=1 rc=0
  # not `if ! spl_dry_run; then rc=$?`: after `!` $? is the NEGATED status
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )); then
    do_gcp_pin_account "$SPL_CNF" || return 1
    command -v gcloud >/dev/null || { do_log "FATAL gcloud is not installed"; return 1; }
  fi

  local dockerfile="$APP_PATH/$SPL_ORG_APP-api/src/docker/pdf.Dockerfile" name tag ref rev
  [[ -f "$dockerfile" ]] || { do_log "FATAL missing $dockerfile (spec 183 row P2 builds it)"; return 1; }
  name="$(yq -r '.env.pdf.image.name // ""' "$SPL_CNF")"
  [[ -n "$name" && "$name" != null ]] || { do_log "FATAL cnf env.pdf.image.name is empty"; return 1; }
  tag="$(spl_pdf_image_tag "$APP_PATH")" || return 1
  ref="${SPL_IMAGE_CNF_REF%/*}/$name:$tag"
  rev="$(git -C "$APP_PATH" rev-parse HEAD)"
  if [[ -n "$(spl_pdf_inputs_dirty "$APP_PATH")" ]]; then
    (( dry )) || { do_log "FATAL the renderer's inputs are dirty: push only a committed build ($tag = the committed inputs)"; return 1; }
    do_log "WARN the renderer's inputs are dirty: this image is not exactly $tag"
  fi

  # only NOT_FOUND means "build it"; any other describe error (permission,
  # network) is a stop, as wf 20's hub image check (R7 c-056 N1)
  local out
  if (( ! dry )); then
    if out="$(gcloud artifacts docker images describe "$ref" --account="$GCP_ACCOUNT" --project="$SPL_PROJECT" \
         --format='value(image_summary.digest)' 2>&1)"; then
      do_log "OK $ref is already in the registry: the renderer's inputs did not change, nothing to build"
      return 0
    elif ! grep -qiE 'not.?found|NOT_FOUND' <<<"$out"; then
      do_log "FATAL cannot read $ref from the registry (is 028 applied, does $GCP_ACCOUNT hold artifactregistry.reader?): $(tail -1 <<<"$out")"
      return 1
    fi
  fi

  docker build -q --platform linux/amd64 \
    --label "org.opencontainers.image.revision=$rev" \
    --label "org.opencontainers.image.title=$SPL_ORG_APP-pdf" \
    -t "$ref" -f "$dockerfile" "$APP_PATH" >/dev/null || { do_log "FATAL pdf image build failed"; return 1; }
  do_log "INFO built $ref ($(docker image inspect -f '{{.Id}}' "$ref"), revision $rev)"

  if (( dry )); then
    do_log "INFO DRY_RUN would run: docker push $ref   (login: oauth2accesstoken @ $SPL_REGISTRY_HOST as \$GCP_ACCOUNT, throwaway DOCKER_CONFIG)"
    do_log "OK DRY_RUN build of $ref complete: nothing was pushed. Re-run with DRY_RUN=0 to push."
    return 0
  fi

  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  local dcfg
  dcfg="$(mktemp -d)" || return 1
  gcloud auth print-access-token --account="$GCP_ACCOUNT" |
    DOCKER_CONFIG="$dcfg" docker login -u oauth2accesstoken --password-stdin "https://$SPL_REGISTRY_HOST" >/dev/null 2>&1 ||
    { rm -rf "$dcfg"; do_log "FATAL docker login to $SPL_REGISTRY_HOST as $GCP_ACCOUNT failed"; return 1; }
  DOCKER_CONFIG="$dcfg" docker push -q "$ref" || rc=$?
  rm -rf "$dcfg"
  (( rc == 0 )) || { do_log "FATAL push of $ref failed (rc=$rc; an existing tag is immutable)"; return 1; }
  do_log "OK pushed $ref -- to run it: cnf env.pdf.image.tag: $tag, do_tpl_gen, then plan + apply 031-cloud-run-pdf (owner's go)"
}

# spl_pdf_inputs <app>: the renderer image's inputs, repo-relative, one a line.
# The one list the tag hashes and workflow 20's pdf job watches.
spl_pdf_inputs() {
  local api="${SPL_ORG_APP:-csi-spl}-api"
  printf '%s\n' \
    "$api/src/go/spool-hub-api/cmd/spool-pdf" \
    "$api/src/go/spool-hub-api/internal/topicpdf" \
    "$api/src/go/spool-hub-api/go.mod" \
    "$api/src/go/spool-hub-api/go.sum" \
    "$api/src/docker/pdf.Dockerfile"
}

# spl_pdf_image_tag <app>: src-<12 hex>, a hash of the git object id of each
# input at HEAD (a missing input hashes as "-"). Committed content only, so a
# rebuild of the same inputs gets the same tag on any machine.
spl_pdf_image_tag() {
  local app="$1" p id h
  h="$(spl_pdf_inputs "$app" | while IFS= read -r p; do
    id="$(git -C "$app" rev-parse -q --verify "HEAD:$p" 2>/dev/null)" || id="-"
    printf '%s %s\n' "$p" "$id"
  done | sha256sum)" || { do_log "FATAL cannot hash the renderer's inputs in $app"; return 1; }
  [[ "$h" =~ ^[0-9a-f]{64} ]] || { do_log "FATAL cannot hash the renderer's inputs in $app"; return 1; }
  printf 'src-%s\n' "${h:0:12}"
}

# spl_pdf_inputs_dirty <app>: the inputs' uncommitted changes (porcelain), "" when clean
spl_pdf_inputs_dirty() {
  local -a p=()
  mapfile -t p < <(spl_pdf_inputs "$1")
  git -C "$1" status --porcelain -- "${p[@]}"
}
