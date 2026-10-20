// Spec 147 R5 (SPL-2676): per-workspace agent caps in the WUI. The spool-hub
// admin edits them in the operator console; a workspace admin only reads
// them in Settings -> Agents. RED before R5: a workspace admin's page had no
// read-only caps table and nothing kept inputs off it.
// Run: node tests/unit/agent-caps.test.mjs
import { readFileSync } from 'node:fs'
import {
  AGENT_CAP_VENDORS,
  AGENT_CAPS_MOCK_KEY,
  AGENT_CAPS_MOCK_LIVE_KEY,
  AGENT_CAPS_MOCK_TENANT,
  agentCapRows,
  agentCapStatus,
  agentCapsDraft,
  agentCapsPutBody,
  mockOperatorAgentCaps,
  mockOperatorPutAgentCaps,
  mockTenantAgentCaps,
  normalizeAgentCaps,
} from '../../src/utils/agent-caps.mjs'
import { OPERATOR_MOCK_KEY } from '../../src/utils/operator-console.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const raises = (fn, status, token, perm) => { try { fn(); return false } catch (e) { return e.status === status && e.token === token && (!perm || e.permission === perm) } }
const memStore = (seed = {}) => {
  const m = new Map(Object.entries(seed))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)) }
}

console.log('agent-caps')
ok('five vendors, in form order', AGENT_CAP_VENDORS.join(',') === 'claude,grok,agy,mistral,qwen')

/* the spec 147 section 6.2 example: example-ws, claude 1 of 1 live */
const body = {
  workspace_id: 'example-ws',
  caps: { claude: 1, grok: 1, agy: 2, mistral: 1, qwen: null },
  live: { claude: 1, grok: 0, agy: 1, mistral: 0, qwen: 3 },
  can_edit: false,
}
const view = normalizeAgentCaps(body)
ok('the tenant body reads caps and live', view.workspaceId === 'example-ws' && view.caps.agy === 2 && view.caps.qwen === null && view.live.qwen === 3)
const rows = agentCapRows(view)
ok('statuses: at limit, available, unlimited',
  rows.map((r) => r.status).join(',') === 'at_limit,available,available,available,unlimited', rows.map((r) => r.status).join(','))
ok('a cap of 0 blocks: at limit with none live', agentCapStatus(0, 0) === 'at_limit')
ok('no cap is unlimited', agentCapStatus(null, 99) === 'unlimited')

