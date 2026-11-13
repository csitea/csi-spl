// spec 115 HUB-1: Tenant settings -> Vendor split per task kind, WUI side -
// the body reader, the section 2 rules the table checks before Save (the hub
// checks the same), the mock hub, and the page wiring.
//   agy codes (owner msg dc673043, SPL-4826): agy > 0 and agy the backup pass
//   in the coding kinds. CONTROL: agy in orchestration is refused by the rule
//   and by the mock hub (the data rule). Every default row equals cnf
//   env.box.agent_split_by_kind (a WUI copy that drifts reds here).
// Run: node tests/unit/agent-split-kinds.test.mjs
import { readFileSync } from 'node:fs'
import { AGENT_SPLIT_KINDS, DEFAULT_SPLIT_KINDS, normalizeAgentSplitKinds, SPLIT_TASK_KINDS, splitKindRule, splitMainOf } from '../../src/utils/tenant-settings.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }
const w = (o) => ({ claude: 0, grok: 0, agy: 0, qwen: 0, mistral: 0, codex: 0, ...o })

console.log('agent-split-kinds')

// --- the body reader --------------------------------------------------------
const fresh = normalizeAgentSplitKinds({})
ok('an empty body reads the seven kinds in order', fresh.map((r) => r.kind).join(',') === SPLIT_TASK_KINDS.join(','))
ok('an empty body is the spec 115 section 2 table, unset',
  fresh.map((r) => `${r.kind}:${r.main}/${r.backup}:${r.set}`).join(' ') ===
  'specs_and_docs:agy/claude:false tests:claude/agy:false simple_coding:claude/agy:false complex_coding:claude/agy:false i18n:agy/claude:false secret:claude/grok:false orchestration:claude/grok:false')
const body = { kinds: [{ kind: 'simple_coding', weights: { mistral: 60, claude: 30, grok: 10 }, backup: 'claude', main: 'mistral', set: true, updated_by: 'HUM-1' }] }
const read = normalizeAgentSplitKinds(body).find((r) => r.kind === 'simple_coding')
ok('a set kind reads its weights, backup and writer', read.set && read.weights.mistral === 60 && read.weights.grok === 10 && read.weights.agy === 0 && read.backup === 'claude' && read.updatedBy === 'HUM-1')
ok('CONTROL: a broken row in the body reads as the default',
  normalizeAgentSplitKinds({ kinds: [{ kind: 'tests', weights: { claude: 50, agy: 50 }, backup: 'mistral', set: true }] }).find((r) => r.kind === 'tests').weights.claude === 70)

// --- the rules --------------------------------------------------------------
for (const k of SPLIT_TASK_KINDS) {
  ok(`the default ${k} row passes`, splitKindRule(k, DEFAULT_SPLIT_KINDS[k].weights, DEFAULT_SPLIT_KINDS[k].backup) === '')
}
ok('main is the strict highest', splitMainOf(w({ claude: 70, mistral: 30 })) === 'claude' && splitMainOf(w({ claude: 50, mistral: 50 })) === '')
ok('a sum of 99 is refused', splitKindRule('tests', w({ claude: 70, mistral: 29 }), 'mistral') === 'sum')
ok('a fraction is refused', splitKindRule('tests', w({ claude: 70.5, mistral: 29.5 }), 'mistral') === 'sum')
ok('a tie is refused', splitKindRule('complex_coding', w({ claude: 50, mistral: 50 }), 'mistral') === 'tie')
ok('the backup as the main is refused', splitKindRule('tests', w({ claude: 70, mistral: 30 }), 'claude') === 'backup')
ok('agy 10 in simple_coding is fine (agy codes)', splitKindRule('simple_coding', w({ mistral: 70, claude: 20, agy: 10 }), 'claude') === '')
ok('agy the tests backup is fine (agy codes)', splitKindRule('tests', w({ claude: 70, mistral: 30 }), 'agy') === '')
ok('agy the complex_coding main is fine', splitKindRule('complex_coding', w({ agy: 60, claude: 40 }), 'claude') === '')
ok('agy in specs_and_docs is fine', splitKindRule('specs_and_docs', w({ agy: 60, claude: 40 }), 'claude') === '')
ok('secret on grok is fine (the data rule)', splitKindRule('secret', w({ claude: 90, grok: 10 }), 'mistral') === '' && splitKindRule('secret', w({ claude: 100 }), 'grok') === '')
ok('secret on qwen is refused', splitKindRule('secret', w({ claude: 90, qwen: 10 }), 'mistral') === 'secret')
ok('secret with an agy backup is refused', splitKindRule('secret', w({ claude: 100 }), 'agy') === 'secret')
ok('orchestration on grok and mistral is fine', splitKindRule('orchestration', w({ claude: 50, grok: 30, mistral: 20 }), 'grok') === '')
ok('CONTROL: orchestration on agy is refused', splitKindRule('orchestration', w({ claude: 90, agy: 10 }), 'grok') === 'secret')
ok('orchestration with a qwen backup is refused', splitKindRule('orchestration', w({ claude: 100 }), 'qwen') === 'secret')

