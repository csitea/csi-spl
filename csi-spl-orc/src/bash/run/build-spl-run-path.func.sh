#!/bin/bash
#------------------------------------------------------------------------------
# @description Build and install spl-run-path, the binary that does the path
# @description step of run.sh's do_set_vars in one exec (SPL-5985, spec 027
# @description rust-run-path.md), at <repo>/bin/spl-run-path (APP_PATH/bin,
# @description git-ignored): the one path a module's ./run looks at. Without
# @description SPL_RUN_PATH_BIN it builds csi-spl-orc/src/rust/spl-run-path
# @description with cargo (the crate's pinned toolchain, static musl). The
# @description copy goes in as .new, must print run.sh's RUN_PATH_BIN_VERSION
# @description and resolve this module's ./run to PROJ_PATH, then mv -f swaps it
# @description in. Rollback: delete the file; ./run then takes the Bash path.
# @description DRY RUN BY DEFAULT: DRY_RUN=0 builds and installs.
# @param DRY_RUN (optional) - 1 prints the plan (default), 0 builds and installs
# @param SPL_RUN_PATH_BIN (optional) - a built spl-run-path to install; default: build it
# @param SPL_RUST_HOME (optional) - RUSTUP_HOME, CARGO_HOME and the target dir under it; default: the user's own rustup and the crate's target/
# @example ./run -a do_build_spl_run_path
# @example DRY_RUN=0 ./run -a do_build_spl_run_path
#------------------------------------------------------------------------------

# _srp_build: cargo build --release in the crate dir (rust-toolchain.toml and
# .cargo/config.toml apply only there); prints the binary's path.
_srp_build() {
  local crate="$PROJ_PATH/src/rust/spl-run-path" rh="${SPL_RUST_HOME:-}" td
  td="${rh:+$rh/target/spl-run-path}"
  td="${td:-$crate/target}"
  command -v cargo >/dev/null 2>&1 || { do_log "FATAL no cargo: install rustup with do_box_pkg_install"; return 1; }
  (
    cd "$crate" || exit 1
    [[ -z "$rh" ]] || export RUSTUP_HOME="$rh/rustup" CARGO_HOME="$rh/cargo"
    CARGO_TARGET_DIR="$td" CARGO_INCREMENTAL=0 cargo build --release --locked --offline
  ) >&2 || return 1
  printf '%s\n' "$td/x86_64-unknown-linux-musl/release/spl-run-path"
}

# _srp_check <bin>: the version run.sh wants, and this module's ./run resolved
# to PROJ_PATH
_srp_check() {
  local v out
  v="$("$1" --version 2>/dev/null)"
  [[ "$v" == "spl-run-path ${RUN_PATH_BIN_VERSION:-}" ]] ||
    { do_log "FAIL $1 is '$v', run.sh wants spl-run-path ${RUN_PATH_BIN_VERSION:-}"; return 1; }
  out="$("$1" -- "$PROJ_PATH/run" 2>/dev/null)" || { do_log "FAIL $1 -- $PROJ_PATH/run exited $?"; return 1; }
  [[ $'\n'"$out"$'\n' == *$'\n'"PROJ_PATH=$PROJ_PATH"$'\n'* ]] ||
    { do_log "FAIL $1 resolves $PROJ_PATH/run to another PROJ_PATH"; return 1; }
}

do_build_spl_run_path() {
  local dry="${DRY_RUN:-1}" bin="${SPL_RUN_PATH_BIN:-}" dst="$APP_PATH/bin/spl-run-path"
  case "$dry" in 0 | 1) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 2 ;; esac
  if [[ "$dry" == 1 ]]; then
    do_log "INFO PLAN ${bin:-cargo build of $PROJ_PATH/src/rust/spl-run-path} -> $dst (version ${RUN_PATH_BIN_VERSION:-}) - DRY RUN"
    return 0
  fi
  if [[ -z "$bin" ]]; then
    bin="$(_srp_build)" || { do_log "FAIL the spl-run-path build failed"; return 1; }
  fi
  _srp_check "$bin" || return 1
  mkdir -p "${dst%/*}" && cp "$bin" "$dst.new" && chmod 755 "$dst.new" || return 1
  _srp_check "$dst.new" || { rm -f "$dst.new"; return 1; }
  mv -f "$dst.new" "$dst" || return 1
  do_log "OK $dst: $("$dst" --version)"
}
