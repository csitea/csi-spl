#!/usr/bin/env bash
# y7-tmux-links.sh - install.sh step (specs/069 Y7): drop the tmux links into
# the ysg-box engine and repoint ~/.tmux.conf at the csi-spl snippet.
#
# spool_install_y7_tmux_links <home> <snippet> <dry 0|1>
#   1. every symlink under <home>/.tmux whose TARGET names the engine (live
#      or broken; SPOOL_INSTALL_ENGINE_PATTERN, an ERE, default the engine
#      path pattern of do_check_ysg_box_deps) is listed
#   2. each uncommented `source-file` line of <home>/.tmux.conf that reads
#      one of those links is rewritten: the first becomes
#      `source-file <snippet>` (the csi-spl snippet already does what the
#      engine snippets did: badges, status line, window sort), unless the
#      conf already sources the snippet or the snippet is absent; every
#      other one is commented out. A backup is kept as
#      <home>/.tmux.conf.bak-spool-install-y7-<UTC>; a conf that is a symlink
#      is written through it
#   3. then the links go, and a subdir of ~/.tmux left empty by that goes too
# A re-run finds no engine link and changes nothing. Returns 0, or 6 when the
# conf cannot be rewritten (then no link is removed).
spool_install_y7_tmux_links() {
  local home="$1" snippet="$2" dry="$3"
  local pat="${SPOOL_INSTALL_ENGINE_PATTERN:-ysg-box(-[a-z]+)?/}"
  local conf="$home/.tmux.conf" l t rel line n=0 hit=0 repointed=0 bak tmp
  local -a links=() rels=()
  [ -d "$home/.tmux" ] || return 0
  while IFS= read -r -d '' l; do
    t="$(readlink "$l")" || continue
    [[ "$t" =~ $pat ]] || continue
    links+=("$l"); rels+=("${l#"$home/.tmux/"}")
  done < <(find "$home/.tmux" -type l -print0 2>/dev/null)
  [ "${#links[@]}" -gt 0 ] || return 0

  if [ -f "$conf" ]; then
    grep -qE "^[[:space:]]*source-file([[:space:]]+-q)?[[:space:]]+$(y7_ere "$snippet")[[:space:]]*$" "$conf" && repointed=1
    [ -f "$snippet" ] || repointed=1
    tmp="$(mktemp)" || return 6
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      rel="$(y7_sourced_rel "$line" "$home")"
      if [ -n "$rel" ] && y7_in "$rel" "${rels[@]}"; then
        hit=$((hit + 1))
        if [ "$repointed" = 0 ]; then
          printf '# spool-install (specs/069 Y7): was: %s\nsource-file %s\n' "$line" "$snippet" >>"$tmp"
          repointed=1
          [ "$dry" = 1 ] && echo "would: $conf:$n repoint '$line' at $snippet"
        else
          printf '# spool-install (specs/069 Y7): %s\n' "$line" >>"$tmp"
          [ "$dry" = 1 ] && echo "would: $conf:$n comment out '$line'"
        fi
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$conf"
    if [ "$hit" -gt 0 ] && [ "$dry" = 0 ]; then
      bak="$conf.bak-spool-install-y7-$(date -u +%Y%m%dT%H%M%SZ)"
      if ! { cp -p "$conf" "$bak" && cat "$tmp" >"$conf"; }; then
        rm -f "$tmp"; echo "spool-install: FATAL tmux: cannot rewrite $conf" >&2; return 6
      fi
      echo "spool-install: tmux: $hit engine source-file line(s) in $conf repointed (backup $bak)" >&2
    fi
    rm -f "$tmp"
  fi

  for l in "${links[@]}"; do
    if [ "$dry" = 1 ]; then echo "would: remove $l -> $(readlink "$l")"; continue; fi
    rm -f "$l" || continue
    [ "${l%/*}" = "$home/.tmux" ] || rmdir --ignore-fail-on-non-empty "${l%/*}" 2>/dev/null
  done
  [ "$dry" = 1 ] || echo "spool-install: tmux: ${#links[@]} engine link(s) removed under $home/.tmux" >&2
  return 0
}

# the path under ~/.tmux an uncommented `source-file` line reads, else ""
y7_sourced_rel() {
  local re
  re='^[[:space:]]*source-file([[:space:]]+-q)?[[:space:]]+"?(~|\$HOME|\$\{HOME\}|'"$(y7_ere "$2")"')/\.tmux/([^"[:space:]]+)"?[[:space:]]*$'
  if [[ "$1" =~ $re ]]; then printf '%s' "${BASH_REMATCH[3]}"; fi
}

y7_in() { local x="$1" e; shift; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

# a literal string as an ERE
y7_ere() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g'; }
