/**
 * Workspace settings -> Agent takeover (SPL-2115): per task kind, the vendor
 * order that takes over a failed task on the same branch, and the failures
 * each vendor is allowed. GET / PUT /v1/takeover-ladder; the hub keeps the
 * rules (store/takeover_ladder.go) and this file says the same, so a row the
 * hub would refuse blocks Save first. Rides with the lazy page only; node
 * tests import it.
 */

/** The vendors, in the hub's order (store.AgentKinds). */
export const TAKEOVER_VENDORS = Object.freeze(['claude', 'grok', 'agy', 'qwen', 'mistral'])

/** The task kinds, in the order the section lists them. */
export const TAKEOVER_KINDS = Object.freeze(['specs_and_docs', 'tests', 'simple_coding', 'complex_coding', 'i18n', 'secret'])

/** The bounds of max_failures. */
export const TAKEOVER_MAX_FAILURES_MIN = 1
export const TAKEOVER_MAX_FAILURES_MAX = 10

/** The secret kind never goes to these (the data rule). */
const SECRET_BANNED = Object.freeze(['agy', 'qwen'])

const CODING = Object.freeze({ order: ['mistral', 'agy', 'claude'], maxFailures: 2 })

/** The owner's defaults (t1 35beee77 msgs d83369df, 97b09186), as the hub's. */
export const DEFAULT_TAKEOVER = Object.freeze({
  specs_and_docs: { order: ['agy', 'claude'], maxFailures: 1 },
  tests: CODING,
  simple_coding: CODING,
  complex_coding: CODING,
  i18n: { order: ['agy', 'claude'], maxFailures: 1 },
  secret: { order: ['claude', 'mistral'], maxFailures: 2 },
})

/**
 * The first rule a row breaks, as an i18n key suffix (takeover.rule_<x>), or
 * '' when the hub would take it: at least one vendor ('empty'), known and
 * distinct vendors ('vendor'), no agy or qwen in secret ('secret'), a whole
 * max_failures in range ('failures').
 */
export function takeoverRule(kind, order, maxFailures) {
  if (!Array.isArray(order) || order.length === 0) return 'empty'
  if (order.some((v, i) => !TAKEOVER_VENDORS.includes(v) || order.indexOf(v) !== i)) return 'vendor'
  if (kind === 'secret' && order.some((v) => SECRET_BANNED.includes(v))) return 'secret'
  if (!Number.isInteger(maxFailures) || maxFailures < TAKEOVER_MAX_FAILURES_MIN || maxFailures > TAKEOVER_MAX_FAILURES_MAX) return 'failures'
  return ''
}

/** The vendors a kind may add: not in its order yet, and allowed for it. */
export function takeoverAddable(kind, order) {
  return TAKEOVER_VENDORS.filter((v) => !order.includes(v) && !(kind === 'secret' && SECRET_BANNED.includes(v)))
}

/** The order with the vendor at i moved by delta (-1 up, +1 down); the same list at an end. */
export function takeoverMove(order, i, delta) {
  const j = i + delta
  if (i < 0 || i >= order.length || j < 0 || j >= order.length) return order.slice()
  const out = order.slice()
  ;[out[i], out[j]] = [out[j], out[i]]
  return out
}

/**
 * A GET/PUT /v1/takeover-ladder body -> one row per kind of TAKEOVER_KINDS,
 * in order: {kind, order, maxFailures, set}. A kind absent or broken in the
 * body reads as its default, unset.
 */
export function normalizeTakeoverLadder(body) {
  const b = body && typeof body === 'object' ? body : {}
  const got = {}
  for (const k of Array.isArray(b.kinds) ? b.kinds : []) {
    if (k && typeof k === 'object' && TAKEOVER_KINDS.includes(k.kind)) got[k.kind] = k
  }
  return TAKEOVER_KINDS.map((kind) => {
    const src = got[kind]
    const order = src && Array.isArray(src.order) ? src.order.filter((v) => typeof v === 'string') : []
    if (!src || takeoverRule(kind, order, src.max_failures)) {
      const d = DEFAULT_TAKEOVER[kind]
      return { kind, order: d.order.slice(), maxFailures: d.maxFailures, set: false }
    }
    return { kind, order, maxFailures: src.max_failures, set: src.set === true }
  })
}

/**
 * The hub's error token -> forbidden | bad_ladder | generic. A code, not an
 * i18n key: this file is reachable from the first screen (the lazy client's
 * mock imports it), so a key literal here would ride in the core catalogue.
 */
export function takeoverErrorCode(err) {
  const token = err && typeof err.token === 'string' ? err.token : ''
  return ['forbidden', 'bad_ladder'].includes(token) ? token : 'generic'
}

/**
 * The mock hub's ladder (NUXT_PUBLIC_USE_MOCK=1). It keeps what was set in
 * localStorage (spool.mock.takeover) so a reload reads it back, like the
 * hub's tenants.settings; every kind is checked before any is written.
 */
export function createMockTakeover(storage = globalThis.localStorage) {
  const KEY = 'spool.mock.takeover'
  const read = () => {
    try { return JSON.parse(storage?.getItem(KEY) || '{}') || {} } catch { return {} }
  }
  const write = (v) => {
    try { storage?.setItem(KEY, JSON.stringify(v)) } catch { /* storage blocked: this page only */ }
  }
  const body = () => {
    const set = read()
    return {
      tenant_id: 'mock',
      vendors: [...TAKEOVER_VENDORS],
      max_failures_max: TAKEOVER_MAX_FAILURES_MAX,
      kinds: TAKEOVER_KINDS.map((kind) => {
        const k = set[kind] || { order: DEFAULT_TAKEOVER[kind].order, max_failures: DEFAULT_TAKEOVER[kind].maxFailures }
        return { kind, order: k.order.slice(), max_failures: k.max_failures, set: Boolean(set[kind]) }
      }),
    }
  }
  const bad = () => {
    const e = new Error('spool 400 bad_ladder')
    e.status = 400
    e.token = 'bad_ladder'
    return e
  }
  return {
    get: body,
    put(kinds) {
      const asked = kinds && typeof kinds === 'object' ? kinds : {}
      if (!Object.keys(asked).length) throw bad()
      const set = read()
      for (const [kind, row] of Object.entries(asked)) {
        if (!TAKEOVER_KINDS.includes(kind)) throw bad()
        if (row !== null && takeoverRule(kind, row?.order, row?.max_failures)) throw bad()
      }
      for (const [kind, row] of Object.entries(asked)) {
        if (row === null) delete set[kind]
        else set[kind] = { order: row.order.slice(), max_failures: row.max_failures }
      }
      write(set)
      return body()
    },
  }
}
