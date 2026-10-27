// csi-spl-wui/src/utils/reporting-tabs.mjs
//
// spec 143 1.2 (SPL-2324, SPL-2351): the Reporting section's tabs, one list
// for the tab bar (pages/reporting.vue) and the tests, built like
// monitoring-tabs.mjs. Each tab is its own path, /reporting/<id>, so each is
// its own chunk loaded on demand and the back button walks through them.
// Releases comes first and is where /reporting lands.

import { productPath } from './signed-out-redirect.mjs'

/** The tabs in their order. `ready: false` reserves an id and its path for a
 *  tab whose page does not exist yet: the bar never draws it. The lane that
 *  lands a tab's page flips its `ready`. */
export const REPORTING_TABS = Object.freeze([
  /* spec 143 2: every signed-in member (its page is spec 143 row 3; the
     shell holds a placeholder there) */
  Object.freeze({ id: 'releases', path: '/reporting/releases', labelKey: 'reporting.tab.releases', adminOnly: false, operatorsOnly: false, ready: true }),
  /* spec 143 3: workspace admins only; its page landed with T033 (SPL-2789) */
  Object.freeze({ id: 'sql', path: '/reporting/sql', labelKey: 'reporting.tab.sql', adminOnly: true, operatorsOnly: false, ready: true }),
  /* spec 143 costs-redesign.md 3.2, slice S1 (SPL-3798, owner HUM-10, t1
     1be0e370, msg 3f1c7128, answer 6 A): Costs replaces the reserved Tokens
     tab, four pages under /reporting/costs (utils/reporting-costs.mjs), for
     a member holding costs.read (biz_owner, admin) */
  Object.freeze({ id: 'costs', path: '/reporting/costs', labelKey: 'reporting.tab.costs', adminOnly: false, operatorsOnly: false, perm: 'costs.read', ready: true }),
  Object.freeze({ id: 'issues', path: '/reporting/issues', labelKey: 'reporting.tab.issues', adminOnly: false, operatorsOnly: false, ready: false }),
  Object.freeze({ id: 'posts', path: '/reporting/posts', labelKey: 'reporting.tab.posts', adminOnly: false, operatorsOnly: false, ready: false }),
  /* spec 143 tasks T053: the fleet's lanes, operator admins only */
  Object.freeze({ id: 'lanes', path: '/reporting/lanes', labelKey: 'reporting.tab.lanes', adminOnly: false, operatorsOnly: true, ready: false }),
])

/** Where /reporting itself goes. */
export const REPORTING_DEFAULT_PATH = REPORTING_TABS[0].path

/**
 * The tabs the bar draws for this reader: the ready ones; an admin-only one
 * for a workspace admin (an operator admin is one); an operator-only one for
 * an admin of the operator workspace only (`who.operator`), never for a
 * workspace admin as such; a tab naming a `perm` only when `who.can` grants
 * it. Not known yet = hidden; the hub's 403 is the control.
 * @param {{ admin?: boolean, operator?: boolean, can?: (perm: string) => boolean }} [who]
 */
export function visibleReportingTabs(who = {}) {
  return REPORTING_TABS.filter((tab) => reportingTabShows(tab, who))
}

/**
 * visibleReportingTabs' rule for one tab (the tests run it on a reserved tab
 * with `ready` forced on).
 * @param {{ ready: boolean, adminOnly?: boolean, operatorsOnly?: boolean, perm?: string }} tab
 * @param {{ admin?: boolean, operator?: boolean, can?: (perm: string) => boolean }} who
 */
export function reportingTabShows(tab, who) {
  return tab.ready
    && (!tab.operatorsOnly || who.operator === true)
    && (!tab.adminOnly || who.admin === true || who.operator === true)
    && (!tab.perm || (typeof who.can === 'function' && who.can(tab.perm) === true))
}

/**
 * The tab a route is on, with or without a locale prefix; a page under a tab
 * keeps it. Null off Reporting and on /reporting itself (it redirects).
 * @param {string} path
 * @returns {string | null}
 */
export function reportingTabFor(path) {
  const p = productPath(path)
  for (const tab of REPORTING_TABS) {
    if (p === tab.path || p.startsWith(tab.path + '/')) return tab.id
  }
  return null
}
