// W15 (spec 047, SPL-1172): the first-run checklist rules (utils/first-run.mjs).
//
// Run: node tests/unit/first-run.test.mjs
import { FIRST_RUN_STEPS, firstRunHiddenKey, firstRunSteps, firstRunVisible } from '../../src/utils/first-run.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const state = (steps) => steps.map((s) => `${s.id}:${s.done ? 1 : 0}`).join(' ')

console.log('first-run')
ok('three steps: invite, agent, first topic', FIRST_RUN_STEPS.map((s) => s.id).join() === 'invite,agent,topic')
const fresh = firstRunSteps({ members: 1, invites: 0, roster: { 'box-wui': ['HUM-1'] }, topics: 0 })
ok('a fresh tenant: all three open (the browser box is not an agent)', state(fresh) === 'invite:0 agent:0 topic:0', state(fresh))
ok('an open invite counts', firstRunSteps({ members: 1, invites: 1 })[0].done)
ok('a second member counts', firstRunSteps({ members: 2, invites: 0 })[0].done)
ok('an agent on a box counts', firstRunSteps({ roster: { 'box-laptop': ['CLE-01'] } })[1].done)
ok('a first topic counts', firstRunSteps({ topics: 1 })[2].done)
ok('unknown counts leave a step open', state(firstRunSteps({})) === 'invite:0 agent:0 topic:0')
ok('shown to an admin with a step open', firstRunVisible({ canSetUp: true, hidden: false, steps: fresh }))
ok('CONTROL not shown to a member who cannot set the tenant up', !firstRunVisible({ canSetUp: false, hidden: false, steps: fresh }))
ok('not shown once hidden', !firstRunVisible({ canSetUp: true, hidden: true, steps: fresh }))
ok('not shown once all three are done', !firstRunVisible({ canSetUp: true, hidden: false,
  steps: firstRunSteps({ members: 2, roster: { 'box-a': ['CLE-01'] }, topics: 3 }) }))
ok('the hide key is per tenant', firstRunHiddenKey('t1') !== firstRunHiddenKey('t2'))
const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs this suite', suite.ok, suite.why)

if (failed) {
  console.log(`first-run: ${failed} FAILED`)
  process.exit(1)
}
console.log('first-run: all passed')
