#!/usr/bin/env bash
# _id_from_ancestry has one copy, lib/id-from-ancestry.inc.sh, and both
# wrappers source it. A probe that sources the lib runs under a parent that
# carries the id; each case is decided by that near parent, never by the real
# ancestry of whoever runs the test.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox

LIB="$T_FEAT/lib/id-from-ancestry.inc.sh"
PROBE="$T_TMP/probe.sh"
cat > "$PROBE" <<'PROBE_EOF'
. "$1" 2>/dev/null
out="$(_id_from_ancestry 2>/dev/null)"; rc=$?
if [ "$rc" -eq 0 ]; then printf '%s' "$out"; else printf 'rc=%s' "$rc"; fi
PROBE_EOF

# the trailing `; true` keeps the parent bash alive (no exec into the probe)
eq "an ancestor's SPOOL_AGENT_ID" "c-123" \
  "$(env SPOOL_AGENT_ID=c-123 bash -c 'bash "$1" "$2"; true' _ "$PROBE" "$LIB")"
eq "an ancestor's --name <id>, its SPOOL_AGENT_ID not an id" "c-777" \
  "$(env SPOOL_AGENT_ID=base bash -c 'bash "$1" "$2"; true' _ "$PROBE" "$LIB" --name c-777)"
printf 'bash "$2" "$3"; true\n' > "$T_TMP/spawn-agy.sh"
eq "an ancestor spawn-<kind>.sh <id>" "a-314" \
  "$(env -u SPOOL_AGENT_ID bash "$T_TMP/spawn-agy.sh" "a-314" "$PROBE" "$LIB")"

defs="$(cd "$T_FEAT" && grep -rlE '^_id_from_ancestry\(\) *\{' scripts lib 2>/dev/null | sort | tr '\n' ' ')"
eq "defined once, in lib/" "lib/id-from-ancestry.inc.sh " "$defs"
for w in mcp-start.sh mcp-start-chrome.sh; do
  eq "$w sources the lib" 1 \
    "$(grep -cE '^\. .*/\.\./lib/id-from-ancestry\.inc\.sh"$' "$T_SCRIPTS/$w")"
done
t_done
