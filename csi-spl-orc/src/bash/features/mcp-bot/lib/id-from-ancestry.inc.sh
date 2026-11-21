# id-from-ancestry.inc.sh — _id_from_ancestry, the one copy: mcp-start.sh and
# mcp-start-chrome.sh source it (through readlink -f, so the installed symlinks
# resolve it in the checkout). It prints nothing when sourced: the wrappers'
# stdout is the MCP stdio channel. Test: tests/test-id-from-ancestry.sh.
# shellcheck shell=bash
_id_from_ancestry() {
  # Walk up the process tree; /proc/<pid>/cmdline is world-readable so this
  # works across the sudo user switch. Returns the first agent id found.
  local pid=$$ ppid tok prev _
  for _ in $(seq 1 25); do
    ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null) || return 1
    [ -n "$ppid" ] && [ "$ppid" != 0 ] && [ "$ppid" != 1 ] || return 1
    pid=$ppid
    # mistral vibe starts a stdio MCP server with a safe env only (specs/110),
    # so MCP_BOT_AGENT_ID never arrives: the agent id an ancestor of the same
    # user carries (the vibe process: SPOOL_AGENT_ID) is the next best source.
    tok=$(tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" | sed -n 's/^SPOOL_AGENT_ID=//p' | head -n 1 || true)
    if printf '%s' "$tok" | grep -E '^[acgmq]-[0-9]{3}$' >/dev/null; then
      printf '%s' "$tok"; return 0
    fi
    [ -r "/proc/$pid/cmdline" ] || continue
    prev=""
    while IFS= read -r -d '' tok; do
      # `claude --name <ID>` (spawn-claude.sh launches the harness this way)
      if [ "$prev" = "--name" ] && printf '%s' "$tok" | grep -E '^[A-Za-z][A-Za-z0-9._-]{0,63}$' >/dev/null; then
        printf '%s' "$tok"; return 0
      fi
      # `spawn-<kind>.sh <TITLE> …` — the launcher itself is an ancestor
      if printf '%s' "$prev" | grep -E '(^|/)spawn-[a-z-]+\.sh$' >/dev/null \
         && printf '%s' "$tok" | grep -E '^[A-Za-z][A-Za-z0-9._-]{0,63}$' >/dev/null; then
        printf '%s' "$tok"; return 0
      fi
      prev="$tok"
    done < "/proc/$pid/cmdline"
  done
  return 1
}
