// spec 184 row W1 (SPL-6725): Tenant settings -> Vendor split -> Default
// model per vendor and task kind, WUI side - the syntax check that blocks
// Save, the settings and readings readers, the PATCH body, the mock hub
// and the page wiring.
//   CONTROL (the row's red control): a model with a space is refused by the
//   check, by the PATCH body (it throws, nothing is sent) and by the mock
//   hub. Plant it by letting AGENT_MODEL_RX take a space: cases 3, 6, 9b, 12,
//   13 and 13d go red (6 failures, seen 2026-11-28).
// Run: node tests/unit/agent-models.test.mjs
import { readFileSync } from 'node:fs'
import {
  AGENT_MODEL_KINDS, AGENT_SPLIT_KINDS, SPLIT_TASK_KINDS, agentModelReadingsOf, agentModelsOf, agentModelsPatchOf,
  agentModelValid, normalizeTenantSettings, tenantSettingsErrorKey,
} from '../../src/utils/tenant-settings.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const token = (fn) => { try { fn(); return '' } catch (e) { return e.token || 'no-token' } }
const empty = () => Object.fromEntries(AGENT_SPLIT_KINDS.map((v) => [v, {}]))

console.log('agent-models')

// --- the syntax (spec 184 7.1.2) ---------------------------------------------
ok('1 the kinds are every kind (*) then the seven split kinds', AGENT_MODEL_KINDS.join() === ['*', ...SPLIT_TASK_KINDS].join())
ok('2 empty (the CLI default) and real names pass', ['', 'sonnet', 'claude-opus-5-5', 'grok-4.7', 'mistral-vibe-cli-latest', 'org/model:tag', ' opus '].every(agentModelValid))
ok('3 CONTROL: a model with a space is refused', !agentModelValid('a b') && !agentModelValid('Gemini 3.8 Flash (High)'))
ok('4 a quote, a semicolon and 81 characters are refused', !agentModelValid("so'net") && !agentModelValid('a;b') && !agentModelValid('x'.repeat(81)) && agentModelValid('x'.repeat(80)))

// --- the settings reader -------------------------------------------------------
{
  const m = agentModelsOf([
    { vendor: 'claude', kind: '*', model: 'sonnet' },
    { vendor: 'claude', kind: 'complex_coding', model: 'opus' },
    { vendor: 'grok', kind: 'tests', model: 'grok-4.6' },
    { vendor: 'nobody', kind: '*', model: 'x' },
    { vendor: 'grok', kind: 'hard', model: 'x' },
    { vendor: 'qwen', kind: '*', model: 'a b' },
  ])
  ok('5 agent_models reads per vendor and kind', m.claude['*'] === 'sonnet' && m.claude.complex_coding === 'opus' && m.grok.tests === 'grok-4.6', JSON.stringify(m))
  ok('6 an unknown vendor, an alias kind and a bad model are dropped', !m.nobody && !m.grok.hard && Object.keys(m.qwen).length === 0, JSON.stringify(m))
  const s = normalizeTenantSettings({ agent_models: [{ vendor: 'codex', kind: '*', model: 'gpt-6-luna' }] })
  ok('7 the settings body carries agentModels; absent is every vendor empty', s.agentModels.codex['*'] === 'gpt-6-luna' &&
    Object.keys(normalizeTenantSettings({}).agentModels).join() === AGENT_SPLIT_KINDS.join())
}

// --- the PATCH body ----------------------------------------------------------
{
  const stored = { ...empty(), claude: { '*': 'sonnet' } }
  ok('8 nothing changed is no PATCH', agentModelsPatchOf(stored, { ...empty(), claude: { '*': ' sonnet ', tests: '' } }) === null)
  const edited = { ...empty(), claude: { '*': '' }, grok: { tests: 'grok-4.6' } }
  const p = agentModelsPatchOf(stored, edited)
  ok('9 a set cell is sent, a cleared one is sent as "" (it reads as the cnf)', p && p.claude['*'] === '' && p.grok.tests === 'grok-4.6' && Object.keys(p).join() === 'claude,grok', JSON.stringify(p))
  ok('9b CONTROL: a model with a space throws bad_model, nothing is sent', token(() => agentModelsPatchOf(stored, { ...empty(), qwen: { '*': 'a b' } })) === 'bad_model')
  ok('10 bad_model has its own error words', tenantSettingsErrorKey({ token: 'bad_model' }) === 'tenant_settings.error.bad_model')
}

