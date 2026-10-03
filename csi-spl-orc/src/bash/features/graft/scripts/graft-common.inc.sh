#!/bin/bash
# graft-common.inc.sh — the library behind graft-index-update.sh: resolve the
# installed graft, keep the safety wrapper and the language layer in force, and
# build each repo's out-of-tree index only when its inputs changed.
#
# OFFLINE and ZERO egress: telemetry is disabled, the LLM pass (--deep) is never
# invoked, and every graft call runs with the proxy blanked so an accidental
# network call fails loudly instead of succeeding quietly.
#
# The caller defines do_log. Nothing here names a box, a user or a repo.

# The list of repos a box indexes: one absolute path per line, # comments and
# blank lines ignored. It is BOX-SPECIFIC state, so no tracked file names a
# repo; _graft_registry_resolve picks it, first hit wins:
#   1. explicit repo arguments               (the caller's; never reaches here)
#   2. GRAFT_REGISTRY in the environment     src=env
#   3. $GRAFT_VAR_ROOT/repos.list            src=box
# GRAFT_REGISTRY is deliberately NOT defaulted when this file is sourced: a
# default set here would be indistinguishable from an explicit one.

# The language extension layer: breadth-tier grammars graft does not register
# itself. `install.sh` does `rm -rf $LIB/*` and re-copies the pristine vendor
# pack, so this layer is DESTROYED on every reinstall and MUST be re-applied
# afterwards -- that is the whole reason do_graft_init exists rather than a bare
# call to install.sh. Patching the pack instead does not work: its
# MANIFEST.sha256 gate correctly refuses to install a modified pack.
: "${GRAFT_LANGS:=sql:.sql bash:.sh,.bash}"

# The graft feature dir (scripts/, assets/): the parent of this file's dir,
# found by its physical path, never by a literal.
_graft_feature_dir() {
  local d
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)"
  [ -n "$d" ] && [ -r "$d/scripts/graft-wrap.sh" ] && { printf '%s' "$d"; return 0; }
  do_log "FATAL graft feature dir not found above $(dirname "${BASH_SOURCE[0]}")"
  return 11
}

# Sets GRAFT_REGISTRY (the list file) and GRAFT_REGISTRY_SRC (env|box).
# A second call keeps the first answer.
_graft_registry_resolve() {
  [ -n "${GRAFT_REGISTRY_SRC:-}" ] && [ -n "${GRAFT_REGISTRY:-}" ] && return 0
  if [ -n "${GRAFT_REGISTRY:-}" ]; then
    GRAFT_REGISTRY_SRC="env"
  else
    # shellcheck disable=SC1091
    GRAFT_REGISTRY="$(. "$(dirname "${BASH_SOURCE[0]}")/graft-index-dir.sh" && graft_var_root)/repos.list"
    GRAFT_REGISTRY_SRC="box"
  fi
  export GRAFT_REGISTRY GRAFT_REGISTRY_SRC
}

# The repos of a list file, one per line: # comments and blank lines dropped.
_graft_registry_repos() {  # FILE
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" | grep -v '^$'
}

