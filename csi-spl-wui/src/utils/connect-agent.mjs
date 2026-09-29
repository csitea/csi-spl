/**
 * "Connect an agent" (W12, spec 047, SPL-1166): the lines a tenant admin
 * pastes on the machine where an agent runs. They build the spool CLI from
 * the public repository, seat the machine as a box with the tenant root key
 * (spool keygen + hub-pin), keep it connected (hub-run), and register the
 * spool MCP server with Claude Code; a Cursor mcp.json does the same there.
 * B2 (join tokens) replaces the root key step later. The steps are the ones
 * csi-spl-doc/doc/help/connect-an-agent.md walks through. Node tests import
 * this file.
 */

export const SPOOL_REPO = 'https://github.com/csitea/csi-spl'

/* the hub's id rules (internal/msg: idRe, boxRe) */
export const validAgentId = (s) => typeof s === 'string' && /^[A-Z]{2,4}-\d+$/.test(s) && !s.startsWith('BOX-') && !s.startsWith('HUM-')
export const validBoxId = (s) => typeof s === 'string' && /^[a-z0-9][a-z0-9-]{0,31}$/.test(s)

/* a single-quoted shell word: the values are checked, this is belt and braces */
const q = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'"

/** The root key path as one shell word: a leading ~/ stays expandable. */
export function keyFileArg(path) {
  const p = String(path || '').trim()
  if (p.startsWith('~/')) return '"$HOME/' + p.slice(2).replace(/["\\$`]/g, '\\$&') + '"'
  return q(p)
}

/**
 * The hub URL a box talks to: the WUI's api base ({tenant} filled in, the lde
 * form), or this page's origin when the WUI and the hub share one (a
 * self-hosted compose stack).
 */
export function boxHubUrl(apiBase, origin, tenant = '') {
  const b = String(apiBase || '').trim().replace(/\/+$/, '').split('{tenant}').join(String(tenant || ''))
  if (/^https?:\/\/[^/]+$/i.test(b)) return b
  return String(origin || '').replace(/\/+$/, '')
}

/** The env file every later line (and the MCP server) reads. */
export function spoolEnv({ hubUrl, tenant, box }) {
  return [
    `export SPOOL_HUB_URL=${q(hubUrl)}`,
    `export SPOOL_TENANT=${q(tenant)}`,
    `export SPOOL_BOX_ID=${q(box)}`,
    'export SPOOL_ROOT="$HOME/.spool/root"',
    'export PATH="$HOME/.local/bin:$PATH"',
  ].join('\n')
}

/**
 * The one block to paste in a terminal (bash or zsh; needs git and Go).
 * keyFile is where the tenant root key sits on that machine.
 */
export function connectAgentScript({ hubUrl, tenant, box, agent, keyFile }) {
  /* one subshell: set -e stops at the first failing line without closing
     the terminal the block was pasted into */
  return [
    '(',
    'set -e',
    'mkdir -p ~/.spool ~/.local/bin',
    `[ -d ~/.spool/src ] || git clone --depth 1 ${SPOOL_REPO} ~/.spool/src`,
    '(cd ~/.spool/src/csi-spl-api/src/go/spool-hub-api && go build -o ~/.local/bin/spool ./cmd/spool)',
    "cat > ~/.spool/env <<'SPOOL_ENV'",
    spoolEnv({ hubUrl, tenant, box }),
    'SPOOL_ENV',
    '. ~/.spool/env',
    `mkdir -p "$SPOOL_ROOT/${agent}"`,
    `spool hub-pin --box "$SPOOL_BOX_ID" --pubkey "$(spool keygen)" --root-key ${keyFileArg(keyFile)}`,
    'nohup spool hub-run >~/.spool/hub-run.log 2>&1 &',
    `claude mcp add spool -- bash -c '. ~/.spool/env && exec spool mcp --as ${agent}'`,
    ')',
  ].join('\n')
}

/** Cursor: ~/.cursor/mcp.json (after the block above ran once on that machine). */
export function cursorMcpJson({ agent }) {
  return JSON.stringify({
    mcpServers: { spool: { command: 'bash', args: ['-c', `. ~/.spool/env && exec spool mcp --as ${agent}`] } },
  }, null, 2)
}

/** The first thing to tell the agent, so it answers what waits for it. */
export function firstPrompt(agent) {
  return `You are ${agent} on spool. Call spool_recv, answer every message with spool_send (to: its sender, task_id: its task_id, kind: msg), then call spool_recv again.`
}
