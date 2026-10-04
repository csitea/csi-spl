#!/bin/bash
#------------------------------------------------------------------------------
# @description Build the `spool` CLI for every release target and, with
# @description DRY_RUN=0, attach the builds to a GitHub release (spec 072 A4a,
# @description lane L3). Workflow 55 runs it on each stable-<date> it cuts, so
# @description a box can download the CLI instead of cloning the tree and
# @description building it with Go (A4b, install.sh).
# @description   1. one static build per target (CGO_ENABLED=0) through
# @description      csi-spl-api/src/bash/build.sh, from the tree at APP_PATH
# @description      (CI checks out the stable tag): spool-<os>-<arch>
# @description   2. spool-SHA256SUMS over those files (sha256sum -c format)
# @description   3. DRY_RUN=0: gh release upload <CLI_ASSETS_TAG> --clobber
# @description      (a re-run replaces, never duplicates)
# @description Any failed build = FATAL, and nothing is uploaded.
# @description Dry run unless DRY_RUN=0: builds and checksums, uploads nothing.
# @param CLI_ASSETS_TAG (DRY_RUN=0) - the existing release to attach to, e.g. stable-2026-10-05
# @param CLI_ASSETS_VERSION (optional) - baked into `spool version`, default the highest v-tag on HEAD, else build.sh's default (.version)
# @param CLI_ASSETS_DIR (optional) - where the builds go, default a temp dir
# @param CLI_ASSETS_TARGETS (optional) - default "linux/amd64 linux/arm64 darwin/amd64 darwin/arm64"
# @param CLI_ASSETS_BUILD (optional) - the build script, default csi-spl-api/src/bash/build.sh
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_release_cli_assets
# @example CLI_ASSETS_TAG=stable-2026-10-05 DRY_RUN=0 ./run -a do_release_cli_assets
#------------------------------------------------------------------------------
do_release_cli_assets() {
  do_require_bin git sha256sum || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tag="${CLI_ASSETS_TAG:-}"
  if ((!dry)) && [[ -z "$tag" ]]; then
    do_log "FATAL DRY_RUN=0 needs CLI_ASSETS_TAG: the release to attach the CLI to"; return 1
  fi
  local build="${CLI_ASSETS_BUILD:-$APP_PATH/csi-spl-api/src/bash/build.sh}"
  [[ -f "$build" ]] || { do_log "FATAL no build script at $build"; return 1; }
  local targets="${CLI_ASSETS_TARGETS:-linux/amd64 linux/arm64 darwin/amd64 darwin/arm64}"
  local t
  for t in $targets; do
    [[ "$t" =~ ^[a-z0-9]+/[a-z0-9]+$ ]] || { do_log "FATAL CLI_ASSETS_TARGETS entries are <os>/<arch>, got: '$t'"; return 1; }
  done
  local version="${CLI_ASSETS_VERSION:-}"
  if [[ -z "$version" ]]; then
    version="$(git -C "$APP_PATH" tag --points-at HEAD -l 'v*' | sed 's/^v//' | spl_version_max)"
  fi
  local dir="${CLI_ASSETS_DIR:-$(mktemp -d)}"
  mkdir -p "$dir" || { do_log "FATAL cannot create $dir"; return 1; }

  local files=() os arch f
  for t in $targets; do
    os="${t%/*}" arch="${t#*/}" f="spool-$os-$arch"
    rm -f "$dir/$f"
    CGO_ENABLED=0 GOOS="$os" GOARCH="$arch" SPOOL_BUILD_VERSION="$version" \
      bash "$build" "$dir/$f" >&2 && [[ -s "$dir/$f" ]] ||
      { do_log "FATAL the $t build failed: nothing is uploaded"; return 1; }
    chmod 0755 "$dir/$f"
    files+=("$f")
  done
  (cd "$dir" && sha256sum "${files[@]}" >spool-SHA256SUMS) || { do_log "FATAL cannot write $dir/spool-SHA256SUMS"; return 1; }
  cat "$dir/spool-SHA256SUMS"

  if ((dry)); then
    do_log "OK DRY_RUN built ${#files[@]} spool builds${version:+ (v$version)} in $dir; re-run with DRY_RUN=0 CLI_ASSETS_TAG=<release> to attach them."
    return 0
  fi
  do_require_bin gh || return 1
  (cd "$APP_PATH" && gh release upload "$tag" --clobber "${files[@]/#/$dir/}" "$dir/spool-SHA256SUMS") ||
    { do_log "FATAL cannot attach the CLI to the release $tag: re-run with CLI_ASSETS_TAG=$tag DRY_RUN=0"; return 1; }
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "dir=$dir"; echo "assets=${files[*]} spool-SHA256SUMS"; } >>"$GITHUB_OUTPUT"
  fi
  do_log "OK attached ${#files[@]} spool builds + spool-SHA256SUMS${version:+ (v$version)} to $tag"
}
