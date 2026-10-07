#!/usr/bin/env bash
# y5-adopt-skills.sh — sourced by install.sh just before step 5b (specs/069 Y5).
#
# Four of the agent's commands and skills used to be rendered by the frozen box
# engine and now ship from spawn-agents/assets: /signed-prompt, /tmux-color,
# paste-html-into-chrome and spec-kit-tasks. Step 5b never touches a file that
# lacks its spool-install marker ("not ours"), so on a box the engine rendered,
# those four would stay the engine's copy for good. This step hands them over:
# for exactly those names, an UNMARKED file is moved aside to
# <file>.bak-spool-install (a symlinked skill dir is unlinked: its content
# lives in its target), and 5b then writes the marked csi-spl copy. A marked
# file is 5b's business and is left alone; any other name is never touched.
#
# Uses install.sh's DRY, plan and say. Returns 0, or 7 when a file cannot be
# moved (install.sh's "a file in the way is not ours").

y5_adopt_skills() {
  local home="${1:-$HOME}" rel dst link
  local mark='<!-- spool-install: sha256='
  for rel in commands/signed-prompt.md skills/tmux-color/SKILL.md \
             skills/paste-html-into-chrome/SKILL.md skills/spec-kit-tasks/SKILL.md; do
    dst="$home/.claude/$rel"
    link="${dst%/SKILL.md}"
    if [ "$link" != "$dst" ] && [ -L "$link" ]; then
      if [ "$DRY" = 1 ]; then plan "unlink $link (-> $(readlink "$link")) so step 5b renders the csi-spl copy"; continue; fi
      rm -f "$link" || return 7
      say "skills: unlinked $link (the engine's copy); step 5b renders ours"
      continue
    fi
    [ -f "$dst" ] || continue
    grep -qF "$mark" "$dst" && continue
    if [ "$DRY" = 1 ]; then plan "move the engine's $dst aside to $dst.bak-spool-install so step 5b renders the csi-spl copy"; continue; fi
    mv -f "$dst" "$dst.bak-spool-install" || return 7
    say "skills: adopted $dst (the engine's copy kept as $dst.bak-spool-install)"
  done
  return 0
}

# The same hand-over for agy (~/.gemini/config/skills): the frozen engine
# copied every skill there unmarked, so its /exit-clean stayed the engine's
# (no --retire, a script path that no longer exists) and agy ids never retired.
# Exactly the skill names spawn-agents/assets ships; any other name (graft,
# the user's own) is never touched.
y5_adopt_agy_skills() {
  local home="${1:-$HOME}" assets="$2" n dst dir
  local mark='<!-- spool-install: sha256='
  for dir in "$assets"/skills/*/; do
    n="$(basename "$dir")"
    dst="$home/.gemini/config/skills/$n/SKILL.md"
    if [ -L "${dst%/SKILL.md}" ]; then
      if [ "$DRY" = 1 ]; then plan "unlink ${dst%/SKILL.md} so step 5b renders the csi-spl copy"; continue; fi
      rm -f "${dst%/SKILL.md}" || return 7
      say "skills: unlinked ${dst%/SKILL.md} (the engine's copy); step 5b renders ours"
      continue
    fi
    [ -f "$dst" ] || continue
    grep -qF "$mark" "$dst" && continue
    if [ "$DRY" = 1 ]; then plan "move the engine's $dst aside to $dst.bak-spool-install so step 5b renders the csi-spl copy"; continue; fi
    mv -f "$dst" "$dst.bak-spool-install" || return 7
    say "skills: adopted $dst (the engine's copy kept as $dst.bak-spool-install)"
  done
  return 0
}
