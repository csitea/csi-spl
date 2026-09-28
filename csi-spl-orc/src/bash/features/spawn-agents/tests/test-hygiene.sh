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
eq "default spool root is /var/spool-hub" 1 "$(grep -c 'SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"' "$T_FEAT/lib/spool-env.inc.sh")"

for f in "$T_FEAT"/lib/*.sh "$T_FEAT"/scripts/*.sh "$T_FEAT"/tests/*.sh; do
  check "parses: ${f#"$T_FEAT"/}" bash -n "$f"
done
t_done
