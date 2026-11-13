#!/usr/bin/env bash
# spl-cmd-guard-install.sh — set SPL_CMD_GUARD_IMPL for the installed
# force-push-guard-hook.sh of ONE home (SPL-5392, the Rust pilot; spec 011
# rust-candidates-analysis.md 6.2). Run as the home's user; the named action
# for both users of a box is do_spl_cmd_guard_mode.
#
#   spl-cmd-guard-install.sh <home> <py|shadow|rust> <binary|-> <dry 0|1>
#
# In <home>/.local/share/spool-agent/force-push-guard/ (spool-install y13):
#   shadow|rust  the binary must pass --self-test; it goes in as
#                spl-cmd-guard.new, passes --self-test again there, the old
#                one is kept as spl-cmd-guard.bak, then mv -T swaps it in
#   any mode     spl-cmd-guard.impl is written (tmp + mv), the hook reads it
#   py           the binary stays where it is: going back is one word
# Exit: 0 done (or planned), 2 a bad argument, 3 no installed hook in the
# home, 4 the binary fails --self-test (nothing changed).
set -uo pipefail
home="${1:-}" impl="${2:-}" bin="${3:-}" dry="${4:-1}"
case "$impl" in py | shadow | rust) ;; *) echo "spl-cmd-guard-install: mode must be py, shadow or rust: '$impl'" >&2; exit 2 ;; esac
case "$dry" in 0 | 1) ;; *) echo "spl-cmd-guard-install: dry must be 0 or 1" >&2; exit 2 ;; esac
dir="$home/.local/share/spool-agent/force-push-guard"
if [ ! -r "$dir/force-push-guard-hook.sh" ]; then
  echo "spl-cmd-guard-install: no installed hook in $dir: run do_install_force_push_guard first" >&2
  exit 3
fi
if [ "$impl" != py ]; then
  if [ "$bin" = - ] || [ ! -x "$bin" ] || ! "$bin" --self-test >/dev/null 2>&1; then
    echo "spl-cmd-guard-install: $bin is not a spl-cmd-guard that passes --self-test; nothing changed" >&2
    exit 4
  fi
fi
if [ "$dry" = 1 ]; then
  [ "$impl" = py ] || echo "PLAN $dir/spl-cmd-guard <- $bin ($("$bin" --version 2>/dev/null))"
  echo "PLAN $dir/spl-cmd-guard.impl <- $impl"
  exit 0
fi
if [ "$impl" != py ]; then
  cp "$bin" "$dir/spl-cmd-guard.new" && chmod 755 "$dir/spl-cmd-guard.new" || exit 4
  if ! "$dir/spl-cmd-guard.new" --self-test >/dev/null 2>&1; then
    rm -f "$dir/spl-cmd-guard.new"
    echo "spl-cmd-guard-install: the copy in $dir fails --self-test; nothing changed" >&2
    exit 4
  fi
  [ -e "$dir/spl-cmd-guard" ] && cp -p "$dir/spl-cmd-guard" "$dir/spl-cmd-guard.bak"
  mv -Tf "$dir/spl-cmd-guard.new" "$dir/spl-cmd-guard" || exit 4
  echo "OK $dir/spl-cmd-guard: $("$dir/spl-cmd-guard" --version)"
fi
printf '%s\n' "$impl" >"$dir/spl-cmd-guard.impl.new" && mv -Tf "$dir/spl-cmd-guard.impl.new" "$dir/spl-cmd-guard.impl" || exit 4
echo "OK $dir/spl-cmd-guard.impl = $impl"
