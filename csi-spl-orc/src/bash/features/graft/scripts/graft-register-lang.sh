#!/usr/bin/env bash
# graft-register-lang.sh -- register a breadth-tier language in an installed graft.
#
#   bash graft-register-lang.sh bash '.sh,.bash'      # register + install tags
#   bash graft-register-lang.sh --check bash          # report only, change nothing
#   GRAFT_LIB=/path/to/graft bash graft-register-lang.sh ...
#
# graft's breadth tier is one row in GENERIC_LANGS plus one queries/<name>.scm.
# Both live in the INSTALLED dist/, not in a config file, so registering a
# language means editing a third-party package -- which a reinstall silently
# reverts. Hence: idempotent, backed up, re-runnable, and --check so the state
# can be asserted without changing it.
#
# It refuses to register an extension the depth tier already claims. That
# collision is not a merge; graft's own comment says breadth extensions "must
# NOT collide" with it, and the loser is decided by load order rather than by
# anything you would want to reason about.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAGS_DIR="${GRAFT_TAGS_DIR:-$HERE/../assets/tags}"

check_only=no
[ "${1:-}" = "--check" ] && { check_only=yes; shift; }
name="${1:-}"; exts="${2:-}"
[ -n "$name" ] || { echo "usage: graft-register-lang.sh [--check] <name> <.ext,.ext>" >&2; exit 2; }

# The lib dir behind a launcher: a script that execs node on .../dist/cli.js, or
# a symlink chain ending at dist/cli.js (the npm shape). Nothing when neither.
_lib_of() {  # LAUNCHER
  local l r
  [ -r "$1" ] || return 1
  l=$(sed -n 's|.*exec node "\(.*\)/dist/cli.js".*|\1|p' "$1" 2>/dev/null)
  if [ -z "$l" ]; then
    r=$(readlink -f "$1" 2>/dev/null)
    case "$r" in */dist/cli.js) l="${r%/dist/cli.js}" ;; esac
  fi
  [ -n "$l" ] && printf '%s' "$l"
}

# GRAFT_LIB wins. Otherwise look THROUGH the wrapper on PATH, the way the run
# actions' _graft_lib does: the launcher itself, the graft.real beside it, then
# the GRAFT_SAFE_BIN a cross-user shim names. Only then the $HOME guess.
LIB="${GRAFT_LIB:-}"
if [ -z "$LIB" ]; then
  # PATH first, then the prefixes an install uses: cron and sudo do not put
  # ~/.local/bin on PATH, and an empty lookup here used to mean the $HOME guess.
  g=$(command -v graft 2>/dev/null)
  for c in "$HOME/.local/bin/graft" "$HOME/.npm-global/bin/graft" /usr/local/bin/graft; do
    [ -n "$g" ] && break
    [ -x "$c" ] && g="$c"
  done
  if [ -n "$g" ]; then
    LIB=$(_lib_of "$g") || LIB=""
    [ -n "$LIB" ] || LIB=$(_lib_of "${g}.real") || LIB=""
    if [ -z "$LIB" ]; then
      r=$(sed -n "s|.*GRAFT_SAFE_BIN=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}.*|\1|p" "$g" 2>/dev/null | sed -n 1p)
      [ -n "$r" ] && { LIB=$(_lib_of "$r") || LIB=""; }
    fi
  fi
  [ -n "$LIB" ] || LIB="$HOME/.local/lib/graft"
fi
GEN="$LIB/dist/graph/generic.js"
QDIR="$LIB/dist/graph/queries"
[ -r "$GEN" ] || { echo "graft-register-lang: no generic.js at $GEN" >&2; exit 1; }

_registered() { grep -q "name: \"$name\"" "$GEN"; }
_wasm_present() {
  [ -r "$LIB/node_modules/tree-sitter-wasm/out/$name/tree-sitter-$name.wasm" ]
}
_query_installed() { [ -r "$QDIR/$name.scm" ]; }

