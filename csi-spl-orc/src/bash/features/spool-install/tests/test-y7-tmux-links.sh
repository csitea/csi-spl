#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034  # the check strings are eval-ed: they read out, want, before, rca
#------------------------------------------------------------------------------
# Purpose: install.sh step y7-tmux-links (specs/069 Y7), hermetic. Two sandbox
#          homes, never the real one:
#   agent home: the 12 BROKEN engine links measured on 2026-10-03 (spec 069
#     2.3 L6+L7) and a ~/.tmux.conf sourcing two of them (lines 155, 160)
#   box home:   the same 12 links LIVE into a fake engine dir, a conf that
#     already sources the csi-spl snippet
#   1. the seed: 12 broken links in the agent home, 12 engine links in each
#   2. --dry-run (through install.sh): every link and both lines named, the
#      homes unchanged
#   3. the step: 0 broken links and 0 engine links in either home; a link
#      that does not name the engine, and the plugins dir, are kept; the
#      emptied scripts/ dir is gone
#   4. the agent conf: the first engine line repointed at the snippet, the
#      second commented out, every other line byte-identical, a backup
#   5. the box conf already sources the snippet: nothing repointed twice
#   6. a re-run changes nothing and writes no second backup
#   7. a conf that is a symlink is written through, the link kept
#   8. an absent snippet: the engine lines are commented out, not repointed
#   9. a caller under `set -e` (an unmatched conf line is no error)
# Control: Y7_TEST_CONTROL=noop swaps the step for a no-op; the run must FAIL.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
STEP="$TEST_DIR/../steps/y7-tmux-links.sh"
INSTALL="$TEST_DIR/../install.sh"
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# shellcheck source=/dev/null
. "$STEP"
[ "${Y7_TEST_CONTROL:-}" = noop ] && spool_install_y7_tmux_links() { return 0; }

GONE="$T/gone/r10/engine/ysg-box-orc/src/bash/features"
LIVE="$T/opt/ysg-box/ysg-box-orc/src/bash/features"
LINKS="agent-status.conf:spawn-agents/assets/tmux-agent-status.conf
tmux-window-events.conf:tmux-windows/assets/tmux-window-events.conf
tmux-windows.conf:tmux-windows/assets/tmux-windows.conf
window-sort.conf:tmux-windows/assets/tmux-windows.conf
scripts/agent-name.sh:spawn-agents/scripts/agent-name.sh
scripts/agent-state.inc.sh:spawn-agents/scripts/agent-state.inc.sh
scripts/agent-top.sh:spawn-agents/scripts/agent-top.sh
scripts/riname.sh:spawn-agents/scripts/riname.sh
scripts/tmux-sort-pause.sh:tmux-windows/scripts/tmux-sort-pause.sh
scripts/tmux-sort-windows.sh:tmux-windows/scripts/tmux-sort-windows.sh
scripts/tmux-window-color.sh:tmux-windows/scripts/tmux-window-color.sh
scripts/tmux-window-event.sh:tmux-windows/scripts/tmux-window-event.sh"

seed() { # <home> <engine>
  local h="$1" e="$2" rel tgt
  mkdir -p "$h/.tmux/scripts" "$h/.tmux/plugins/tpm" "$h/.local/share/spool-agent"
  echo '# csi-spl snippet' >"$h/.local/share/spool-agent/tmux-agent-status.conf"
  while IFS=: read -r rel tgt; do ln -s "$e/$tgt" "$h/.tmux/$rel"; done <<<"$LINKS"
  ln -s "$h/.local/share/spool-agent/tmux-agent-status.conf" "$h/.tmux/own.conf"
}
broken() { find "$1" -xtype l 2>/dev/null | wc -l; }
engine() { local l c=0; while IFS= read -r l; do [[ "$(readlink "$l")" == *ysg-box* ]] && c=$((c + 1)); done < <(find "$1" -type l); echo "$c"; }

A="$T/agent" B="$T/box"
mkdir -p "$T/opt"
while IFS=: read -r _ tgt; do mkdir -p "$(dirname "$LIVE/$tgt")"; touch "$LIVE/$tgt"; done <<<"$LINKS"
seed "$A" "$GONE"; seed "$B" "$LIVE"
SNA="$A/.local/share/spool-agent/tmux-agent-status.conf"
SNB="$B/.local/share/spool-agent/tmux-agent-status.conf"
{
  echo "run '~/.tmux/plugins/tpm/tpm'"
  echo '# Snippet lives in the engine; ~/.tmux/agent-status.conf is a symlink into it.'
  echo 'source-file ~/.tmux/agent-status.conf'
  echo 'set -g mouse on'
  echo '# Snippet lives in the engine; ~/.tmux/window-sort.conf is a symlink into it.'
  echo 'source-file ~/.tmux/window-sort.conf'
  echo '# source-file ~/.tmux/tmux-windows.conf'
} >"$A/.tmux.conf"
{ echo 'set -g mouse on'; echo "source-file $SNB"; } >"$B/.tmux.conf"

# 1. the seed
check "seed: 12 broken links in the agent home" '[ "$(broken "$A")" = 12 ]'
check "seed: 12 engine links in each home" '[ "$(engine "$A")" = 12 ] && [ "$(engine "$B")" = 12 ]'

