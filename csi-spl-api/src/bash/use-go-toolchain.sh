#!/usr/bin/env bash
# Pick the newest Go toolchain installed under a root (default /usr/local)
# and prepend its bin directory to PATH.
#
# The api build and its tests set GOTOOLCHAIN=local, so they never download a
# toolchain. A patch release sits beside the box default
# (/usr/local/go1.25.14 next to /usr/local/go) and this selector uses it.
#
# spl_export_go_path [root]
#   Prints nothing. The winner is the newest of the trees under the root and
#   the go already on PATH. Returns 1 only when neither exists.
spl_export_go_path() {
  local root="${1:-/usr/local}"
  local best="" bestn=-1 g ver a b c num
  local nullglob_was=0
  local -a cands=()
  # shopt -q returns 1 when the option is off. Under set -e that line
  # aborts the caller (run-all-tests.sh) before it prints anything.
  if shopt -q nullglob; then nullglob_was=1; fi
  shopt -s nullglob
  cands=("$root"/go/bin/go "$root"/go[0-9].*/bin/go)
  if (( nullglob_was )); then
    :
  else
    shopt -u nullglob
  fi
  for g in "${cands[@]}"; do
    [[ -x "$g" ]] || continue
    ver=$("$g" env GOVERSION 2>/dev/null) || continue
    ver=${ver#go}
    ver=${ver%% *}
    IFS=. read -r a b c <<<"$ver"
    c=${c%%[^0-9]*}
    num=$((10#${a:-0} * 1000000 + 10#${b:-0} * 1000 + 10#${c:-0}))
    if (( num > bestn )); then
      bestn=$num
      best=$(dirname "$g")
    fi
  done
  # A go already on PATH counts too. CI's setup-go is 1.25.14 while
  # /usr/local/go on the runner is 1.25.1; prepending the older tree is how
  # msg-wipe.tst.sh failed (run 36180632878). An equal or newer PATH go wins
  # so we do not downgrade.
  local pathgo=""
  pathgo=$(command -v go 2>/dev/null || true)
  if [[ -n "$pathgo" && -x "$pathgo" ]]; then
    ver=$("$pathgo" env GOVERSION 2>/dev/null) || ver=""
    if [[ -n "$ver" ]]; then
      ver=${ver#go}
      ver=${ver%% *}
      IFS=. read -r a b c <<<"$ver"
      c=${c%%[^0-9]*}
      num=$((10#${a:-0} * 1000000 + 10#${b:-0} * 1000 + 10#${c:-0}))
      if (( num >= bestn && num > 0 )); then
        bestn=$num
        best=$(dirname "$pathgo")
      fi
    fi
  fi
  [[ -n "$best" ]] || return 1
  if [[ -n "$pathgo" && "$(dirname "$pathgo")" == "$best" ]]; then
    return 0
  fi
  export PATH="$best:$PATH"
}
