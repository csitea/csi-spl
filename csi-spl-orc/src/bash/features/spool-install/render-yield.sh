#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: hand the harness names back to install.sh in a claude-config render.
#   The satellite's role 07 renders the box claude-config with the ysg-box
#   engine (claude-render.sh). That engine is FROZEN for harness work and still
#   ships its own exit-clean, kill-your-self, agent-msg and spawn commands,
#   which call the ysg-box spawn-agents scripts (old ids: c-096 -> 'C-96').
#   install.sh (role 08) then leaves those files alone: no spool-install marker.
#   This drops, from ONE role's manifest of the render, every path install.sh
#   step 5b writes (.claude/skills/<n>/SKILL.md, .claude/commands/<n>.md,
#   .qwen/skills/<n>/SKILL.md for each spawn-agents asset), and the file.
#   claude-pack.sh packs only manifest rows, so the pack no longer carries
#   them; claude-apply.sh removes its earlier copy (in its previous manifest,
#   not in the pack); install.sh then writes the csi-spl one.
# Usage:   render-yield.sh --render DIR [--role agent] [--assets DIR]
# Output:  one "yield <path>" line per dropped row, then
#          "render-yield: role=<role> yielded=<n> kept=<n>"
# Exit:    0 done (also when nothing to drop), 2 usage / no such render
#------------------------------------------------------------------------------
set -uo pipefail

render="" role=agent
assets="$(cd "$(dirname "${BASH_SOURCE[0]}")/../spawn-agents/assets" 2>/dev/null && pwd)"
while [ $# -gt 0 ]; do
  case "$1" in
    --render) render="${2:-}"; shift 2 ;;
    --role) role="${2:-}"; shift 2 ;;
    --assets) assets="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "render-yield: unknown option '$1'" >&2; exit 2 ;;
  esac
done
man="$render/$role.manifest.tsv"
[ -n "$render" ] && [ -r "$man" ] || { echo "render-yield: no $role manifest in render '$render'" >&2; exit 2; }
[ -d "$assets/skills" ] && [ -d "$assets/commands" ] || { echo "render-yield: no harness assets at '$assets'" >&2; exit 2; }

declare -A OWN=()
for d in "$assets"/skills/*/; do
  n="$(basename "$d")"
  OWN[".claude/skills/$n/SKILL.md"]=1
  OWN[".qwen/skills/$n/SKILL.md"]=1
done
for f in "$assets"/commands/*.md; do
  n="$(basename "$f" .md)"
  OWN[".claude/commands/$n.md"]=1
  OWN[".qwen/skills/$n/SKILL.md"]=1
done

tmp="$man.tmp.$$"
yielded=0 kept=0
while IFS= read -r line || [ -n "$line" ]; do
  path="${line%%$'\t'*}"
  if [ "$path" != path ] && [ -n "${OWN[$path]:-}" ]; then
    echo "yield $path"
    rm -f "$render/$role/$path"
    yielded=$((yielded + 1))
    continue
  fi
  printf '%s\n' "$line" >>"$tmp"
  [ "$path" = path ] || kept=$((kept + 1))
done <"$man"
mv "$tmp" "$man" || exit 2
echo "render-yield: role=$role yielded=$yielded kept=$kept"