// --- the readings (N1: a display only) -----------------------------------------
{
  const r = agentModelReadingsOf({ readings: [
    { box: 'box-a', vendor: 'grok', cli_version: '1.0.89', models: ['grok-4.7', 'grok-4.5'], read_at: '2026-11-27T17:31:00Z' },
    { box: 'box-b', vendor: 'grok', cli_version: '1.0.92', models: ['grok-4.7', 'grok-4.6', 'grok-4.6', 'bad model'], read_at: '2026-11-27T18:02:00Z' },
    { box: 'box-c', vendor: 'grok', cli_version: '1.0.80', models: ['old'], read_at: '2026-11-01T00:00:00Z' },
    { box: 'box-a', vendor: 'nobody', models: ['x'], read_at: '2026-11-27T18:02:00Z' },
  ] })
  ok('11 per vendor the newest reading of any box, its time and CLI version', r.grok.box === 'box-b' && r.grok.cliVersion === '1.0.92' && r.grok.readAt === '2026-11-27T18:02:00Z', JSON.stringify(r))
  ok('12 its models deduped, a bad one dropped; an unknown vendor dropped', r.grok.models.join() === 'grok-4.7,grok-4.6' && !r.nobody && Object.keys(agentModelReadingsOf(null)).length === 0, JSON.stringify(r))
}

// --- the mock hub ------------------------------------------------------------
{
  const m = createMockTenant()
  ok('13a mock: no cell set at first', Array.isArray(m.settings().agent_models) && m.settings().agent_models.length === 0)
  const after = m.patch({ agent_models: { grok: { tests: 'grok-4.6' }, claude: { complex_coding: 'opus', '*': 'sonnet' } } }).agent_models
  ok('13b mock: a PATCH sets the cells, sorted by vendor then kind (* first)', after.map((c) => `${c.vendor}/${c.kind}=${c.model}`).join() === 'claude/*=sonnet,claude/complex_coding=opus,grok/tests=grok-4.6', JSON.stringify(after))
  ok('13 CONTROL: mock: a model with a space is 400 bad_model and nothing of the PATCH is written',
    token(() => m.patch({ agent_models: { codex: { '*': 'gpt-6-luna' }, qwen: { '*': 'a b' } } })) === 'bad_model' && !m.settings().agent_models.some((c) => c.vendor === 'codex'))
  ok('13c mock: an unknown vendor or an alias kind is bad_model', token(() => m.patch({ agent_models: { nobody: { '*': 'x' } } })) === 'bad_model' && token(() => m.patch({ agent_models: { claude: { hard: 'x' } } })) === 'bad_model')
  const dropped = m.patch({ agent_models: { claude: { '*': '', complex_coding: null } } }).agent_models
  ok('13d mock: "" and null drop a cell', dropped.map((c) => c.vendor + '/' + c.kind).join() === 'grok/tests', JSON.stringify(dropped))
  const rd = agentModelReadingsOf(m.modelReadings())
  ok('13e mock: the readings name claude and grok, grok from its newer box', rd.claude?.models.includes('sonnet') && rd.grok?.box === 'box-b' && !rd.codex, JSON.stringify(rd))
}

// --- the page wiring -----------------------------------------------------------
{
  const page = readFileSync(new URL('../../src/pages/tenant-settings/split.vue', import.meta.url), 'utf8')
  const comp = readFileSync(new URL('../../src/components/AgentModels.vue', import.meta.url), 'utf8')
  const client = readFileSync(new URL('../../src/utils/spool-client.mjs', import.meta.url), 'utf8')
  const lazy = readFileSync(new URL('../../src/utils/spool-client-lazy.mjs', import.meta.url), 'utf8')
  ok('14 the split page mounts the model table', /<AgentModels\b[^>]*\/>/.test(page))
  ok('15 the table reads the readings and writes agent_models', comp.includes('api.getAgentModelReadings()') && comp.includes('api.patchTenantSettings({ agent_models: patch })'))
  ok('16 Save is blocked while a cell breaks the syntax', /:disabled="busy \|\| !dirty \|\| !valid"/.test(comp) && comp.includes('agentModelValid(edited[v][k])'))
  ok('17 each cell offers its vendor\'s reading as choices', comp.includes(':list="\'agent-models-\' + v"') && comp.includes('<datalist'))
  ok('18 the client routes GET /v1/tenant/agent-model-readings', client.includes("'getAgentModelReadings'") && lazy.includes("live('/v1/tenant/agent-model-readings')") && /\n {2}getAgentModelReadings,\n/.test(lazy))
}

// --- the words in every locale -------------------------------------------------
{
  const keys = ['models_title', 'models_hint', 'models_kind_all', 'models_cli_default', 'models_reading', 'models_no_reading']
  for (const loc of ['en', 'bg', 'el', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
    const ts = JSON.parse(readFileSync(new URL(`../../i18n/locales/${loc}.json`, import.meta.url), 'utf8')).tenant_settings
    const miss = keys.filter((k) => typeof ts[k] !== 'string' || !ts[k])
    if (typeof ts.error?.bad_model !== 'string') miss.push('error.bad_model')
    const ph = ['{vendor}', '{at}', '{box}', '{cli}'].filter((x) => !String(ts.models_reading).includes(x))
    ok(`19 ${loc} has the model words and the reading's placeholders`, miss.length === 0 && ph.length === 0 && String(ts.models_no_reading).includes('{vendor}'), [...miss, ...ph].join())
  }
}

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll agent-models checks passed.')
