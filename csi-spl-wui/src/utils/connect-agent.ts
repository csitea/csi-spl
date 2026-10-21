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

import { isWritableAgentId } from '~/utils/agent-id.mjs'

/**
 * The source repository the lines clone: cnf env.wui.repo_clone_url
 * (/config.json repoCloneUrl). '' = this site names none, and the guide
 * hides the lines (no fallback repository).
 */
export function spoolRepo(cloneUrl: unknown): string {
  const s = String(cloneUrl ?? '').trim().replace(/\/+$/, '')
  return /^https?:\/\/[^\s"'<>`$\\]+$/i.test(s) ? s : ''
}

/* the hub's id rules (internal/msg: idRe, boxRe; spec 061: c-004, or a legacy
   id until LEGACY_ID_UNTIL - this is a write path) */
export const validAgentId = (s: unknown): boolean => typeof s === 'string' && isWritableAgentId(s)
export const validBoxId = (s: unknown): boolean => typeof s === 'string' && /^[a-z0-9][a-z0-9-]{0,31}$/.test(s)

/* a single-quoted shell word: the values are checked, this is belt and braces */
const q = (s: unknown): string => "'" + String(s).replace(/'/g, "'\\''") + "'"

/** The root key path as one shell word: a leading ~/ stays expandable. */
export function keyFileArg(path: unknown): string {
  const p = String(path || '').trim()
  if (p.startsWith('~/')) return '"$HOME/' + p.slice(2).replace(/["\\$`]/g, '\\$&') + '"'
  return q(p)
}

/**
 * The hub URL a box talks to: the WUI's api base ({tenant} filled in, the lde
 * form), or this page's origin when the WUI and the hub share one (a
 * self-hosted compose stack).
 */
export function boxHubUrl(apiBase: unknown, origin: unknown, tenant: unknown = ''): string {
  const b = String(apiBase || '').trim().replace(/\/+$/, '').split('{tenant}').join(String(tenant || ''))
  if (/^https?:\/\/[^/]+$/i.test(b)) return b
  return String(origin || '').replace(/\/+$/, '')
}

/** The env file every later line (and the MCP server) reads. */
function spoolEnv({ hubUrl, tenant, box }: { hubUrl: string, tenant: string, box: string }): string {
  return [
    `export SPOOL_HUB_URL=${q(hubUrl)}`,
    `export SPOOL_TENANT=${q(tenant)}`,
    `export SPOOL_BOX_ID=${q(box)}`,
    'export SPOOL_ROOT="$HOME/.spool/root"',
    'export PATH="$HOME/.local/bin:$PATH"',
  ].join('\n')
}

/**
 * The oldest Go that builds the spool CLI: the `go` line of
 * csi-spl-api/src/go/spool-hub-api/go.mod (a unit test compares the two).
 */
export const GO_MIN = '1.26.10'

/**
 * The tools the block checks before it clones (SPL-2695): a miss stops it
 * with one line naming what is missing, the minimum and where to get it,
 * instead of a bare "go: command not found" after the clone. Two lines, so
 * the block stays inside the card preview (code-view.mjs PREVIEW_LIMIT); the
 * version compare is awk arithmetic, the same on Linux and macOS.
 */
export function toolChecks(goMin: string = GO_MIN): string[] {
  const [ma, mi, pa] = goMin.split('.').map(Number)
  const go = q(`Go ${goMin} or newer`)
  return [
    'need() { echo "spool: $1; get $2 from $3, then paste the block again" >&2; exit 1; }',
    `command -v git >/dev/null || need 'git is missing' git git-scm.com; ` +
    `command -v go >/dev/null || need 'go is missing' ${go} go.dev/dl; ` +
    `go env GOVERSION | awk -F'[.a-z]+' '{ exit ($2 * 1000000 + $3 * 1000 + $4 < ${ma * 1000000 + mi * 1000 + (pa || 0)}) }' || need "$(go env GOVERSION) is too old" ${go} go.dev/dl`,
  ]
}

/**
 * The one block to paste in a terminal (bash or zsh; needs git and Go
 * GO_MIN or newer, checked first).
 * keyFile is where the tenant root key sits on that machine; repo is
 * spoolRepo(). No repo: '' (nothing to clone, the guide hides the block).
 */
export function connectAgentScript({ hubUrl, tenant, box, agent, keyFile, repo }: { hubUrl: string, tenant: string, box: string, agent: string, keyFile: string, repo?: string }): string {
  const src = spoolRepo(repo)
  if (!src) return ''
  /* one subshell: set -e stops at the first failing line without closing
     the terminal the block was pasted into */
  return [
    '(',
    'set -e',
    ...toolChecks(),
    'mkdir -p ~/.spool ~/.local/bin',
    `[ -d ~/.spool/src ] || git clone --depth 1 ${q(src)} ~/.spool/src`,
    '(cd ~/.spool/src/csi-spl-api/src/go/spool-hub-api && go build -o ~/.local/bin/spool ./cmd/spool)',
    "cat > ~/.spool/env <<'SPOOL_ENV'",
    spoolEnv({ hubUrl, tenant, box }),
    'SPOOL_ENV',
    '. ~/.spool/env',
    `mkdir -p "$SPOOL_ROOT/${agent}"`,
    `spool hub-pin --box "$SPOOL_BOX_ID" --pubkey "$(spool keygen)" --root-key ${keyFileArg(keyFile)}`,
    'nohup spool hub-run >~/.spool/hub-run.log 2>&1 &',
    `claude mcp add --scope user spool -- bash -c '. ~/.spool/env && exec spool mcp --as ${agent}'`,
    ')',
  ].join('\n')
}

/** Cursor: ~/.cursor/mcp.json (after the block above ran once on that machine). */
export function cursorMcpJson({ agent }: { agent: string }): string {
  return JSON.stringify({
    mcpServers: { spool: { command: 'bash', args: ['-c', `. ~/.spool/env && exec spool mcp --as ${agent}`] } },
  }, null, 2)
}

/** The first thing to tell the agent, so it answers what waits for it. */
export function firstPrompt(agent: string): string {
  return `You are ${agent} on spool. Call spool_recv, answer every message with spool_send (to: its sender, task_id: its task_id, kind: msg), then call spool_recv again.`
}
