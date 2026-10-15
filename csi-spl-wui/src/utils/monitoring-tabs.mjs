// csi-spl-wui/src/utils/monitoring-tabs.mjs
//
// SPL-1991 (owner HUM-10, t1 dbf2f39b, msg 94283d6b: "go", A on Q1-Q4): the
// Monitoring section's tabs, one list for the tab bar (pages/monitoring.vue)
// and the tests. Each tab is its own path, /monitoring/<id>, so each is its
// own chunk loaded on demand and the back button walks through them (D4).
// Agents comes first and is where /monitoring lands (Q1 A). The fleet tabs
// that follow are for admins of the operator workspace only (Q3 A).

import { productPath } from './signed-out-redirect.mjs'

/** The tabs in their order. `ready: false` reserves an id and its path for a
 *  tab whose page does not exist yet: the bar never draws it. */
export const MONITORING_TABS = Object.freeze([
  Object.freeze({ id: 'agents', path: '/monitoring/agents', labelKey: 'monitoring.tab.agents', operatorsOnly: false, ready: true }),
  Object.freeze({ id: 'boxes', path: '/monitoring/boxes', labelKey: 'monitoring.tab.boxes', operatorsOnly: false, ready: true }),
  Object.freeze({ id: 'costs', path: '/monitoring/costs', labelKey: 'monitoring.tab.costs', operatorsOnly: false, ready: true }),
  /* spec 140 (live token burn per agent type and agent): reserved, hidden until its page lands */
  Object.freeze({ id: 'tokens', path: '/monitoring/tokens', labelKey: 'monitoring.tab.tokens', operatorsOnly: true, ready: false }),
])

/** Where /monitoring itself goes (Q1 A: no Overview tab). */
export const MONITORING_DEFAULT_PATH = MONITORING_TABS[0].path

/**
 * The tabs the bar draws for this reader: the ready ones, the operator-only
 * ones only for an operator.
 * @param {{ operator?: boolean }} [who]
 */
export function visibleMonitoringTabs(who = {}) {
  return MONITORING_TABS.filter((tab) => tab.ready && (!tab.operatorsOnly || who.operator === true))
}

/**
 * The tab a route is on: /monitoring/boxes and /monitoring/boxes/<id> are
 * both Boxes, with or without a locale prefix. Null off Monitoring and on
 * /monitoring itself (it redirects).
 * @param {string} path
 * @returns {string | null}
 */
export function monitoringTabFor(path) {
  const p = productPath(path)
  for (const tab of MONITORING_TABS) {
    if (p === tab.path || p.startsWith(tab.path + '/')) return tab.id
  }
  return null
}