# Resolve the installed runtime the same way the launcher does, so we never
# guess a prefix that is not the one on PATH.
# Resolve graft's lib dir. THREE install shapes exist, and the order they are
# tried in is load-bearing (see 1b):
#   1.  the wrapper shape - a shell script that execs node on .../dist/cli.js
#   1b. the SAFE-WRAPPER  - graft-safe.sh: execs <launcher>.real and names no
#                           cli.js at all, so 1 and 2 are both blind to it.
#                           Must be tried AFTER 1 and BEFORE 2, or a .real that
#                           is itself a symlink chain resolves against the
#                           wrapper instead of the launcher.
#   1c. the CROSS-USER  - a second OS user's shim: it sets GRAFT_SAFE_BIN to
#       SHIM              another user's graft.real and execs graft-safe.sh.
#                           There is NO .real beside it (the real launcher is in
#                           the OTHER user's home), so 1b is blind to it too.
#                           This is the shape <agent-user> runs on this box.
#   2.  the npm shape     - the bin is a SYMLINK CHAIN ending at dist/cli.js,
#                           where the sed matches nothing and the old fallback
#                           pointed at a directory that does not exist.
# The $HOME fallback below is a last resort whose correctness depends on WHICH
# OS USER runs it - measured 2026-09-16 it lands for <box-user> and misses for
# <agent-user> and root. <agent-user> is the agent user, so the failing path is the one the
# fleet actually uses. That is why this presented as a per-user environment
# problem rather than as a resolver bug, and why 1b is not optional.
# Resolve via _graft_bin (not PATH) so it works under cron too.
_graft_lib() {
  local g lib real
  g="$(_graft_bin 2>/dev/null)"
  if [ -n "$g" ]; then
    # 1. the offline-pack wrapper shape: a script that execs node on dist/cli.js
    lib="$(sed -n 's|.*exec node "\(.*\)/dist/cli.js".*|\1|p' "$g" 2>/dev/null)"
    # 1b. the graft-safe wrapper shape: it execs <launcher>.real and names no
    #     cli.js at all, so neither the sed nor the readlink below can see
    #     through it. Ask the .real, which is the launcher that actually knows.
    #     Without this the resolver silently falls through to the $HOME guess:
    #     a WRONG-but-present lib dir misregisters languages quietly, and a
    #     missing one fails FATAL with "no generic.js" while graft works fine.
    #     (Found on a second box 2026-09-16 after adopting the wrapper; this box
    #     was masking it because the $HOME guess happened to be correct here.)
    if [ -z "${lib:-}" ] && [ -r "${g}.real" ]; then
      lib="$(sed -n 's|.*exec node "\(.*\)/dist/cli.js".*|\1|p' "${g}.real" 2>/dev/null)"
      if [ -z "${lib:-}" ]; then
        real="$(readlink -f "${g}.real" 2>/dev/null)"
        case "$real" in */dist/cli.js) lib="${real%/dist/cli.js}" ;; esac
      fi
    fi
    # 1c. the CROSS-USER shim shape: a second OS user's launcher that names the
    #     real one via GRAFT_SAFE_BIN and execs graft-safe.sh. No .real sits
    #     beside it -- the real launcher lives in the OTHER user's home -- so 1b
    #     cannot see it either. Resolve through the path it names, then apply
    #     the same two parses to THAT. Must stay after 1b (a local .real wins)
    #     and before 2 (or a symlinked shim resolves against the shim).
    #     <agent-user> runs on exactly this shape here, which is why the fleet's own
    #     path stayed broken after 1b landed.
    if [ -z "${lib:-}" ]; then
      real="$(sed -n "s|.*GRAFT_SAFE_BIN=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*|\1|p" "$g" 2>/dev/null | head -1)"
      if [ -n "${real:-}" ] && [ -r "$real" ]; then
        lib="$(sed -n 's|.*exec node "\(.*\)/dist/cli.js".*|\1|p' "$real" 2>/dev/null)"
        if [ -z "${lib:-}" ]; then
          real="$(readlink -f "$real" 2>/dev/null)"
          case "$real" in */dist/cli.js) lib="${real%/dist/cli.js}" ;; esac
        fi
      fi
    fi
    # 2. the npm shape: the bin is a symlink chain ending at dist/cli.js
    if [ -z "${lib:-}" ]; then
      real="$(readlink -f "$g" 2>/dev/null)"
      case "$real" in */dist/cli.js) lib="${real%/dist/cli.js}" ;; esac
    fi
  fi
  [ -n "${lib:-}" ] || lib="$HOME/.local/lib/graft"
  printf '%s' "$lib"
}

# Candidate locations for the graft binary, most-specific first.
# Cron does NOT read the login profile that puts ~/.local/bin on PATH, so
# `command -v graft` is empty under cron even where graft is installed and
# working. Never rely on PATH alone here. (Converged from the hub box pack,
# 2026-09-16; our own cron also pins PATH, so this is defence in depth.)
_graft_candidates() {
  printf '%s\n' \
    "$(command -v graft 2>/dev/null)" \
    "$HOME/.local/bin/graft" \
    "$HOME/.npm-global/bin/graft" \
    /usr/local/bin/graft \
    /usr/bin/graft
}

