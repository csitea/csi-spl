// csi-spl-wui/src/utils/reporting-tax.mjs
//
// SPL-6438 (spec 143 taxes-tab.md sections 5 and 6; owner HUM-10, csitea
// topic dc7c9c9a, msg fc8f964e: "Every person of csitea; agents never",
// "Weekly, after the weekly tax check"): Reporting -> Costs -> Taxes, the
// main box's tax index as the hub keeps it. One hub route:
//   GET /v1/view/tax/overview[?year=YYYY]
//     {tax_year, years, today, taken_at, previous_taken_at, snapshot_id,
//      documents: [{arrival_date, kind, doc_type, tax_type, period, due_date,
//                   category, status, due_soon, overdue, open_question}]}
// The hub answers it to every person seated in the tax workspace; 403 to an
// agent seat, a time accountant, a channel guest, an act-as clone and any
// request carrying an Authorization header (so this call never sends the
// view token); every other workspace gets an unknown route's 404. The label
// is drawn only after that read answered 2xx. No amount, file name or
// personal data exists here: the index carries none. The mock's rows are
// invented.

import { mockMeGet, mockRefused } from './act-as-mock.mjs'
import { HUB_READ_TIMEOUT_MS } from './fetch-timeouts.mjs'

export const TAX_OVERVIEW_PATH = '/v1/view/tax/overview'

/** The hub's categories (store.TaxCategories), in the page's order. */
export const TAX_CATEGORIES = Object.freeze(['decisions', 'payments', 'balance', 'msgs'])

/** The mock plays the tax workspace only while this key holds "here" (an
 *  e2e of the tax workspace); otherwise it plays every other workspace, an
 *  unknown route's 404, so the other mock pages keep their five labels. */
export const MOCK_TAX_WORKSPACE_KEY = 'spool.mock.tax_workspace'

// ---------------------------------------------------------------------------
// the mock hub: invented rows

const MOCK_NOT_PERSON = new Set(['pure_agent', 'time_accountant', 'channel_guest'])

function mockOtherWorkspace(store) {
  try {
    return (store || globalThis.localStorage)?.getItem(MOCK_TAX_WORKSPACE_KEY) !== 'here'
  } catch {
    return true
  }
}

const isoDay = (ms) => new Date(ms).toISOString().slice(0, 10)
const isoSecond = (ms) => new Date(ms).toISOString().slice(0, 19) + 'Z'
const DAY = 86400000

/* arrival (days back), kind, type, tax type, period, due (days ahead, '' = none), category, status */
const MOCK_ROWS = [
  [1, 'Example decision', 'decision', 'vat', '2026-01', '9', 'decisions', 'new'],
  [2, 'Example notice', 'notice', 'income', '2026', '', 'decisions', 'new'],
  [6, 'Example payment plan', 'plan', 'vat', '2025-12', '-3', 'payments', 'changed'],
  [12, 'Example balance', 'statement', 'all', '2026-01', '', 'balance', ''],
  [20, 'Example letter', 'letter', 'employer', '2026-01', '', 'msgs', ''],
]

/**
 * The mock overview at now.
 * @param {number} [now]
 */
export function mockTaxOverview(now = Date.now()) {
  const today = Date.UTC(new Date(now).getUTCFullYear(), new Date(now).getUTCMonth(), new Date(now).getUTCDate())
  const documents = MOCK_ROWS.map(([back, kind, docType, taxType, period, ahead, category, status]) => {
    const due = ahead === '' ? 0 : today + Number(ahead) * DAY
    const days = due ? Math.round((due - today) / DAY) : null
    return {
      arrival_date: isoDay(today - Number(back) * DAY), kind, doc_type: docType, tax_type: taxType, period,
      due_date: due ? isoDay(due) : '', category, status,
      due_soon: days !== null && Math.abs(days) <= 30, overdue: days !== null && days < 0,
      open_question: category === 'decisions' && !due,
    }
  })
  const year = new Date(now).getUTCFullYear()
  return {
    tax_year: year, years: [year], today: isoDay(today), taken_at: isoSecond(today - DAY),
    previous_taken_at: isoSecond(today - 8 * DAY), snapshot_id: 'mock-tax-snapshot-1', documents,
  }
}

