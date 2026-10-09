// spec 115 HUB-1: Tenant settings -> Vendor split per task kind, WUI side -
// the body reader, the section 2 rules the table checks before Save (the hub
// checks the same), the mock hub, and the page wiring.
//   CONTROL: agy > 0 or agy the backup in a coding kind is refused by the
//   rule and by the mock hub (drop the agy rule in splitKindRule: red).
// Run: node tests/unit/agent-split-kinds.test.mjs
import { readFileSync } from 'node:fs'
import { DEFAULT_SPLIT_KINDS, normalizeAgentSplitKinds, SPLIT_TASK_KINDS, splitKindRule, splitMainOf } from '../../src/utils/tenant-settings.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }
const w = (o) => ({ claude: 0, grok: 0, agy: 0, qwen: 0, mistral: 0, ...o })

console.log('agent-split-kinds')

// --- the body reader --------------------------------------------------------
const fresh = normalizeAgentSplitKinds({})
ok('an empty body reads the six kinds in order', fresh.map((r) => r.kind).join(',') === SPLIT_TASK_KINDS.join(','))
ok('an empty body is the spec 115 section 2 table, unset',
  fresh.map((r) => `${r.kind}:${r.main}/${r.backup}:${r.set}`).join(' ') ===
  'specs_and_docs:agy/claude:false tests:claude/mistral:false simple_coding:mistral/claude:false complex_coding:claude/mistral:false i18n:agy/claude:false secret:claude/mistral:false')
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
ok('CONTROL: agy 10 in simple_coding is refused', splitKindRule('simple_coding', w({ mistral: 70, claude: 20, agy: 10 }), 'claude') === 'agy')
ok('CONTROL: agy the tests backup is refused', splitKindRule('tests', w({ claude: 70, mistral: 30 }), 'agy') === 'agy')
ok('agy in specs_and_docs is fine', splitKindRule('specs_and_docs', w({ agy: 60, claude: 40 }), 'claude') === '')
ok('secret on grok is refused', splitKindRule('secret', w({ claude: 90, grok: 10 }), 'mistral') === 'secret')
ok('secret with an agy backup is refused', splitKindRule('secret', w({ claude: 100 }), 'agy') === 'secret')

// --- the mock hub -----------------------------------------------------------
{
  const m = createMockTenant()
  const kinds = (b) => Object.fromEntries(b.kinds.map((k) => [k.kind, k]))
  ok('mock: six kinds, all unset', m.splitKinds().kinds.length === 6 && m.splitKinds().kinds.every((k) => !k.set))
  const after = kinds(m.patchSplitKinds({ kinds: { simple_coding: { weights: { mistral: 60, claude: 30, grok: 10 }, backup: 'claude' } } }))
  ok('mock: a PATCH updates the row', after.simple_coding.set && after.simple_coding.weights.mistral === 60 && after.simple_coding.main === 'mistral' && !after.tests.set)
  ok('mock CONTROL: agy in a coding kind is refused', throws(() => m.patchSplitKinds({ kinds: { complex_coding: { weights: { claude: 80, mistral: 10, agy: 10 }, backup: 'mistral' } } }), 'bad_split'))
  ok('mock: a refused PATCH writes none of its kinds', throws(() => m.patchSplitKinds({ kinds: {
    i18n: { weights: { agy: 90, claude: 10 }, backup: 'claude' },
    tests: { weights: { claude: 70, mistral: 29 }, backup: 'mistral' },
  } }), 'bad_split') && !kinds(m.splitKinds()).i18n.set)
  ok('mock: an alias kind is refused', throws(() => m.patchSplitKinds({ kinds: { hard: null } }), 'bad_split'))
  ok('mock: an empty PATCH is refused', throws(() => m.patchSplitKinds({ kinds: {} }), 'bad_split'))
  const back = kinds(m.patchSplitKinds({ kinds: { simple_coding: null } }))
  ok('mock: null resets a kind to the default', !back.simple_coding.set && back.simple_coding.weights.mistral === 80)
}

// --- the page wiring --------------------------------------------------------
const page = readFileSync(new URL('../../src/pages/tenant-settings/split.vue', import.meta.url), 'utf8')
const comp = readFileSync(new URL('../../src/components/AgentSplitKinds.vue', import.meta.url), 'utf8')
ok('the split page mounts the per-kind table', page.includes('<AgentSplitKinds />'))
ok('the table reads and writes /v1/agent-split', comp.includes('api.getAgentSplit()') && comp.includes('api.patchAgentSplit('))
ok('Save is blocked while a changed row breaks a rule', /:disabled="busy \|\| !dirty \|\| !valid"/.test(comp))
const en = JSON.parse(readFileSync(new URL('../../i18n/locales/en.json', import.meta.url), 'utf8')).tenant_settings
for (const k of SPLIT_TASK_KINDS) ok(`en names the kind ${k}`, typeof en['split_kind_' + k] === 'string' && en['split_kind_' + k] !== '')
for (const r of ['tie', 'backup', 'agy', 'secret']) ok(`en names the rule ${r}`, typeof en['split_rule_' + r] === 'string')

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nAll agent-split-kinds checks passed.')