_graft_bin() {
  local b
  while IFS= read -r b; do
    [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done < <(_graft_candidates)
  do_log "FATAL graft is not installed, and is not at any known prefix."
  do_log "FATAL looked on PATH, ~/.local/bin, ~/.npm-global/bin, /usr/local/bin, /usr/bin"
  do_log "FATAL install it first: csi-spl-orc/src/bash/features/graft/README.md"
  return 11
}

# Every graft invocation goes through here. Three guarantees in one place:
# no telemetry, no writes into the repo's tracked files, and a blanked proxy so
# egress fails loudly rather than silently succeeding.
_graft_run() {
  env HTTPS_PROXY= HTTP_PROXY= https_proxy= http_proxy= ALL_PROXY= all_proxy= \
      NO_PROXY='*' no_proxy='*' \
      DO_NOT_TRACK=1 GRAFT_NO_GITIGNORE=1 GRAFT_NO_IGNORE=1 \
      "$@"
}

# Re-apply the breadth-tier language registrations. Idempotent: the underlying
# script reports "already registered" and changes nothing on a second run.
# Re-assert the safety wrapper as the `graft` on PATH.
#
# graft-safe.sh forces DO_NOT_TRACK / GRAFT_TELEMETRY_DISABLED, clears the proxy
# env, and refuses `init`, `upgrade` and `--deep`. `graft` on PATH is a stub that
# execs it (scripts/graft-wrap.sh), with the real launcher renamed alongside it
# as `graft.real`.
#
# This runs on every index, for the same reason the grammar layer does: an
# install or upgrade of graft overwrites ~/.local/bin/graft with the stock
# two-line launcher and silently reverts the wrapper. Measured 2026-09-16 - the
# wrapper had been documented as in force while a bare exec was actually on
# PATH, so telemetry was held off by config alone with nothing re-asserting it.
# Verifying the control EXISTS is not the same as verifying it is IN FORCE.
#
# Idempotent: rewrites only when the file on PATH is not already the stub naming
# a raw launcher.
_graft_apply_safe_wrapper() {
  local fdir dst out
  fdir="$(_graft_feature_dir)" || return 11
  [ -r "$fdir/scripts/graft-wrap.sh" ] || { do_log "WARN  no graft-wrap.sh under $fdir - wrapper not asserted"; return 0; }

  dst="$(_graft_bin)" || return 11
  case "$dst" in *.real) return 0 ;; esac          # already resolved past the wrapper

  # The ONE wrapper shape, written by the same script the feature install uses
  # (scripts/graft-wrap.sh). A verbatim copy of graft-safe.sh, the shape this
  # function used to write, is not it: it names no launcher, and verify calls it
  # broken. graft-wrap.sh leaves an existing graft.real exactly as it is.
  bash "$fdir/scripts/graft-wrap.sh" --check "$dst" && return 0
  if out="$(bash "$fdir/scripts/graft-wrap.sh" "$dst" 2>&1)"; then
    do_log "INFO  re-asserted the graft-safe wrapper at $dst (real: $(bash "$fdir/scripts/graft-wrap.sh" --target "$dst"))"
  else
    do_log "WARN  could not assert the graft-safe wrapper at $dst: $out"
  fi
  return 0
}

