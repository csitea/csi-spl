#!/bin/bash
#------------------------------------------------------------------------------
# @description Remove the Go module versions that no checkout on this box names
# @description (SPL-5225, row 6 of the sat disk table): from each box user's
# @description GOMODCACHE, a <module>@<version> dir and its cache/download
# @description files go only when no go.mod / go.sum under GO_MODCACHE_ROOTS or
# @description a user's home names it (a go.mod's go / toolchain line keeps that
# @description toolchain), nothing in it changed for GO_MODCACHE_AGE_D days, and
# @description the owner runs no go build now. Removed as the owner, its
# @description read-only files made writable first. A scan that cannot read a
# @description dir, or finds no go.mod / go.sum, removes nothing. One line per
# @description version with its size. Dry run unless DRY_RUN=0. By hand only.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param GO_MODCACHE_ROOTS (optional) - default "/opt /srv /var/tmp /tmp", the users' homes added
# @param GO_MODCACHE_USERS (optional) - default every user with a login shell
# @param GO_MODCACHE_DIRS (optional) - "<owner>:<dir> ..." in place of the users' caches
# @param GO_MODCACHE_AGE_D (optional) - idle days before removal, default 7
# @param GO_MODCACHE_SUDO (optional) - 1 (default) or 0: this user's caches only
# @example ./run -a do_sweep_go_modcache
# @example DRY_RUN=0 ./run -a do_sweep_go_modcache
#------------------------------------------------------------------------------
do_sweep_go_modcache() {
  DRY_RUN="${DRY_RUN:-1}" bash "$PROJ_PATH/src/bash/scripts/go-modcache-sweep.sh"
}
