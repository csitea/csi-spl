// W12 (spec 047, SPL-1166): the "Connect an agent" lines (utils/connect-agent.mjs)
// - the block is valid bash, names this tenant's hub, box and agent, never
// closes the terminal it is pasted into (one subshell), and the MCP lines
// seat the server as the one agent.
//
// Run: node tests/unit/connect-agent.test.mjs
import { spawnSync } from 'node:child_process'
import {
  spoolRepo, boxHubUrl, connectAgentScript, cursorMcpJson, firstPrompt, keyFileArg, validAgentId, validBoxId,
} from '../../src/utils/connect-agent.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'
import { setAgentIdNow } from '../../src/utils/agent-id.mjs'

/* spec 061 FR-004: these ids are legacy (CLE-01); pin the clock before
   LEGACY_ID_UNTIL so this file does not turn red at the deadline on its own */
setAgentIdNow('2026-10-02T12:00:00Z')

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const bashN = (src) => spawnSync('bash', ['-n'], { input: src, encoding: 'utf8' })

console.log('connect-agent')
const o = { hubUrl: 'https://api.example.com', tenant: 't1', box: 'box-laptop', agent: 'CLE-01', keyFile: '~/Downloads/t1.root.key', repo: 'https://git.example.org/acme/spool' }
const s = connectAgentScript(o)
const lines = s.split('\n')
ok('the block is valid bash', bashN(s).status === 0, bashN(s).stderr)
ok('CONTROL a broken block is caught by bash -n', bashN(s.replace(/\)$/, '')).status !== 0)
ok('one subshell: set -e cannot close the terminal', lines[0] === '(' && lines.at(-1) === ')' && lines[1] === 'set -e')
ok('it names the hub, the tenant and the box', s.includes("SPOOL_HUB_URL='https://api.example.com'") && s.includes("SPOOL_TENANT='t1'") && s.includes("SPOOL_BOX_ID='box-laptop'"))
ok('it builds spool from the configured repo', s.includes("git clone --depth 1 'https://git.example.org/acme/spool' ~/.spool/src") && s.includes('go build -o ~/.local/bin/spool ./cmd/spool'))
ok('no repo configured: no block at all (no fallback repo)', connectAgentScript({ ...o, repo: '' }) === '' && connectAgentScript({ ...o, repo: undefined }) === '')
ok('a repo that is not an http(s) url is no repo', spoolRepo('ftp://x/y') === '' && spoolRepo('https://x/$(id)') === '' && spoolRepo('https://x/y/') === 'https://x/y')
ok('it seats the box with the root key file', s.includes('spool hub-pin --box "$SPOOL_BOX_ID" --pubkey "$(spool keygen)" --root-key "$HOME/Downloads/t1.root.key"'))
ok('it announces the agent (its spool dir)', s.includes('mkdir -p "$SPOOL_ROOT/CLE-01"'))
ok('it keeps the box connected', s.includes('nohup spool hub-run'))
ok('Claude Code gets the spool MCP seated as the agent', s.includes("claude mcp add spool -- bash -c '. ~/.spool/env && exec spool mcp --as CLE-01'"))
ok('no secret in the block: the key stays a file path', !/[A-Za-z0-9+/]{80,}={0,2}/.test(s))
const c = JSON.parse(cursorMcpJson({ agent: 'CLE-02' }))
ok('Cursor mcp.json seats the same server', c.mcpServers.spool.command === 'bash' && c.mcpServers.spool.args[1] === '. ~/.spool/env && exec spool mcp --as CLE-02')
ok('the first prompt names the agent and the tools', /CLE-01/.test(firstPrompt('CLE-01')) && /spool_recv/.test(firstPrompt('CLE-01')) && /spool_send/.test(firstPrompt('CLE-01')))
ok('ids follow the hub rules', validAgentId('c-004') && !validAgentId('C-004') && validAgentId('CLE-01') && validAgentId('GRK-3') && !validAgentId('cle-01') && !validAgentId('HUM-4') && !validAgentId('BOX-1') &&
  validBoxId('box-laptop') && !validBoxId('Box') && !validBoxId('-x') && !validBoxId('a'.repeat(33)))
ok('a ~/ key path stays expandable, others are one quoted word', keyFileArg('~/k.key') === '"$HOME/k.key"' && keyFileArg("/a b/c'd") === "'/a b/c'\\''d'")
ok('hub url: the api base, {tenant} filled, else this origin', boxHubUrl('https://api.example.com/', 'https://w.example.com') === 'https://api.example.com' &&
  boxHubUrl('http://{tenant}.localhost:58080', 'x', 't1') === 'http://t1.localhost:58080' && boxHubUrl('', 'https://chat.example.org') === 'https://chat.example.org')
/* the quoted values survive a hostile-looking tenant or hub (they are validated upstream too) */
ok('values are quoted shell words', bashN(connectAgentScript({ ...o, hubUrl: "https://x'; rm -rf ~; '" })).status === 0 &&
  connectAgentScript({ ...o, hubUrl: "https://x'; rm -rf ~; '" }).includes("'https://x'\\''; rm -rf ~; '\\'''"))
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`connect-agent: ${failed} FAILED`)
  process.exit(1)
}
console.log('connect-agent: all passed')