_graft_apply_langs() {
  local fdir rv=0 pair name exts lib
  fdir="$(_graft_feature_dir)" || return 11
  # graft-register-lang.sh is handed the lib dir resolved HERE. Left to find it
  # itself it guessed $HOME/.local/lib/graft behind a wrapper whose graft.real is
  # an npm symlink chain, and failed every run with "no generic.js" while the
  # wasm step above it, which asks _graft_lib, had found the right dir.
  lib="$(_graft_lib)"
  for pair in $GRAFT_LANGS; do
    name="${pair%%:*}"; exts="${pair#*:}"
    if [ -z "$name" ] || [ -z "$exts" ] || [ "$name" = "$exts" ]; then
      do_log "FATAL malformed GRAFT_LANGS entry '$pair' - expected name:.ext,.ext"
      return 11
    fi
    # The vendor bundle does not carry every grammar we need (tree-sitter-wasm
    # 1.1.8 dropped sql). Install any locally-held wasm BEFORE registering, or
    # graft-register-lang.sh correctly refuses the language and init fails.
    local wsrc="$fdir/assets/wasm/tree-sitter-$name.wasm"
    local wdir
    if [ -f "$wsrc" ]; then
      wdir="$lib/node_modules/tree-sitter-wasm/out/$name"
      mkdir -p "$wdir" || { do_log "FATAL cannot create $wdir"; return 11; }
      cp -n "$wsrc" "$wdir/tree-sitter-$name.wasm" 2>/dev/null
      [ -f "$wdir/tree-sitter-$name.wasm" ] || { do_log "FATAL could not place grammar for $name"; return 11; }
      do_log "INFO  supplied local grammar wasm for $name"
    fi
    do_log "INFO  registering breadth-tier language '$name' ($exts)"
    GRAFT_LIB="$lib" bash "$fdir/scripts/graft-register-lang.sh" "$name" "$exts"
    rv=$?
    if [ $rv -ne 0 ]; then
      do_log "ERROR graft-register-lang.sh '$name' FAILED (rv=$rv)"
      return $rv
    fi
  done
  return 0
}

