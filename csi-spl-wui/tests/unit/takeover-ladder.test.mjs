// SPL-2115: Tenant settings -> Agent takeover, WUI side - the defaults (the
// hub's), the rules the section checks before Save (the hub checks the
// same), the reorder step, the body reader, the mock hub that keeps a set
// kind across a reload, and the page wiring.
//   CONTROL: agy or qwen in the secret order is refused by the rule and by
//   the mock hub (drop the secret line in takeoverRule: red).
// Run: node tests/unit/takeover-ladder.test.mjs
import { readFileSync } from 'node:fs'
import {
  createMockTakeover, DEFAULT_TAKEOVER, normalizeTakeoverLadder, TAKEOVER_KINDS, takeoverAddable,
  takeoverErrorKey, takeoverMove, takeoverRule,
} from '../../src/utils/takeover-ladder.mjs'

let failed = 0
const ok = (name, cond, why = '') => { if (cond) console.log(`  OK   ${name}`); else { failed++; console.log(`  FAIL ${name} ${why}`) } }
const throws = (fn, token) => { try { fn(); return false } catch (e) { return e.token === token } }

console.log('takeover-ladder')

// --- the defaults are the hub's (store/takeover_ladder.go) -----------------
const goSrc = readFileSync(new URL('../../../csi-spl-api/src/go/spool-hub-api/internal/store/takeover_ladder.go', import.meta.url), 'utf8')
ok('the kinds are the hub\'s, in order', goSrc.includes('[]string{"' + TAKEOVER_KINDS.join('", "') + '"}'))
ok('coding: mistral, agy, claude, 2', goSrc.includes('Order: []string{"mistral", "agy", "claude"}, MaxFailures: 2') &&
  ['tests', 'simple_coding', 'complex_coding'].every((k) => DEFAULT_TAKEOVER[k].order.join() === 'mistral,agy,claude' && DEFAULT_TAKEOVER[k].maxFailures === 2))
ok('docs and i18n: agy, claude, 1', ['specs_and_docs', 'i18n'].every((k) => DEFAULT_TAKEOVER[k].order.join() === 'agy,claude' && DEFAULT_TAKEOVER[k].maxFailures === 1) &&
  goSrc.includes('{Kind: "i18n", Order: []string{"agy", "claude"}, MaxFailures: 1}'))
ok('secret: claude, mistral, 2', DEFAULT_TAKEOVER.secret.order.join() === 'claude,mistral' && DEFAULT_TAKEOVER.secret.maxFailures === 2 &&
  goSrc.includes('{Kind: "secret", Order: []string{"claude", "mistral"}, MaxFailures: 2}'))
ok('every default passes its own rule', TAKEOVER_KINDS.every((k) => takeoverRule(k, DEFAULT_TAKEOVER[k].order, DEFAULT_TAKEOVER[k].maxFailures) === ''))

// --- the rules -------------------------------------------------------------
ok('CONTROL: agy in secret', takeoverRule('secret', ['claude', 'agy'], 2) === 'secret')
ok('CONTROL: qwen in secret', takeoverRule('secret', ['qwen'], 2) === 'secret')
ok('agy in tests is fine (takeover, not the split)', takeoverRule('tests', ['agy', 'claude'], 2) === '')
ok('empty order', takeoverRule('tests', [], 2) === 'empty')
ok('unknown vendor', takeoverRule('tests', ['opus'], 2) === 'vendor')
ok('a vendor twice', takeoverRule('tests', ['claude', 'claude'], 2) === 'vendor')
ok('0 failures', takeoverRule('tests', ['claude'], 0) === 'failures')
ok('11 failures', takeoverRule('tests', ['claude'], 11) === 'failures')
ok('1.5 failures', takeoverRule('tests', ['claude'], 1.5) === 'failures')
ok('secret never offers agy or qwen to add', takeoverAddable('secret', ['claude']).join() === 'grok,mistral')
ok('tests offers the vendors not in the order', takeoverAddable('tests', ['mistral', 'agy', 'claude']).join() === 'grok,qwen')

// --- the reorder step ------------------------------------------------------
ok('up', takeoverMove(['a', 'b', 'c'], 2, -1).join() === 'a,c,b')
ok('down', takeoverMove(['a', 'b', 'c'], 0, 1).join() === 'b,a,c')
ok('the top does not move up', takeoverMove(['a', 'b'], 0, -1).join() === 'a,b')

// --- the body reader -------------------------------------------------------
const fresh = normalizeTakeoverLadder({})
ok('an empty body reads the six kinds, defaults, unset', fresh.map((r) => r.kind).join() === TAKEOVER_KINDS.join() && fresh.every((r) => !r.set))
const read = normalizeTakeoverLadder({ kinds: [
  { kind: 'tests', order: ['claude', 'grok'], max_failures: 3, set: true },
  { kind: 'secret', order: ['agy'], max_failures: 2, set: true },
  { kind: 'nope', order: ['claude'], max_failures: 1 },
] })
ok('a good kind reads as set', read[1].order.join() === 'claude,grok' && read[1].maxFailures === 3 && read[1].set)
ok('a broken kind reads as its default', read[5].order.join() === 'claude,mistral' && !read[5].set)
ok('error keys', takeoverErrorKey({ token: 'bad_ladder' }) === 'takeover.error_bad_ladder' && takeoverErrorKey(new Error('x')) === 'takeover.error_generic')

// --- the mock hub keeps a set kind across a reload --------------------------
const mem = new Map()
const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, String(v)) }
const m1 = createMockTakeover(storage)
m1.put({ simple_coding: { order: ['claude', 'mistral'], max_failures: 4 } })
const again = normalizeTakeoverLadder(createMockTakeover(storage).get())
ok('a new mock (a reload) reads the saved kind', again[2].order.join() === 'claude,mistral' && again[2].maxFailures === 4 && again[2].set)
ok('CONTROL: the mock refuses agy in secret', throws(() => m1.put({ secret: { order: ['claude', 'agy'], max_failures: 2 } }), 'bad_ladder'))
ok('a refused PUT writes nothing, its good kind included', throws(() => m1.put({ i18n: { order: ['claude'], max_failures: 1 }, secret: { order: ['qwen'], max_failures: 1 } }), 'bad_ladder') &&
  normalizeTakeoverLadder(m1.get())[4].order.join() === 'agy,claude')
m1.put({ simple_coding: null })
ok('null resets the kind', !normalizeTakeoverLadder(m1.get())[2].set)

// --- the page wiring -------------------------------------------------------
const page = readFileSync(new URL('../../src/pages/tenant-settings/takeover.vue', import.meta.url), 'utf8')
const nav = readFileSync(new URL('../../src/utils/tenant-settings-nav.mjs', import.meta.url), 'utf8')
ok('the page reads and writes through the client', page.includes('api.getTakeoverLadder()') && page.includes('api.putTakeoverLadder('))
ok('the nav lists the section for tenant.settings', nav.includes("{ id: 'takeover', label: 'tenant_settings.takeover', perm: 'tenant.settings' }"))

if (failed) {
  console.log(`takeover-ladder: ${failed} FAILED`)
  process.exit(1)
}
console.log('takeover-ladder: all passed')
