#!/usr/bin/env bash
# graft-wrap.sh — the ONE shape of the `graft` safety wrapper on PATH.
#
#   graft-wrap.sh --check BIN        rc 0 when BIN is the wrapper stub AND the
#                                    launcher it names is executable and raw
#   graft-wrap.sh --target BIN       print the launcher the stub names
#   graft-wrap.sh BIN [REAL]         make BIN the wrapper stub for launcher REAL
#
# The stub, and nothing else, is what both the graft feature's install and the
# run actions (_graft_apply_safe_wrapper) write:
#
#   #!/usr/bin/env bash
#   # installed by the graft feature — do not edit; edit the feature instead
#   export GRAFT_SAFE_BIN='<raw launcher>'
#   exec bash '<this feature>/scripts/graft-safe.sh' "$@"
#
# Two shapes used to exist — the feature wrote this stub, the action copied
# graft-safe.sh verbatim with no GRAFT_SAFE_BIN line — and each one's verify
# called the other's wrapper broken.
#
# REAL defaults to BIN.real. When BIN is a raw launcher and BIN.real does not
# exist, BIN is moved to BIN.real first, exactly once; an existing BIN.real is
# never overwritten or deleted. A REAL that is itself a wrapper is refused: a
# wrapper exec'ing a wrapper execs forever. graft-safe.sh is named by its
# physical path, so the stub does not depend on a compat symlink.

set -uo pipefail

SAFE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/graft-safe.sh"
die() { echo "graft-wrap: $*" >&2; exit 1; }

is_wrapper() { [ -r "$1" ] && grep -q 'graft-safe' "$1" 2>/dev/null; }
target_of()  { sed -n "s/^export GRAFT_SAFE_BIN='\(.*\)'$/\1/p" "$1" 2>/dev/null | head -1; }

case "${1:-}" in
  --check)
    b="${2:-}"; [ -n "$b" ] || die "usage: --check BIN"
    [ -x "$b" ] && is_wrapper "$b" || exit 1
    t="$(target_of "$b")"
    [ -n "$t" ] && [ -x "$t" ] && ! is_wrapper "$t"
    exit $? ;;
  --target)
    b="${2:-}"; [ -n "$b" ] || die "usage: --target BIN"
    target_of "$b"; exit 0 ;;
  -*|"") die "usage: graft-wrap.sh [--check|--target] BIN [REAL]" ;;
esac

BIN="$1"; REAL="${2:-}"
[ -r "$SAFE" ] || die "no graft-safe.sh at $SAFE"
case "$SAFE" in *"'"*) die "a quote in $SAFE cannot go into the stub" ;; esac

if [ -z "$REAL" ]; then
  REAL="$BIN.real"
  if [ -e "$BIN" ] && ! is_wrapper "$BIN" && [ ! -e "$REAL" ] && [ ! -L "$REAL" ]; then
    mv "$BIN" "$REAL" || die "cannot move the raw launcher $BIN to $REAL"
    echo "graft-wrap: raw launcher $BIN -> $REAL"
  fi
fi
[ -x "$REAL" ] || die "no executable raw launcher at $REAL"
is_wrapper "$REAL" && die "$REAL is itself a wrapper — it would exec forever"
case "$REAL" in *"'"*) die "a quote in $REAL cannot go into the stub" ;; esac

want="$(printf '%s\n' '#!/usr/bin/env bash' \
  '# installed by the graft feature — do not edit; edit the feature instead' \
  "export GRAFT_SAFE_BIN='$REAL'" \
  "exec bash '$SAFE' \"\$@\"")"
if [ -f "$BIN" ] && [ "$(cat "$BIN")" = "$want" ]; then
  exit 0
fi
mkdir -p "$(dirname "$BIN")" || die "cannot create $(dirname "$BIN")"
tmp="$(mktemp "$(dirname "$BIN")/.graft-wrap.XXXXXX")" || die "cannot write beside $BIN"
printf '%s\n' "$want" > "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$BIN" \
  || { rm -f "$tmp"; die "cannot install the wrapper at $BIN"; }
echo "graft-wrap: $BIN -> wrapper (real: $REAL)"