/**
 * The mock hub's answer to one call (`store` is a Storage, for the tests).
 * @param {string} path
 * @param {number} [now]
 * @param {Storage} [store]
 */
export function mockTaxCall(path, now = Date.now(), store) {
  if (path.split('?')[0] !== TAX_OVERVIEW_PATH || mockOtherWorkspace(store)) {
    throw Object.assign(new Error('404 page not found'), { status: 404 })
  }
  const me = mockMeGet(store)
  if (me && MOCK_NOT_PERSON.has(me.role)) {
    throw mockRefused(TAX_OVERVIEW_PATH, Object.assign(new Error('the tax index is read only from a person\'s own browser session'), { status: 403, error: 'person_only' }))
  }
  return mockTaxOverview(now)
}

// ---------------------------------------------------------------------------
// the hub call

/**
 * GET one tax route from the browser session alone: no Authorization header
 * ever (the hub answers 403 person_only to one). Throws { status, error } on
 * a non-2xx answer, { status: 0 } off the network.
 * @param {{ mock?: boolean, base?: string }} api
 * @param {string} path
 */
export async function taxCall(api, path) {
  if (api.mock) return Promise.resolve().then(() => mockTaxCall(path))
  let res
  try {
    res = await fetch(`${String(api.base).replace(/\/+$/, '')}${path}`, {
      method: 'GET',
      /* the reader's session cookie whatever the view door is */
      credentials: 'include',
      headers: { accept: 'application/json' },
      signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0 })
  }
  const out = await res.json().catch(() => null)
  if (!res.ok) throw Object.assign(new Error(`tax ${res.status}`), { status: res.status, error: String(out?.error || '') })
  return out
}

/* the probe's answer per hub base: a workspace switch asks again */
const readerAnswer = new Map()

/**
 * Does this reader see the Taxes page? The overview read answered 2xx
 * (every person of the tax workspace); any refusal (403, the 404 of every
 * other workspace) or failure is false. Asked once per page load and base.
 * @param {{ mock?: boolean, base?: string }} api
 * @returns {Promise<boolean>}
 */
export function taxReaderProbe(api) {
  const key = api.mock ? 'mock' : String(api.base)
  if (!readerAnswer.has(key)) readerAnswer.set(key, taxCall(api, TAX_OVERVIEW_PATH).then(() => true, () => false))
  return readerAnswer.get(key)
}

/** Forget the probe's answers (the tests). */
export function taxReaderProbeReset() {
  readerAnswer.clear()
}

// ---------------------------------------------------------------------------
// the page's blocks

/**
 * The page's three blocks from one overview answer: due (due_soon, soonest
 * first), week (new or changed, per category, plus the open questions) and
 * the year's documents filtered by category and tax type ('' = all), newest
 * first as the hub sends them; the filters' choices.
 * @param {any} view
 * @param {{ category?: string, taxType?: string }} [filter]
 */
export function taxBlocks(view, filter = {}) {
  const docs = Array.isArray(view?.documents) ? view.documents : []
  const due = docs.filter((d) => d.due_soon).slice().sort((a, b) => String(a.due_date).localeCompare(String(b.due_date)))
  const moved = docs.filter((d) => d.status === 'new' || d.status === 'changed')
  const week = {
    new: moved.filter((d) => d.status === 'new').length,
    changed: moved.filter((d) => d.status === 'changed').length,
    byCategory: TAX_CATEGORIES.map((c) => ({ category: c, docs: moved.filter((d) => d.category === c) })).filter((g) => g.docs.length),
    open: docs.filter((d) => d.open_question),
  }
  const taxTypes = [...new Set(docs.map((d) => String(d.tax_type || '')).filter(Boolean))].sort()
  const all = docs.filter((d) => (!filter.category || d.category === filter.category) && (!filter.taxType || d.tax_type === filter.taxType))
  return { due, week, all, taxTypes, compared: Boolean(view?.previous_taken_at) }
}