# 2. --dry-run through install.sh: the one hook line is wired, nothing changes
sum() { find "$1" -printf '%p %l\n' | sort | md5sum; md5sum <"$1/.tmux.conf"; }
before="$(sum "$A")"
out="$(HOME="$A" SPOOL_INSTALL_PREFIX="$A/.local" XDG_CONFIG_HOME="$T/cfg" bash "$INSTALL" --dry-run --cli none --no-seat 2>&1)"
[ "${Y7_TEST_CONTROL:-}" = noop ] && out=""
check "dry-run: names all 12 links" '[ "$(grep -c "^would: remove $A/.tmux/" <<<"$out")" = 12 ]'
check "dry-run: repoints line 3, comments out line 6" \
  'grep -q "^would: $A/.tmux.conf:3 repoint" <<<"$out" && grep -q "^would: $A/.tmux.conf:6 comment out" <<<"$out"'
check "dry-run: the home is unchanged" '[ "$(sum "$A")" = "$before" ]'

# 3. the step on both homes
spool_install_y7_tmux_links "$A" "$SNA" 0 2>"$T/a.err"; rca=$?
spool_install_y7_tmux_links "$B" "$SNB" 0 2>"$T/b.err"; rcb=$?
check "step: exit 0 on both homes" '[ "$rca" = 0 ] && [ "$rcb" = 0 ]'
check "step: 0 broken links in either home" '[ "$(broken "$A")" = 0 ] && [ "$(broken "$B")" = 0 ]'
check "step: 0 engine links in either home" '[ "$(engine "$A")" = 0 ] && [ "$(engine "$B")" = 0 ]'
check "step: a non-engine link and plugins/ are kept" '[ -L "$A/.tmux/own.conf" ] && [ -d "$A/.tmux/plugins/tpm" ]'
check "step: the emptied scripts/ dir is gone" '[ ! -e "$A/.tmux/scripts" ] && [ ! -e "$B/.tmux/scripts" ]'

# 4. the agent conf
want="run '~/.tmux/plugins/tpm/tpm'
# Snippet lives in the engine; ~/.tmux/agent-status.conf is a symlink into it.
# spool-install (specs/069 Y7): was: source-file ~/.tmux/agent-status.conf
source-file $SNA
set -g mouse on
# Snippet lives in the engine; ~/.tmux/window-sort.conf is a symlink into it.
# spool-install (specs/069 Y7): source-file ~/.tmux/window-sort.conf
# source-file ~/.tmux/tmux-windows.conf"
check "agent conf: repointed, commented, the rest identical" '[ "$(cat "$A/.tmux.conf")" = "$want" ]'
check "agent conf: one backup holding the old conf" \
  '[ "$(ls "$A"/.tmux.conf.bak-spool-install-y7-* 2>/dev/null | wc -l)" = 1 ] && grep -qx "source-file ~/.tmux/window-sort.conf" "$A"/.tmux.conf.bak-spool-install-y7-*'

# 5. the box conf
check "box conf: unchanged, no backup" \
  '[ "$(cat "$B/.tmux.conf")" = "set -g mouse on
source-file $SNB" ] && ! ls "$B"/.tmux.conf.bak-spool-install-y7-* >/dev/null 2>&1'

# 6. a re-run
before="$(sum "$A")"
spool_install_y7_tmux_links "$A" "$SNA" 0 2>/dev/null
check "re-run: nothing changes, no second backup" \
  '[ "$(sum "$A")" = "$before" ] && [ "$(ls "$A"/.tmux.conf.bak-spool-install-y7-* | wc -l)" = 1 ]'

# 7. a conf that is a symlink (a dotfiles checkout)
C="$T/dot"; seed "$C" "$GONE"; mkdir -p "$T/dotfiles"
printf 'source-file $HOME/.tmux/agent-status.conf\n' >"$T/dotfiles/tmux.conf"
ln -s "$T/dotfiles/tmux.conf" "$C/.tmux.conf"
spool_install_y7_tmux_links "$C" "$C/.local/share/spool-agent/tmux-agent-status.conf" 0 2>/dev/null
check "symlinked conf: written through, the link kept" \
  '[ -L "$C/.tmux.conf" ] && grep -qx "source-file $C/.local/share/spool-agent/tmux-agent-status.conf" "$T/dotfiles/tmux.conf"'

# 8. no snippet installed (--no-skills): comment out, never point at nothing
D="$T/noskills"; seed "$D" "$GONE"; rm -f "$D/.local/share/spool-agent/tmux-agent-status.conf"
printf 'source-file -q "%s/.tmux/agent-status.conf"\n' "$D" >"$D/.tmux.conf"
spool_install_y7_tmux_links "$D" "$D/.local/share/spool-agent/tmux-agent-status.conf" 0 2>/dev/null
check "no snippet: the line is commented out" \
  '[ "$(cat "$D/.tmux.conf")" = "# spool-install (specs/069 Y7): source-file -q \"$D/.tmux/agent-status.conf\"" ] && [ "$(engine "$D")" = 0 ]'

# 9. set -e in the caller
E="$T/sete"; seed "$E" "$GONE"; printf 'set -g mouse on\nsource-file ~/.tmux/agent-status.conf\n' >"$E/.tmux.conf"
( set -e; spool_install_y7_tmux_links "$E" "$E/.local/share/spool-agent/tmux-agent-status.conf" 0 2>/dev/null ); rce=$?
check "set -e caller: exit 0, links gone" '[ "$rce" = 0 ] && [ "$(engine "$E")" = 0 ]'

echo "test-y7-tmux-links: $((n - fails))/$n passed"
[ "$fails" = 0 ]
