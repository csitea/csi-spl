#!/usr/bin/env bash
# y6-graft.sh — install.sh step (spec 069 Y6): point this user's graft at the
# csi-spl copy of the graft feature (csi-spl-orc/src/bash/features/graft).
#
#   H1  <bin>/graft                  the wrapper stub, exec'ing this checkout's
#                                    graft-safe.sh (scripts/graft-wrap.sh writes
#                                    it; the raw launcher it names is kept)
#   L4  ~/.claude/skills/graft       -> <feature>/assets/skills/graft
#   L5  ~/.gemini/config/rules/graft.md -> <feature>/assets/agy-rules/graft.md
#                                    (only where ~/.gemini exists)
#
# A link is (re)pointed only when it is missing, broken, or points at another
# graft feature's assets (an older checkout, the retired engine copy); a real
# file or dir there, or a link to anything else, is left alone and named.
# graft itself is not installed here: with no graft on <bin>, H1 is skipped
# and named. C3/C4 (the cron lines) run <feature>/scripts/graft-cron.sh and
# are written by the box cron action, not here.
#
#   y6_graft_install ORC BIN DRY      DRY=1 prints the plan, changes nothing

y6_graft_install() {
  local orc="$1" bin="$2" dry="$3" feat rc=0 w real
  feat="$orc/src/bash/features/graft"
  _y6_say() { echo "spool-install: graft: $*" >&2; }
  [ -r "$feat/scripts/graft-wrap.sh" ] || { _y6_say "FATAL no graft feature at $feat"; return 1; }

  _y6_link() {  # DST SRC
    local dst="$1" src="$2" cur
    if [ -L "$dst" ]; then
      cur="$(readlink "$dst")"
      [ "$cur" = "$src" ] && return 0
      if [ -e "$dst" ]; then
        case "$cur" in
          */features/graft/assets/*) ;;
          *) _y6_say "$dst -> $cur is not a graft feature link: left alone"; return 0 ;;
        esac
      fi
    elif [ -e "$dst" ]; then
      _y6_say "$dst is a real file, not ours: left alone"; return 0
    fi
    if [ "$dry" = 1 ]; then echo "would: link $dst -> $src${cur:+ (was $cur)}"; return 0; fi
    mkdir -p "${dst%/*}" && ln -sfn "$src" "$dst" || { _y6_say "cannot link $dst"; return 1; }
    _y6_say "$dst -> $src${cur:+ (was $cur)}"
  }

  _y6_link "$HOME/.claude/skills/graft" "$feat/assets/skills/graft" || rc=1
  if [ -d "$HOME/.gemini" ]; then
    _y6_link "$HOME/.gemini/config/rules/graft.md" "$feat/assets/agy-rules/graft.md" || rc=1
  fi

  w="$bin/graft"
  if [ ! -e "$w" ]; then
    _y6_say "no graft at $w: the wrapper is skipped (install graft, then re-run)"
  else
    real=""
    grep -q 'graft-safe' "$w" 2>/dev/null && real="$(bash "$feat/scripts/graft-wrap.sh" --target "$w")"
    if [ "$dry" = 1 ]; then
      grep -qF "exec bash '$feat/scripts/graft-safe.sh'" "$w" 2>/dev/null \
        || echo "would: make $w the wrapper stub for $feat/scripts/graft-safe.sh (real: ${real:-$w.real})"
    else
      bash "$feat/scripts/graft-wrap.sh" "$w" ${real:+"$real"} >&2 || rc=1
    fi
  fi
  return "$rc"
}
