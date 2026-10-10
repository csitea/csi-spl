#!/usr/bin/env bash
# y14-agy-exit-rule.sh — install.sh step: the agy lane's exit rule (owner
# 2026-10-10, t1 3b755aef: exit clean "in the loop") into the rules dir agy
# loads every file of: ~/.gemini/config/rules/30-exit-after-accepted.md.
# A lane exits only after an ACCEPTED verdict, never on its own "done"
# (a-884 retired itself before its work was accepted).
#
# The source is spool-install/assets/agy/rules/<part>.md. The rendered file is
# that text plus one marker line "<!-- spool-install: sha256=<hex> -->" (the
# sha of the text above it): a re-run rewrites the file only while it is
# untouched (its text still hashes to its marker); a hand-edited file, or a
# same-named file without the marker, is left alone and named (FORCE_SKILLS=1
# replaces it). A HOME without ~/.gemini is skipped.
# Env: SPOOL_INSTALL_VENDOR_RULES=0 skips the step (install.sh sets it without
#      --fleet); SPOOL_INSTALL_AGY_ASSETS overrides the assets dir (tests).
# Reads install.sh's DRY and FORCE_SKILLS when set.

Y14_PART=30-exit-after-accepted

_y14_say() { echo "spool-install: agy-exit-rule: $*" >&2; }

# The marker sha a file carries, "" when it has none.
_y14_marker() { sed -n 's/^<!-- spool-install: sha256=\([0-9a-f]\{64\}\) -->$/\1/p' "$1" | tail -1; }

# The sha of a rendered file's text (every line but its marker).
_y14_body_sha() { grep -v '^<!-- spool-install: sha256=' "$1" | sha256sum | cut -d' ' -f1; }

spool_install_agy_exit_rule() {
  [ "${SPOOL_INSTALL_VENDOR_RULES:-1}" = 0 ] && return 0
  [ -d "$HOME/.gemini" ] || return 0
  local here src dst want have body
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  src="${SPOOL_INSTALL_AGY_ASSETS:-$here/../assets/agy}/rules/$Y14_PART.md"
  dst="$HOME/.gemini/config/rules/$Y14_PART.md"
  [ -f "$src" ] || { _y14_say "missing source $src"; return 1; }
  want="$(sha256sum <"$src" | cut -d' ' -f1)"
  if [ -f "$dst" ]; then
    have="$(_y14_marker "$dst")" body="$(_y14_body_sha "$dst")"
    [ "$have" = "$want" ] && [ "$body" = "$want" ] && { _y14_say "current: $dst"; return 0; }
    if [ "${FORCE_SKILLS:-0}" != 1 ] && { [ -z "$have" ] || [ "$body" != "$have" ]; }; then
      _y14_say "kept $dst: hand-edited or not ours (FORCE_SKILLS=1 replaces it)"
      return 0
    fi
  fi
  if [ "${DRY:-0}" = 1 ]; then echo "PLAN render $src -> $dst"; return 0; fi
  mkdir -p "${dst%/*}" || return 1
  { cat "$src"; echo "<!-- spool-install: sha256=$want -->"; } >"$dst.tmp.$$" && mv -f "$dst.tmp.$$" "$dst" || return 1
  _y14_say "wrote $dst"
}