/* the red control: a workspace admin never gets an editable row */
ok('workspace settings rows are read-only', rows.every((r) => r.editable === false))
const claims = agentCapRows(normalizeAgentCaps({ ...body, can_edit: true }))
ok('CONTROL a body that claims can_edit still renders read-only rows', claims.every((r) => r.editable === false))
const page = readFileSync(new URL('../../src/pages/tenant-settings/agents.vue', import.meta.url), 'utf8')
const section = (page.match(/<SettingsSection[^>]*id="tenant-agent-caps"[\s\S]*?<\/SettingsSection>/) || [''])[0]
ok('the agents page has the read-only caps table', section.includes('data-test="tenant-agent-caps-table"') && /agentCapRows\(/.test(page))
ok('…with no input, select or textarea in it', section !== '' && !/<(input|select|textarea)\b/.test(section))
ok('…and it says who sets the limits', section.includes("t('tenant_settings.caps_note')"))
const pane = readFileSync(new URL('../../src/components/OperatorPane.vue', import.meta.url), 'utf8')
ok('the operator console has one number input per vendor', /v-for="v in AGENT_CAP_VENDORS"[\s\S]{0,400}type="number"/.test(pane) && pane.includes('data-test="operator-caps-input"'))

/* the PUT body */
const draft = agentCapsDraft(view)
ok('the draft: a number per cap, empty = unlimited', draft.claude === '1' && draft.qwen === '')
ok('the body names every vendor, empty -> null', JSON.stringify(agentCapsPutBody(draft).body) === '{"caps":{"claude":1,"grok":1,"agy":2,"mistral":1,"qwen":null}}')
ok('0 is a cap (blocks the vendor)', agentCapsPutBody({ ...draft, grok: '0' }).body?.caps.grok === 0)
ok('a negative cap is refused', agentCapsPutBody({ ...draft, grok: '-1' }).error === 'operator.caps_error')
ok('a fraction or a word is refused', agentCapsPutBody({ ...draft, agy: '1.5' }).error === 'operator.caps_error' && agentCapsPutBody({ ...draft, agy: 'two' }).error === 'operator.caps_error')

/* the mock hub */
const ws = memStore()
ok('mock: a workspace admin PUT is 403 operator.workspaces',
  raises(() => mockOperatorPutAgentCaps(AGENT_CAPS_MOCK_TENANT, { caps: { claude: 1 } }, ws), 403, 'forbidden', 'operator.workspaces'))
ok('mock: …and so is the GET', raises(() => mockOperatorAgentCaps(AGENT_CAPS_MOCK_TENANT, ws), 403, 'forbidden', 'operator.workspaces'))
const op = memStore({ [OPERATOR_MOCK_KEY]: '1' })
ok('mock: an unknown workspace is 404', raises(() => mockOperatorAgentCaps('Not A Slug', op), 404, 'not_found'))
mockOperatorPutAgentCaps(AGENT_CAPS_MOCK_TENANT, { caps: { claude: 1, grok: 1, agy: 2, mistral: 1, qwen: null } }, op)
ok('mock: the operator GET reads what the PUT set', JSON.stringify(mockOperatorAgentCaps(AGENT_CAPS_MOCK_TENANT, op).caps) === '{"claude":1,"grok":1,"agy":2,"mistral":1}')
const tv = normalizeAgentCaps(mockTenantAgentCaps(op))
ok('mock: the tenant view shows them, qwen unlimited, can_edit false', tv.caps.agy === 2 && tv.caps.qwen === null && tv.canEdit === false)
mockOperatorPutAgentCaps(AGENT_CAPS_MOCK_TENANT, { caps: { claude: null } }, op)
ok('mock: null removes a cap', normalizeAgentCaps(mockTenantAgentCaps(op)).caps.claude === null)
ok('mock: the PUT is kept under its store key', JSON.parse(op.getItem(AGENT_CAPS_MOCK_KEY))[AGENT_CAPS_MOCK_TENANT].agy === 2)
op.setItem(AGENT_CAPS_MOCK_LIVE_KEY, JSON.stringify({ [AGENT_CAPS_MOCK_TENANT]: { agy: 2, qwen: 4 } }))
const lv = agentCapRows(normalizeAgentCaps(mockTenantAgentCaps(op)))
ok('mock: live counts from the e2e key; agy 2 of 2 is at limit, qwen stays unlimited',
  lv.find((r) => r.vendor === 'agy').status === 'at_limit' && lv.find((r) => r.vendor === 'qwen').live === 4 && lv.find((r) => r.vendor === 'qwen').status === 'unlimited')
ok('mock: a bad vendor is 400 bad_vendor', raises(() => mockOperatorPutAgentCaps(AGENT_CAPS_MOCK_TENANT, { caps: { deepseek: 1 } }, op), 400, 'bad_vendor'))
ok('mock: a bad cap is 400 bad_cap', raises(() => mockOperatorPutAgentCaps(AGENT_CAPS_MOCK_TENANT, { caps: { grok: -1 } }, op), 400, 'bad_cap'))

/* the client: one lazy method, named in the stub list */
const lazy = readFileSync(new URL('../../src/utils/spool-client-lazy.mjs', import.meta.url), 'utf8')
const client = readFileSync(new URL('../../src/utils/spool-client.mjs', import.meta.url), 'utf8')
ok('the lazy half has agentCaps on the three routes', /async function agentCaps\(/.test(lazy) &&
  lazy.includes("'/v1/tenant/agent-caps'") && lazy.includes("'/agent-caps'"))
ok('…and the client names it a lazy method', /'agentCaps',/.test(client))

const s = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', s.ok, s.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll agent-caps checks passed.')
