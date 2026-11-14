#!/bin/bash
#------------------------------------------------------------------------------
# @description Set SPL_CMD_GUARD_IMPL (py, shadow or rust) for the installed
# @description force-push-guard-hook.sh of BOTH the box's agent user and its
# @description box user (SPL-5392, the Rust pilot; spec 011
# @description rust-candidates-analysis.md 6.2). shadow and rust install the
# @description spl-cmd-guard binary next to the hook (--self-test, .bak, mv -T
# @description swap) and write spl-cmd-guard.impl; py writes only the impl
# @description file, the one-word rollback. Without SPL_CMD_GUARD_BIN it
# @description builds the binary from csi-spl-orc/src/rust/spl-cmd-guard with
# @description the pinned toolchain under SPL_RUST_HOME. Per home, as that user
# @description (sudo -n -u for the other one):
# @description spawn-agents/scripts/spl-cmd-guard-install.sh.
# @description Switching a box to shadow or rust is the owner's go, never a lane's.
# @description DRY RUN BY DEFAULT: DRY_RUN=0 writes.
# @param SPL_CMD_GUARD_IMPL (required) - py | shadow | rust
# @param DRY_RUN (optional) - 1 prints the plan (default), 0 writes
# @param SPL_CMD_GUARD_BIN (optional) - a built spl-cmd-guard; default: build it
# @param SPL_RUST_HOME (optional) - rustup, cargo and target dirs; default
# @param SPL_RUST_HOME /mnt/data/var/csi/rust when /mnt/data is mounted, else /var/csi/rust
# @param SPOOL_AGENT_USER (optional) - default from $SPOOL_ROOT/box.env
# @param SPOOL_BOX_USER (optional) - default the owner of $SPOOL_ROOT
# @param SPL_CMD_GUARD_HOMES (optional, tests) - space-separated homes, run as THIS user
# @example SPL_CMD_GUARD_IMPL=shadow ./run -a do_spl_cmd_guard_mode
# @example SPL_CMD_GUARD_IMPL=py DRY_RUN=0 ./run -a do_spl_cmd_guard_mode
#------------------------------------------------------------------------------

# _scg_build: build spl-cmd-guard with the pinned toolchain; prints its path.
# cargo runs in a subshell with the crate dir as its cwd (SPL-5487): only
# there does rustup read rust-toolchain.toml and cargo .cargo/config.toml
# (the musl target, rust-lld). From another dir it found no toolchain, or
# built a glibc binary outside the musl path printed below.
_scg_build() {
  local rh="${SPL_RUST_HOME:-}" crate="$PROJ_PATH/src/rust/spl-cmd-guard"
  if [[ -z "$rh" ]]; then
    rh=/var/csi/rust
    mountpoint -q /mnt/data 2>/dev/null && rh=/mnt/data/var/csi/rust
  fi
  command -v cargo >/dev/null 2>&1 || { do_log "FATAL no cargo: install rustup with do_box_pkg_install"; return 1; }
  ( cd "$crate" || exit 1
    RUSTUP_HOME="$rh/rustup" CARGO_HOME="$rh/cargo" CARGO_TARGET_DIR="$rh/target/spl-cmd-guard" \
      CARGO_INCREMENTAL=0 SPL_CMD_GUARD_COMMIT="$(git -C "$PROJ_PATH" rev-parse --short=12 HEAD 2>/dev/null)" \
      cargo build --release --locked --offline ) >&2 || return 1
  printf '%s\n' "$rh/target/spl-cmd-guard/x86_64-unknown-linux-musl/release/spl-cmd-guard"
}

# _scg_homes: "<user> <home>" per line, the agent user and the box user
_scg_homes() {
  local u h users=()
  # shellcheck source=../features/spawn-agents/lib/spool-env.inc.sh
  source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || return 1
  SPOOL_ENV_NO_BINS=1 spool_env_resolve >/dev/null 2>&1
  users=("${SPOOL_AGENT_USER:-}")
  [[ "${SPOOL_BOX_USER:-}" != "${SPOOL_AGENT_USER:-}" ]] && users+=("${SPOOL_BOX_USER:-}")
  for u in "${users[@]}"; do
    [[ -n "$u" ]] || { do_log "FATAL no agent / box user: set SPOOL_AGENT_USER and SPOOL_BOX_USER"; return 1; }
    h="$(getent passwd "$u" | cut -d: -f6)"
    [[ -d "$h" ]] || { do_log "FATAL no home for $u"; return 1; }
    printf '%s %s\n' "$u" "$h"
  done
}

do_spl_cmd_guard_mode() {
  local impl="${SPL_CMD_GUARD_IMPL:-}" dry="${DRY_RUN:-1}" bin="${SPL_CMD_GUARD_BIN:-}" u h rc=0 rows
  local script="$PROJ_PATH/src/bash/features/spawn-agents/scripts/spl-cmd-guard-install.sh"
  case "$impl" in py | shadow | rust) ;; *) do_log "FATAL SPL_CMD_GUARD_IMPL must be py, shadow or rust"; return 2 ;; esac
  case "$dry" in 0 | 1) ;; *) do_log "FATAL DRY_RUN must be 0 or 1"; return 2 ;; esac
  if [[ "$impl" != py && -z "$bin" ]]; then
    bin="$(_scg_build)" || { do_log "FAIL the spl-cmd-guard build failed"; return 1; }
  fi
  [[ -n "$bin" ]] || bin=-
  if [[ -n "${SPL_CMD_GUARD_HOMES:-}" ]]; then
    for h in $SPL_CMD_GUARD_HOMES; do bash "$script" "$h" "$impl" "$bin" "$dry" || rc=$?; done
  else
    rows="$(_scg_homes)" || return 1
    while read -r u h; do
      do_log "INFO spl-cmd-guard $impl for $u ($h)$([[ $dry == 1 ]] && echo ' - DRY RUN')"
      if [[ "$(id -un)" == "$u" ]]; then bash "$script" "$h" "$impl" "$bin" "$dry" || rc=$?
      else sudo -n -u "$u" -H bash "$script" "$h" "$impl" "$bin" "$dry" || rc=$?
      fi
    done <<<"$rows"
  fi
  (( rc == 0 )) || { do_log "FAIL spl-cmd-guard mode exited $rc"; return "$rc"; }
  do_log "OK spl-cmd-guard $impl $([[ $dry == 1 ]] && echo 'planned (DRY_RUN=0 writes)' || echo set)"
}
