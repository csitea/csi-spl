// csi-spl-wui/src/utils/expenses-tabs.mjs
//
// Spec 143 costs-redesign.md 3.8 (SPL-4382; owner HUM-10, t1 4f48f878, msgs
// 4cea9710, b0ccc0aa, 50d84663; name: poll 9fbea87a answer A): the Expenses
// section, a level-0 rail entry where costs are ENTERED, one tab per cost
// type: AI costs, Cloud infra costs, HR costs. Reporting -> Costs only reports
// them (utils/reporting-costs.mjs). One list for the tab bar
// (pages/expenses.vue) and the tests, built like reporting-tabs.mjs: each tab
// is its own path, /expenses/<id>, so its own chunk, and the back button walks
// through them. AI costs comes first and is where /expenses lands.

import { productPath } from './signed-out-redirect.mjs'

/** The tabs in their order. `operatorsOnly`: drawn for an operator admin only
 *  (the paid items are the estate's; the hub's 403 on /v1/operator/* is the
 *  control). `entry: false` = the type has no entry form yet (its storage is
 *  the next lane's, SPL-4382 split B); the tab says so and shows no numbers. */
export const EXPENSES_TABS = Object.freeze([
  /* the paid subscriptions and top-ups (spec 140 3.8, SPL-2567), moved here
     from Monitoring -> Tokens */
  Object.freeze({ id: 'ai', path: '/expenses/ai', labelKey: 'expenses.tab.ai', operatorsOnly: true, entry: true }),
  Object.freeze({ id: 'cloud', path: '/expenses/cloud', labelKey: 'expenses.tab.cloud', operatorsOnly: true, entry: false }),
  Object.freeze({ id: 'hr', path: '/expenses/hr', labelKey: 'expenses.tab.hr', operatorsOnly: true, entry: false }),
])

/** Where /expenses itself goes. */
export const EXPENSES_DEFAULT_PATH = EXPENSES_TABS[0].path

/** The tabs the bar draws for this reader. @param {{ operator?: boolean }} [who] */
export function visibleExpensesTabs(who = {}) {
  return EXPENSES_TABS.filter((tab) => !tab.operatorsOnly || who.operator === true)
}

/**
 * The tab a route is on, with or without a locale prefix; a page under a tab
 * keeps it. Null off Expenses and on /expenses itself (it redirects).
 * @param {string} path
 * @returns {string | null}
 */
export function expensesTabFor(path) {
  const p = productPath(path)
  for (const tab of EXPENSES_TABS) {
    if (p === tab.path || p.startsWith(tab.path + '/')) return tab.id
  }
  return null
}
