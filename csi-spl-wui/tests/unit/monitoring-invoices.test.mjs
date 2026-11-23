// Spec 181 row B13 (gap G14): Monitoring -> Invoices, the util under the page
// (src/utils/monitoring-invoices.mjs): the hub body as a view, the money, the
// mark paid path, and the mock. Done test on the mock: two invoices, one
// paid -> the list shows one; mark it paid -> the list is empty. CONTROL:
// anyone but the operator admin -> 403, and the page holds no figure of its own.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  INVOICES_MOCK_PAID_KEY,
  invoiceMoney,
  invoicePaidPath,
  mockMarkInvoicePaid,
  mockOverdueInvoices,
  overdueInvoicesOf,
} from '../../src/utils/monitoring-invoices.mjs'
import { TOKENS_MOCK_OPERATOR_KEY } from '../../src/utils/monitoring-tokens.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

/** A localStorage stand-in. */
function memStore(init = {}) {
  const m = new Map(Object.entries(init))
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => { m.set(k, String(v)) }, removeItem: (k) => { m.delete(k) } }
}

const NOW = new Date('2026-11-20T10:00:00Z')

describe('monitoring invoices', () => {
  it('the hub body as a view: a row with no workspace or no YYYY-MM month is dropped', () => {
    const v = overdueInvoicesOf({ as_of: '2026-11-20T10:00:00Z', invoices: [
      { workspace: 'ws-a', workspace_name: 'A', month: '2026-10', currency: 'EUR', humans: 2, total_micros: '24650000.000000', issued_on: '2026-11-03', due_on: '2026-11-17', days_overdue: 3, reminded_at: null },
      { workspace: '', month: '2026-10' },
      { workspace: 'ws-b', month: '2026-13' },
      null,
    ] })
    assert.equal(v.asOf, '2026-11-20T10:00:00Z')
    assert.deepEqual(v.invoices, [{ workspace: 'ws-a', workspaceName: 'A', month: '2026-10', currency: 'EUR', humans: 2,
      totalMicros: '24650000.000000', issuedOn: '2026-11-03', dueOn: '2026-11-17', daysOverdue: 3, remindedAt: '' }])
    assert.deepEqual(overdueInvoicesOf(null), { asOf: '', invoices: [] })
  })
  it('money: micros of the currency, two decimals; junk is empty, never a 0', () => {
    assert.equal(invoiceMoney('24650000.000000', 'EUR', 'en'), '€24.65')
    assert.equal(invoiceMoney('24650000.000000', '', 'en'), '24.65')
    assert.equal(invoiceMoney('', 'EUR', 'en'), '')
    assert.equal(invoiceMoney('x', 'EUR', 'en'), '')
  })
  it('the mark paid path escapes its parts', () => {
    assert.equal(invoicePaidPath('ws-a', '2026-10'), '/v1/operator/invoices/ws-a/2026-10/paid')
    assert.equal(invoicePaidPath('a/b', '2026-10'), '/v1/operator/invoices/a%2Fb/2026-10/paid')
  })
  it('done test (mock): two invoices, one paid -> one listed; mark it paid -> none; again -> 409', () => {
    const store = memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '1' })
    const first = overdueInvoicesOf(mockOverdueInvoices(store, NOW))
    assert.deepEqual(first.invoices.map((i) => i.workspace + '/' + i.month), ['ws-north/2026-10'])
    assert.equal(first.invoices[0].daysOverdue, 3)
    assert.deepEqual(mockMarkInvoicePaid('ws-north', '2026-10', store, NOW), { workspace: 'ws-north', month: '2026-10', paid_at: '2026-11-20T10:00:00Z' })
    assert.deepEqual(JSON.parse(store.getItem(INVOICES_MOCK_PAID_KEY)), ['ws-north/2026-10'])
    assert.deepEqual(overdueInvoicesOf(mockOverdueInvoices(store, NOW)).invoices, [])
    assert.throws(() => mockMarkInvoicePaid('ws-north', '2026-10', store, NOW), (e) => e.status === 409 && e.token === 'already_paid')
    assert.throws(() => mockMarkInvoicePaid('ws-none', '2026-10', store, NOW), (e) => e.status === 404)
  })
  it('CONTROL: anyone but the operator admin gets the hub\'s 403, on the list and on mark paid', () => {
    for (const store of [memStore(), memStore({ [TOKENS_MOCK_OPERATOR_KEY]: '0' }), null]) {
      assert.throws(() => mockOverdueInvoices(store, NOW), (e) => e.status === 403 && e.permission === 'operator.workspaces')
      assert.throws(() => mockMarkInvoicePaid('ws-north', '2026-10', store, NOW), (e) => e.status === 403)
    }
  })
  it('the page: the hub\'s 403 as a sentence, a confirm before mark paid, every text a translation key', () => {
    const page = read('src/pages/monitoring/invoices/index.vue')
    for (const tid of ['invoices-page', 'invoices-forbidden', 'invoices-empty', 'invoices-table', 'invoices-row', 'invoices-mark-paid', 'invoices-refresh']) {
      assert.match(page, new RegExp(`data-test="${tid}"`), tid)
    }
    assert.match(page, /operatorReadable\(await gateMe\(access\)\)/)
    assert.match(page, /if \(!confirm\(t\('monitoring\.invoices\.confirm'/)
    assert.match(page, /markInvoicePaid\(inv\.workspace, inv\.month\)/)
    const en = JSON.parse(read('i18n/locales/en.json'))
    for (const key of [...page.matchAll(/t\('monitoring\.invoices\.([a-z_]+)'/g)].map((m) => m[1])) {
      assert.equal(typeof en.monitoring.invoices[key], 'string', 'en has monitoring.invoices.' + key)
    }
    assert.equal(en.monitoring.tab.invoices, 'Invoices')
  })
  it('the lazy client routes both calls to the operator paths', () => {
    const lazy = read('src/utils/spool-client-lazy.mjs')
    assert.match(lazy, /live\('\/v1\/operator\/invoices\/overdue'\)/)
    assert.match(lazy, /live\(mi\.invoicePaidPath\(workspace, month\), \{ method: 'POST' \}\)/)
    const client = read('src/utils/spool-client.mjs')
    for (const name of ['getOverdueInvoices', 'markInvoicePaid']) assert.match(client, new RegExp(`'${name}'`), name)
  })
})
