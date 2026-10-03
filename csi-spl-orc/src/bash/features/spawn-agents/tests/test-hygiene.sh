#!/usr/bin/env bash
# The fork is self-contained and org-neutral: no path into the reference
# engine, none of its message root, no literal users, boxes or homes (in the
# shipped lib/, scripts/, assets/ and docs; the tests name what they forbid). Every
# script parses.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"

hits() { grep -rnE "$1" "$T_FEAT" --include='*.sh' --include='*.md' --include='*.conf' --include='*.tsv' | grep -v '/tests/' || true; }  # tests may NAME what they forbid

eq "no path into the reference engine" "" "$(hits '/ysg-box|ysg-box/|box-env\.inc|\.box-root')"
eq "no markdown-inbox root or MSGS_ROOT" "" "$(hits '/var/tmp/claude|MSGS_ROOT')"
eq "no literal users, boxes or homes" "" "$(hits '\bysg\b|ai-usr|claude-user|\btnk\b|/home/[a-z]')"
# specs/069 Y5: the directive feature moved out of the engine beside this one;
# the same bans hold there, and /signed-prompt + /tmux-color name no engine path.
T_DIR="$(cd "$T_FEAT/../directive" && pwd)"
dhits() { grep -rnE "$1" "$T_DIR" --include='*.sh' --include='*.md' | grep -v '/tests/' || true; }
eq "directive: no path into the reference engine" "" "$(dhits '/ysg-box|ysg-box/|box-env\.inc|\.box-root|box_env_resolve')"
eq "directive: no literal users, boxes or homes" "" "$(dhits '\bysg\b|ai-usr|claude-user|\btnk\b|\bosp\b|\bnea\b|/home/[a-z]|/var/tmp/')"
for f in "$T_DIR"/lib/*.sh "$T_DIR"/scripts/*.sh "$T_DIR"/tests/*.sh; do
  check "parses: directive/${f#"$T_DIR"/}" bash -n "$f"
done
eq "default spool root is /var/spool-hub" 1 "$(grep -c 'SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"' "$T_FEAT/lib/spool-env.inc.sh")"

for f in "$T_FEAT"/lib/*.sh "$T_FEAT"/scripts/*.sh "$T_FEAT"/tests/*.sh; do
  check "parses: ${f#"$T_FEAT"/}" bash -n "$f"
done
t_done