if [ "$check_only" = yes ]; then
  _registered    && echo "ok   $name is in GENERIC_LANGS" || echo "MISS $name is not registered"
  _wasm_present  && echo "ok   grammar wasm present"      || echo "MISS no tree-sitter-$name.wasm in the bundle"
  _query_installed && echo "ok   queries/$name.scm installed" \
                   || echo "MISS no queries/$name.scm (language would fall back to the symbols-only walker)"
  _registered && _wasm_present && _query_installed
  exit $?
fi

[ -n "$exts" ] || { echo "graft-register-lang: extensions required to register" >&2; exit 2; }
_wasm_present || { echo "graft-register-lang: no tree-sitter-$name.wasm in the bundle -- nothing to register" >&2; exit 1; }

# The tags query is checked HERE, before the registry row is written, not by the
# --check at the end. Previously a language with no .scm had its GENERIC_LANGS
# row written and THEN failed the closing --check: the caller saw a non-zero
# exit while the language stayed registered. Partial application on a reported
# failure, and the next run says "already registered" about a state nobody
# intended. Refuse up front instead, so a failed run changes nothing.
#
# GRAFT_ALLOW_NO_TAGS=1 registers anyway, for a language whose symbols-only
# walker output is genuinely wanted. It is opt-in because the default should not
# be "index it badly and report success".
if [ ! -r "$TAGS_DIR/$name.scm" ] && [ "${GRAFT_ALLOW_NO_TAGS:-0}" != 1 ]; then
  echo "graft-register-lang: no $TAGS_DIR/$name.scm -- refusing to register $name" >&2
  echo "graft-register-lang: without a tags query it yields symbols and NO call edges," >&2
  echo "graft-register-lang: while still reporting a successful build. Ship a query, or" >&2
  echo "graft-register-lang: set GRAFT_ALLOW_NO_TAGS=1 if that is genuinely what you want." >&2
  exit 1
fi

# A breadth extension the depth tier already owns is a conflict, not an addition.
for e in ${exts//,/ }; do
  if grep -q "ext: \"$e\"" "$LIB/dist/graph/extract.js" 2>/dev/null; then
    echo "graft-register-lang: $e is already claimed by the depth tier (extract.js) -- refusing" >&2
    exit 1
  fi
done

stamp=$(date -u +%Y%m%dT%H%M%SZ)
if ! _registered; then
  cp -p "$GEN" "$GEN.pre-$name.$stamp" || exit 1
  arr=$(printf '"%s", ' ${exts//,/ } | sed 's/, $//; s/"\([^"]*\)"/"\1"/g')
  row="    { name: \"$name\", exts: [$arr], wasm: \"$name\" }, // registered by graft"
  # Insert as the last row of GENERIC_LANGS: the first "];" after the opening.
  awk -v row="$row" '
    /^export const GENERIC_LANGS = \[/ { inarr=1; print; next }
    inarr && /^\];/ { print row; inarr=0; print; next }
    { print }
  ' "$GEN" > "$GEN.new" && mv "$GEN.new" "$GEN" || exit 1
  echo "registered $name [$exts]  (backup: $(basename "$GEN.pre-$name.$stamp"))"
else
  echo "already registered: $name"
fi

if [ -r "$TAGS_DIR/$name.scm" ]; then
  if ! _query_installed || ! cmp -s "$TAGS_DIR/$name.scm" "$QDIR/$name.scm"; then
    [ -e "$QDIR/$name.scm" ] && cp -p "$QDIR/$name.scm" "$QDIR/$name.scm.pre.$stamp"
    mkdir -p "$QDIR" && cp "$TAGS_DIR/$name.scm" "$QDIR/$name.scm" && echo "installed queries/$name.scm"
  else
    echo "queries/$name.scm already current"
  fi
else
  # Not fatal: graft falls back to a node-kind walker. But that yields symbols
  # and NO edges while still reporting a successful build, which is precisely
  # the "populated index that knows nothing" this feature exists to avoid.
  echo "WARN no $TAGS_DIR/$name.scm -- $name would extract symbols with no call edges" >&2
fi

bash "$0" --check "$name"
