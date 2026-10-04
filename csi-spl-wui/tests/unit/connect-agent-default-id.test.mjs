// spec 072 A65: Tenant settings -> Agents opened "Connect an agent" on CLE-01,
// a legacy id the write path rejects after LEGACY_ID_UNTIL - so the guide hid
// its paste block on first open. Its initial id must be one isWritableAgentId
// accepts after the cut-over.
//
// Run: node tests/unit/connect-agent-default-id.test.mjs
import { readFileSync } from 'node:fs'
import { LEGACY_ID_UNTIL, isWritableAgentId } from '../../src/utils/agent-id.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }

console.log('connect-agent-default-id')
const src = readFileSync(new URL('../../src/components/ConnectAgentGuide.vue', import.meta.url), 'utf8')
const m = /const agent = ref\('([^']*)'\)/.exec(src)
const initial = m ? m[1] : ''
const after = Date.parse(LEGACY_ID_UNTIL) + 1000
ok('the guide declares its initial agent id', Boolean(initial), 'no `const agent = ref(...)` in ConnectAgentGuide.vue')
ok('the initial id is writable after LEGACY_ID_UNTIL', isWritableAgentId(initial, after), initial)
ok('CONTROL CLE-01 is rejected after LEGACY_ID_UNTIL', !isWritableAgentId('CLE-01', after))
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`connect-agent-default-id: ${failed} FAILED`)
  process.exit(1)
}
console.log('connect-agent-default-id: all passed')
