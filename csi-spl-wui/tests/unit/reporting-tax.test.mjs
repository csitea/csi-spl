// SPL-6438 (spec 143 taxes-tab.md sections 5 and 6): the Taxes page's util.
// The mock plays the tax workspace while spool.mock.tax_workspace = here; a seat that is not a person's gets 403,
// any other value (another workspace) an unknown route's 404; the probe is true only on a 2xx; the blocks group the hub's flags.
// Every row is invented.
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  MOCK_TAX_WORKSPACE_KEY, TAX_CATEGORIES, TAX_OVERVIEW_PATH, mockTaxCall, mockTaxOverview, taxBlocks, taxReaderProbe, taxReaderProbeReset,
} from '../../src/utils/reporting-tax.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

/** A Storage over a plain object. */
function memStore(init = {}) {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k) }
}

const NOW = Date.UTC(2026, 2, 10, 12)

describe('the mock hub (the tax workspace, its doors)', () => {
  it('a person of the tax workspace reads the overview; it carries no amount and no file name', () => {
    const out = mockTaxCall(TAX_OVERVIEW_PATH, NOW, memStore({ [MOCK_TAX_WORKSPACE_KEY]: 'here' }))
    assert.equal(out.tax_year, 2026)
    assert.ok(out.documents.length >= 4)
    for (const d of out.documents) {
      assert.deepEqual(Object.keys(d).sort(), ['arrival_date', 'category', 'doc_type', 'due_date', 'due_soon', 'kind', 'open_question', 'overdue', 'period', 'status', 'tax_type'])
      assert.ok(TAX_CATEGORIES.includes(d.category), d.category)
    }
  })
  it('an agent seat, a time accountant, a channel guest: 403; another workspace: 404', () => {
    for (const role of ['pure_agent', 'time_accountant', 'channel_guest']) {
      const store = memStore({ [MOCK_TAX_WORKSPACE_KEY]: 'here', 'spool.mock.me': JSON.stringify({ role, permissions: [] }) })
      assert.throws(() => mockTaxCall(TAX_OVERVIEW_PATH, NOW, store), (e) => e.status === 403, role)
    }
    const dev = memStore({ [MOCK_TAX_WORKSPACE_KEY]: 'here', 'spool.mock.me': JSON.stringify({ role: 'developer', permissions: [] }) })
    assert.equal(mockTaxCall(TAX_OVERVIEW_PATH, NOW, dev).tax_year, 2026)
    for (const v of [null, 'other', '']) {
      const st = memStore(v === null ? {} : { [MOCK_TAX_WORKSPACE_KEY]: v })
      assert.throws(() => mockTaxCall(TAX_OVERVIEW_PATH, NOW, st), (e) => e.status === 404, String(v))
    }
  })
})

describe('the probe', () => {
  beforeEach(() => taxReaderProbeReset())
  it('true on a 2xx, false on a refusal, once per base', async () => {
    const realFetch = globalThis.fetch
    let calls = 0
    globalThis.fetch = async (url) => { calls++; return String(url).startsWith('https://tax.example') ? { ok: true, status: 200, json: async () => ({ documents: [] }) } : { ok: false, status: 404, json: async () => ({ error: 'not_found' }) } }
    try {
      assert.equal(await taxReaderProbe({ base: 'https://tax.example' }), true)
      assert.equal(await taxReaderProbe({ base: 'https://api.example' }), false)
      assert.equal(await taxReaderProbe({ base: 'https://api.example' }), false)
      assert.equal(calls, 2)
    } finally {
      globalThis.fetch = realFetch
    }
  })
  it('the call never sends an Authorization header (the hub refuses one)', () => {
    assert.doesNotMatch(readFileSync(join(WUI, 'src/utils/reporting-tax.mjs'), 'utf8'), /[Aa]uthorization['"]?\s*:/)
  })
})

describe('the blocks', () => {
  const view = mockTaxOverview(NOW)
  it('due soonest first; this week by category; open questions; the year filtered', () => {
    const b = taxBlocks(view)
    assert.ok(b.due.length >= 2)
    assert.deepEqual(b.due.map((d) => d.due_date), [...b.due.map((d) => d.due_date)].sort())
    assert.equal(b.compared, true)
    assert.equal(b.week.new, 2)
    assert.equal(b.week.changed, 1)
    assert.deepEqual(b.week.byCategory.map((g) => g.category), ['decisions', 'payments'])
    assert.equal(b.week.open.length, 1)
    assert.equal(b.all.length, view.documents.length)
    assert.ok(taxBlocks(view, { category: 'msgs' }).all.every((d) => d.category === 'msgs'))
    assert.ok(taxBlocks(view, { taxType: 'vat' }).all.every((d) => d.tax_type === 'vat'))
    assert.deepEqual(b.taxTypes, [...new Set(view.documents.map((d) => d.tax_type))].sort())
  })
  it('no snapshot: empty blocks, nothing compared', () => {
    const b = taxBlocks({ documents: [] })
    assert.deepEqual([b.due.length, b.all.length, b.week.open.length, b.compared], [0, 0, 0, false])
    assert.equal(taxBlocks(null).all.length, 0)
  })
})

describe('the strings', () => {
  it('every key the page names is in every locale', () => {
    const page = readFileSync(join(WUI, 'src/pages/reporting/costs/taxes.vue'), 'utf8')
    const keys = new Set([...page.matchAll(/'(reporting\.taxes\.[a-z_.]+)'/g)].map((m) => m[1]).filter((k) => !k.endsWith('.')))
    for (const c of TAX_CATEGORIES) keys.add('reporting.taxes.category.' + c)
    for (const s of ['new', 'changed']) keys.add('reporting.taxes.status.' + s)
    keys.add('reporting.costs.label.taxes')
    assert.ok(keys.size > 25, String(keys.size))
    const dir = join(WUI, 'i18n/locales')
    for (const f of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const cat = JSON.parse(readFileSync(join(dir, f + '.json'), 'utf8'))
      for (const k of keys) assert.equal(typeof k.split('.').reduce((o, x) => o?.[x], cat), 'string', f + ': ' + k)
    }
  })
})
