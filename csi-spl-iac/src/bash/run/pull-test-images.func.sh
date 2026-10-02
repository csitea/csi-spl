#!/bin/bash
#------------------------------------------------------------------------------
# @description Pull the container images the csi-spl-api gates run, so hub-pg
# @description and hub-gcs RUN on this box instead of skipping (they only ever
# @description use a CACHED image, never pull one). The tags are read from the
# @description tests themselves (the `${SPOOL_TEST_*_IMAGE:-<tag>}` defaults),
# @description never repeated here, so a pin bump in a test is picked up by the
# @description next run. An image already cached is left as is. Satellite gap 12
# @description (HOWTO-satellite-work.md section 4); box-playbook role 09 runs it.
# @param DRY_RUN (optional) - 1 = print the images and pull none
# @example ./run -a do_pull_test_images
#------------------------------------------------------------------------------
do_pull_test_images() {
  local imgs img fails=0
  imgs=$(_pull_test_images_list "${PROJ_PATH}/../csi-spl-api/src/bash/tests") || return 1
  for img in $imgs; do
    if [[ "${DRY_RUN:-0}" == 1 ]]; then
      echo "PLAN pull $img"; continue
    fi
    command -v docker >/dev/null || { do_log "FATAL docker is not installed"; return 1; }
    if docker image inspect "$img" >/dev/null 2>&1; then
      do_log "INFO $img already cached"
    elif docker pull -q "$img" >/dev/null; then
      do_log "INFO $img pulled"
    else
      do_log "FATAL could not pull $img"; fails=$((fails + 1))
    fi
  done
  [[ "$fails" -eq 0 ]]
}

# The default image of every `<NAME>_IMAGE="${SPOOL_TEST_<NAME>_IMAGE:-<tag>}"`
# line of the api tests, one per line, sorted; none found is an error.
_pull_test_images_list() {
  local out
  out=$(sed -nE 's/^[A-Z_]+_IMAGE="\$\{SPOOL_TEST_[A-Z_]+_IMAGE:-([^}]+)\}".*/\1/p' "$1"/*.tst.sh 2>/dev/null | sort -u)
  [[ -n "$out" ]] || { do_log "FATAL no SPOOL_TEST_*_IMAGE default in $1"; return 1; }
  printf '%s\n' "$out"
}
