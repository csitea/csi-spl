#!/bin/bash
#------------------------------------------------------------------------------
# @description Prune THIS box's docker daemon: unused images and build cache
# @description older than PRUNE_UNTIL (168h, a week). Never a container, a
# @description volume, an image a container uses, or the infra stack's
# @description (con-csi-csi-spl-*) images; waits for the CI jobs and builds
# @description that can reach the daemon, then skips with a WARN. One line per
# @description check and a RESULT line with the reclaimed bytes; a WARN or
# @description FAIL is also a spool note to the orchestrator.
# @description Dry run unless DRY_RUN=0. The weekly cron line is
# @description do_prune_docker_images_install_cron.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PRUNE_UNTIL (optional) - age filter, default 168h
# @param PRUNE_BUSY_WAIT_S (optional) - wait for busy CI/builds, default 2700
# @example ./run -a do_prune_docker_images
# @example DRY_RUN=0 ./run -a do_prune_docker_images
#------------------------------------------------------------------------------
do_prune_docker_images() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/prune-docker-images.sh"
}