// --- the defaults are cnf ---------------------------------------------------
{
  const lines = readFileSync(new URL('../../../csi-spl-cnf/csi-spl/all.env.yaml', import.meta.url), 'utf8').split('\n')
  const at = lines.findIndex((l) => /^\s+agent_split_by_kind:\s*$/.test(l))
  const cnf = {}
  for (const l of at < 0 ? [] : lines.slice(at + 1)) {
    if (/^\s*(#.*)?$/.test(l)) continue
    if (l.search(/\S/) <= lines[at].search(/\S/)) break
    const m = l.match(/^\s+([a-z0-9_]+):\s*\{(.*)\}/)
    if (!m) break
    const row = Object.fromEntries(m[2].split(',').map((kv) => kv.split(':').map((x) => x.trim())))
    cnf[m[1]] = AGENT_SPLIT_KINDS.map((v) => `${v}=${Number(row[v] ?? 0)}`).join(' ') + ` backup=${row.backup}`
  }
  for (const k of SPLIT_TASK_KINDS) {
    const d = AGENT_SPLIT_KINDS.map((v) => `${v}=${DEFAULT_SPLIT_KINDS[k].weights[v]}`).join(' ') + ` backup=${DEFAULT_SPLIT_KINDS[k].backup}`
    ok(`the ${k} default is the cnf row`, d === cnf[k], `wui ${d} cnf ${cnf[k]}`)
  }
}

// --- the mock hub -----------------------------------------------------------
{
  const m = createMockTenant()
  const kinds = (b) => Object.fromEntries(b.kinds.map((k) => [k.kind, k]))
  ok('mock: seven kinds, all unset', m.splitKinds().kinds.length === 7 && m.splitKinds().kinds.every((k) => !k.set))
  const after = kinds(m.patchSplitKinds({ kinds: { simple_coding: { weights: { mistral: 60, claude: 30, grok: 10 }, backup: 'claude' } } }))
  ok('mock: a PATCH updates the row', after.simple_coding.set && after.simple_coding.weights.mistral === 60 && after.simple_coding.main === 'mistral' && !after.tests.set)
  ok('mock: agy in a coding kind is stored', kinds(m.patchSplitKinds({ kinds: { complex_coding: { weights: { claude: 80, mistral: 10, agy: 10 }, backup: 'agy' } } })).complex_coding.weights.agy === 10)
  ok('mock CONTROL: agy in orchestration is refused', throws(() => m.patchSplitKinds({ kinds: { orchestration: { weights: { claude: 90, agy: 10 }, backup: 'grok' } } }), 'bad_split'))
  ok('mock: a refused PATCH writes none of its kinds', throws(() => m.patchSplitKinds({ kinds: {
    i18n: { weights: { agy: 90, claude: 10 }, backup: 'claude' },
    tests: { weights: { claude: 70, mistral: 29 }, backup: 'mistral' },
  } }), 'bad_split') && !kinds(m.splitKinds()).i18n.set)
  ok('mock: an alias kind is refused', throws(() => m.patchSplitKinds({ kinds: { hard: null } }), 'bad_split'))
  ok('mock: an empty PATCH is refused', throws(() => m.patchSplitKinds({ kinds: {} }), 'bad_split'))
  const back = kinds(m.patchSplitKinds({ kinds: { simple_coding: null } }))
  ok('mock: null resets a kind to the default', !back.simple_coding.set && back.simple_coding.weights.agy === 41)
}

// --- the page wiring --------------------------------------------------------
const page = readFileSync(new URL('../../src/pages/tenant-settings/split.vue', import.meta.url), 'utf8')
const comp = readFileSync(new URL('../../src/components/AgentSplitKinds.vue', import.meta.url), 'utf8')
ok('the split page mounts the per-kind table', /<AgentSplitKinds\b[^>]*\/>/.test(page))
ok('the table reads and writes /v1/agent-split', comp.includes('api.getAgentSplit()') && comp.includes('api.patchAgentSplit('))
ok('Save is blocked while a changed row breaks a rule', /:disabled="busy \|\| !dirty \|\| !valid"/.test(comp))
const en = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8')).tenant_settings
for (const k of SPLIT_TASK_KINDS) ok(`en names the kind ${k}`, typeof en['split_kind_' + k] === 'string' && en['split_kind_' + k] !== '')
for (const r of ['tie', 'backup', 'secret']) ok(`en names the rule ${r}`, typeof en['split_rule_' + r] === 'string')

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll agent-split-kinds checks passed.')
