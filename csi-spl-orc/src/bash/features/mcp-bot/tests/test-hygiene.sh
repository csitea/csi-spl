#!/usr/bin/env bash
# The feature is org-neutral (no literal users, boxes or homes in the shipped
# scripts, assets and docs; the tests name what they forbid) and every script
# parses.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"

hits() { grep -rnE "$1" "$T_FEAT" --include="*.sh" --include="*.md" --include="*.json" | grep -v "/tests/" || true; }

eq "no path into the reference engine" "" "$(hits "/ysg-box|ysg-box/")"
eq "no literal users, boxes or homes" "" "$(hits "\bysg\b|ai-usr|claude-user|\btnk\b|/home/[a-z]")"
eq "config template keeps its placeholder" 1 "$(grep -c "__MCP_BOT_HOME__/cr-profile" "$T_FEAT/assets/mcp-config-chrome.json")"
check "config template is JSON" python3 -m json.tool "$T_FEAT/assets/mcp-config-chrome.json" >/dev/null

for f in "$T_FEAT"/scripts/*.sh "$T_FEAT"/tests/*.sh; do
  check "parses: ${f#"$T_FEAT"/}" bash -n "$f"
done
t_done
