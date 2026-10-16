// csi-spl-wui/src/utils/monitoring-tabs.mjs
//
// SPL-1991 (owner HUM-10, t1 dbf2f39b, msg 94283d6b: "go", A on Q1-Q4): the
// Monitoring section's tabs, one list for the tab bar (pages/monitoring.vue)
// and the tests. Each tab is its own path, /monitoring/<id>, so each is its
// own chunk loaded on demand and the back button walks through them (D4).
// Agents comes first and is where /monitoring lands (Q1 A). The fleet tabs
// that follow are for admins of the operator workspace only (Q3 A).
// SPL-2075: each of Agents and Boxes also has its card, /monitoring/agents/<id@box>
// and /monitoring/boxes/<id> (the old /agents and /boxes pages, moved).

import { productPath } from './signed-out-redirect.mjs'

/** The tabs in their order. `ready: false` reserves an id and its path for a
 *  tab whose page does not exist yet: the bar never draws it. */
export const MONITORING_TABS = Object.freeze([
  Object.freeze({ id: 'agents', path: '/monitoring/agents', labelKey: 'monitoring.tab.agents', operatorsOnly: false, ready: true }),
  Object.freeze({ id: 'boxes', path: '/monitoring/boxes', labelKey: 'monitoring.tab.boxes', operatorsOnly: false, ready: true }),
  /* spec 123 5 (SPL-2056): the month's costs, for a member holding costs.read (biz_owner, admin) */
  Object.freeze({ id: 'costs', path: '/monitoring/costs', labelKey: 'monitoring.tab.costs', operatorsOnly: false, ready: true, perm: 'costs.read' }),
  /* spec 140 (live token burn per agent type and agent): reserved, hidden until its page lands */
  Object.freeze({ id: 'tokens', path: '/monitoring/tokens', labelKey: 'monitoring.tab.tokens', operatorsOnly: true, ready: false }),
])

/** Where /monitoring itself goes (Q1 A: no Overview tab). */
export const MONITORING_DEFAULT_PATH = MONITORING_TABS[0].path

/**
 * The tabs the bar draws for this reader: the ready ones, the operator-only
 * ones only for an operator, a tab naming a `perm` only when `who.can`
 * grants it (no `can` = not known yet: hidden; the hub's 403 is the control).
 * @param {{ operator?: boolean, can?: (perm: string) => boolean }} [who]
 */
export function visibleMonitoringTabs(who = {}) {
  return MONITORING_TABS.filter((tab) => tab.ready && (!tab.operatorsOnly || who.operator === true)
    && (!tab.perm || (typeof who.can === 'function' && who.can(tab.perm) === true)))
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

/**
 * SPL-2075 (owner HUM-10, t1 dbf2f39b, msg fd5a2bf4): the Agents and Boxes
 * sections went into Monitoring. An old link (/agents, /agents/<id@box>,
 * /boxes, /boxes/<id>, with or without a locale prefix) answers the matching
 * Monitoring path, no locale prefix (the caller adds it); anything else null.
 * Query (`?r=`) and hash (`#box-people`) are the caller's to keep.
 * @param {string} path
 * @returns {string | null}
 */
export function legacyMonitoringPath(path) {
  const m = productPath(path).match(/^\/(agents|boxes)(?:\/([^/]+))?$/)
  if (!m) return null
  return '/monitoring/' + m[1] + (m[2] ? '/' + m[2] : '')
}
