#!/usr/bin/env bash
#------------------------------------------------------------------------------
# satellite-replicate-ai-user.sh — runs ON the satellite as its box user, sent
# by do_satellite_replicate_ai_user, with the box PC's AI-user config as a
# tar.gz on stdin. Idempotent; one verdict line per part:
#   REPL <part> OK|CHANGED|FAIL <detail>
# Env: BOXHOME (the box PC's home path, rewritten to $HOME in the copied text
#      files), PERSIST (home dirs that live on the data disk), GIT_NAME,
#      GIT_EMAIL (optional), PARTS (default "home claude tmux git gh";
#      "home" alone reads no stdin and copies nothing from the box).
#------------------------------------------------------------------------------
set -uo pipefail
: "${BOXHOME:?BOXHOME must be set}" "${PERSIST:?PERSIST must be set}"
DATA_HOME="/mnt/data/home/$(id -un)"
fails=0
verdict() { echo "REPL $1 $2 ${3:-}"; [[ "$2" == FAIL ]] && fails=$((fails + 1)); return 0; }
stage=$(mktemp -d) || exit 1
trap 'rm -rf "$stage"' EXIT
PARTS=" ${PARTS:-home claude tmux git gh} "
if [[ "$PARTS" != " home " ]]; then
  tar -C "$stage" -xzf - || { verdict copy FAIL "tar from the box"; exit 1; }
fi

# --- home: the stateful dirs live on the data disk -----------------------------
part_home() {
  local d src dst moved=() kept=()
  mountpoint -q /mnt/data || { verdict home FAIL "/mnt/data is not mounted"; return; }
  [[ -d "$DATA_HOME" ]] || sudo -n install -d -m 750 -o "$(id -un)" -g "$(id -gn)" "$DATA_HOME" \
    || { verdict home FAIL "cannot create $DATA_HOME"; return; }
  for d in $PERSIST; do
    src="$HOME/$d" dst="$DATA_HOME/$d"
    if [[ -L "$src" && "$(readlink "$src")" == "$dst" ]]; then kept+=("$d"); continue; fi
    if [[ -e "$dst" ]]; then
      # a recreate: the data copy wins, the fresh boot one is set aside
      if [[ -e "$src" || -L "$src" ]]; then rm -rf "$src.boot-aside"; mv "$src" "$src.boot-aside"; fi
    elif [[ -e "$src" ]]; then
      # a cross-disk mv copies, then deletes: a read-only tree (the Go module
      # cache) copies fine and then cannot be deleted, so make it writable first
      chmod -R u+w "$src" 2>/dev/null
      mv "$src" "$dst" || { verdict home FAIL "mv ~/$d -> $dst"; return; }
    else
      mkdir -p "$dst"
    fi
    ln -s "$dst" "$src" || { verdict home FAIL "ln ~/$d"; return; }
    moved+=("$d")
  done
  ((${#moved[@]})) && verdict home CHANGED "on $DATA_HOME: ${moved[*]}" || verdict home OK "${#kept[@]} dirs on $DATA_HOME"
}

# --- claude / tmux: the copied config, the box home rewritten ------------------
rewrite_home() {
  [[ "$BOXHOME" == "$HOME" ]] && return 0
  grep -rlIF -- "$BOXHOME" "$stage" 2>/dev/null | while IFS= read -r f; do
    sed -i "s#${BOXHOME}#${HOME}#g" "$f"
  done
}

part_claude() {
  local n before after
  [[ -d "$stage/.claude" ]] || { verdict claude OK "nothing to copy"; return; }
  mkdir -p "$HOME/.claude"
  before=$(cd "$HOME/.claude" && find CLAUDE.md settings.json statusline-title.sh skills commands projects -type f 2>/dev/null -exec md5sum {} + | sort | md5sum)
  if [[ -f "$stage/.claude/settings.json" ]]; then
    local cur="$HOME/.claude/settings.json" tmp
    tmp=$(mktemp)
    if [[ -s "$cur" ]]; then
      # this box's keys win; the satellite's own hooks (spool-install) stay
      jq -s '.[0] * (.[1] | del(.hooks))' "$cur" "$stage/.claude/settings.json" >"$tmp"
    else
      jq 'del(.hooks)' "$stage/.claude/settings.json" >"$tmp"
    fi || { rm -f "$tmp"; verdict claude FAIL "settings.json merge"; return; }
    cmp -s "$tmp" "$cur" && rm -f "$tmp" || mv "$tmp" "$cur"
    rm -f "$stage/.claude/settings.json"
  fi
  cp -a "$stage/.claude/." "$HOME/.claude/" || { verdict claude FAIL "copy ~/.claude"; return; }
  after=$(cd "$HOME/.claude" && find CLAUDE.md settings.json statusline-title.sh skills commands projects -type f 2>/dev/null -exec md5sum {} + | sort | md5sum)
  n=$(find "$HOME/.claude/skills" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
  [[ "$before" == "$after" ]] && verdict claude OK "$n skills, settings, memory" || verdict claude CHANGED "$n skills, settings, memory"
}

part_tmux() {
  [[ -e "$stage/.tmux.conf" || -d "$stage/.tmux" ]] || { verdict tmux OK "nothing to copy"; return; }
  local c=0
  if [[ -e "$stage/.tmux.conf" ]] && ! cmp -s "$stage/.tmux.conf" "$HOME/.tmux.conf"; then cp "$stage/.tmux.conf" "$HOME/.tmux.conf"; c=1; fi
  if [[ -d "$stage/.tmux" ]]; then mkdir -p "$HOME/.tmux"; cp -a "$stage/.tmux/." "$HOME/.tmux/"; fi
  ((c)) && verdict tmux CHANGED "~/.tmux.conf" || verdict tmux OK "~/.tmux.conf"
}

part_git() {
  local c=0 helper
  helper='!f() { echo username=x-access-token; echo "password=$(cat "$HOME/.github/token")"; }; f'
  if [[ -n "${GIT_NAME:-}" && "$(git config --global user.name)" != "$GIT_NAME" ]]; then git config --global user.name "$GIT_NAME"; c=1; fi
  if [[ -n "${GIT_EMAIL:-}" && "$(git config --global user.email)" != "$GIT_EMAIL" ]]; then git config --global user.email "$GIT_EMAIL"; c=1; fi
  if [[ "$(git config --global credential.https://github.com.helper)" != "$helper" ]]; then
    git config --global credential.https://github.com.helper "$helper"; c=1
  fi
  ((c)) && verdict git CHANGED "identity + github https helper" || verdict git OK "identity + github https helper"
}

part_gh() {
  [[ -r "$HOME/.github/token" ]] || { verdict gh FAIL "no ~/.github/token: DRY_RUN=0 ./run -a do_satellite_creds_push"; return; }
  if gh auth status -h github.com >/dev/null 2>&1; then verdict gh OK "authenticated"; return; fi
  gh auth login -h github.com --with-token <"$HOME/.github/token" >/dev/null 2>&1 && gh auth status -h github.com >/dev/null 2>&1 \
    && verdict gh CHANGED "authenticated from ~/.github/token" || verdict gh FAIL "gh auth login --with-token"
}

[[ "$PARTS" == *" home "* ]] && part_home
rewrite_home
[[ "$PARTS" == *" claude "* ]] && part_claude
[[ "$PARTS" == *" tmux "* ]] && part_tmux
[[ "$PARTS" == *" git "* ]] && part_git
[[ "$PARTS" == *" gh "* ]] && part_gh
echo "REPLICA fails=$fails"
exit $((fails > 0))