# Fingerprint of the language extension layer: the GENERIC_LANGS rows plus every
# installed tags query. graft caches extraction per file and will happily replay
# a cached result produced by an OLDER layer -- so a re-registered grammar or an
# edited .scm yields a build that reports success and serves a stale graph.
# Measured: a corrected sql.scm produced 0 lineage edges on a cached tree and
# 2370 after the cache was purged. Silent staleness, so we gate on it.
_graft_layer_fingerprint() {
  local lib
  lib="$(_graft_lib)"
  {
    sed -n "/GENERIC_LANGS/,/^\];/p" "$lib/dist/graph/generic.js" 2>/dev/null
    cat "$lib"/dist/graph/queries/*.scm 2>/dev/null
  } | sha256sum | cut -c1-16
}

# The index of a repo lives OUTSIDE it: scripts/graft-index-dir.sh, i.e.
# ${GRAFT_INDEX_ROOT:-$GRAFT_VAR_ROOT/index}/<slug of the repo path>. Every
# build passes it with graft's global --dir, so nothing is written into the tree.
_graft_index_dir() {  # REPO
  local fdir
  fdir="$(_graft_feature_dir)" || return 11
  bash "$fdir/scripts/graft-index-dir.sh" "$1"
}

# Purge a repo index whose cache predates the current layer. Returns 0 always -
# a repo with no index yet is not an error.
_graft_purge_if_stale() {
  local repo="$1" fp stamp idx
  idx="$(_graft_index_dir "$repo")" || { do_log "FATAL no index dir for $repo"; return 11; }
  fp="$(_graft_layer_fingerprint)"
  stamp="$idx/.cache/.layer-fingerprint"
  if [ -d "$idx" ]; then
    if [ ! -r "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$fp" ]; then
      do_log "INFO  language layer changed - purging stale index $idx"
      rm -rf "$idx" || { do_log "FATAL cannot purge $idx"; return 11; }
    fi
  fi
  return 0
}

_graft_stamp_layer() {
  local repo="$1" fp idx
  idx="$(_graft_index_dir "$repo")" || return 0
  fp="$(_graft_layer_fingerprint)"
  mkdir -p "$idx/.cache" 2>/dev/null
  printf "%s\n" "$fp" > "$idx/.cache/.layer-fingerprint" 2>/dev/null
  return 0
}

# Fingerprint of everything a build of REPO reads, so an unchanged repo is not
# rebuilt. graft's own per-file memo cannot be trusted to make that cheap: its
# extract cache is one JSON string, and past V8's ~512 MiB string limit the
# write throws a RangeError that graft swallows. Measured 2026-09-18 on a repo
# carrying a vendored CMS: "parsed: 15086 of 15086 files (0 replayed from
# cache)", ~520s, on every run, with no error printed.
#
# The inputs, in the order hashed:
#   - graft's code: every dist/**/*.js by content, the grammar wasm and package
#     manifests by name/size/mtime (a reinstall moves them), the layer fingerprint
#   - the repo's graft build config (.graft/config.json: include dirs etc.)
#   - the repo's git-visible tree, the exact set graft walks (git ls-files
#     --cached --others --exclude-standard): HEAD, plus the content of every path
#     `git status` names. core.fileMode=false: graft reads bytes, not modes, and
#     fleet mode churn must not force a rebuild.
# Prints nothing and returns 1 when a stamp cannot be trusted - a submodule or
# nested-repo walk, whose content git status here does not see - so the caller
# builds. Hashing never writes an object into the repo (hash-object without -w).
_graft_source_stamp() {  # REPO
  local repo="$1" lib head cfg st
  lib="$(_graft_lib)"
  [ -d "$lib/dist" ] || return 1
  cfg="$repo/.graft/config.json"
  if [ -r "$cfg" ] && grep -qE '"follow(Submodules|NestedRepos)"[[:space:]]*:[[:space:]]*true' "$cfg"; then
    return 1
  fi
  head="$(git -C "$repo" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || head=none
  st="$(git -C "$repo" -c core.fileMode=false status --porcelain=v1 -z --untracked-files=all 2>/dev/null | tr '\0' '\n')" \
    || return 1
  {
    printf 'graft\n'
    find "$lib/dist" -type f -name '*.js' -print0 | sort -z | xargs -0 -r cat | sha256sum
    find "$lib" -maxdepth 5 \( -name '*.wasm' -o -name package.json \) -type f -printf '%P %s %T@\n' 2>/dev/null | sort
    _graft_layer_fingerprint
    printf 'config\n'
    [ -r "$cfg" ] && cat "$cfg"
    printf 'head %s\nstatus\n%s\ncontent\n' "$head" "$st"
    # A rename's second -z record carries no "XY " prefix; the -f test drops
    # whatever that mangles, and a present path is hashed either way.
    printf '%s\n' "$st" | sed -n 's/^.. //p' \
      | ( cd "$repo" && while IFS= read -r p; do [ -f "$p" ] && printf '%s\n' "$p"; done | git hash-object --stdin-paths 2>/dev/null )
  } | sha256sum | cut -c1-32
}

# The stamp the last successful build of REPO recorded, or nothing.
_graft_source_stamp_file() {  # REPO
  local idx
  idx="$(_graft_index_dir "$1")" || return 1
  printf '%s/.cache/.source-stamp' "$idx"
}

# 0 when REPO's index is present and was built from exactly STAMP.
_graft_index_current() {  # REPO STAMP
  local repo="$1" stamp="$2" f idx
  [ -n "$stamp" ] || return 1
  idx="$(_graft_index_dir "$repo")" || return 1
  f="$idx/.cache/.source-stamp"
  [ -r "$f" ] && [ -s "$idx/.graph/wiring.json" ] || return 1
  [ "$(cat "$f" 2>/dev/null)" = "$stamp" ]
}

_graft_record_source_stamp() {  # REPO STAMP
  local f
  [ -n "$2" ] || return 0
  f="$(_graft_source_stamp_file "$1")" || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null
  printf '%s\n' "$2" > "$f" 2>/dev/null
  return 0
}

# Build one repo's index into its out-of-tree dir. A graft/ left inside the repo
# by an earlier in-tree build is named, never deleted: it may be someone's.
_graft_build_repo() {  # BIN REPO
  local bin="$1" repo="$2" idx
  idx="$(_graft_index_dir "$repo")" || { do_log "FATAL no index dir for $repo"; return 11; }
  mkdir -p "$idx" || { do_log "FATAL cannot create $idx"; return 11; }
  [ -d "$repo/graft" ] && do_log "WARN  $repo/graft is an in-tree index from an earlier build; the index is now $idx - remove the old one by hand"
  ( cd "$repo" && _graft_run "$bin" --dir "$idx" build . >/dev/null 2>&1 )
}
