/** Left-strip tabs, top to bottom. */

import { productPath } from './signed-out-redirect.mjs'

/* owner HUM-10 (t1 e4bfddb1, msg a78e06c8): no Topics tab; a topic opens in
   its channel (or its DM) */
export const SIDE_TABS = ['dm', 'channels', 'flow']

/** The admin's Users tab: after flow, only for members.invite
 *  (tenant-users.mjs usersEntryVisible), so it is not in SIDE_TABS. */
export const USERS_TAB = 'users'

/** Issues: the third rail tab, directly after Channels. A page, so it is
 *  not one of the four sidebar lists. */
export const ISSUES_TAB = 'issues'

/** Archive (SPL-983): archived threads on /archive, the 7th reorderable rail
 *  tab (last by default, utils/rail-order.ts). A page, like Issues. */
export const ARCHIVE_TAB = 'archive'

/** People (CLE-77794): every tenant member; the list is the sidebar, the
 *  chosen person's card is /people/<id> (a page in the middle pane, like the
 *  DM feed). A reorderable rail tab (utils/rail-order.ts). */
export const PEOPLE_TAB = 'people'

/** Calendar (spec 089 T007): /calendar, a single sheet like Issues (the year
 *  strip and the main view). A page, so not one of the sidebar lists. */
export const CALENDAR_TAB = 'calendar'

/** Monitoring (SPL-1991, t1 dbf2f39b): /monitoring, its tabs Agents and
 *  Boxes as paths (/monitoring/agents, ...). A page, so not one of the
 *  sidebar lists. SPL-2075: the Agents and Boxes rail tabs (CLE-77794,
 *  CLE-77799) went into it; their old paths are Monitoring's. SPL-3250: so
 *  did the personal Event log (005 FR-017), /monitoring/events; /events is
 *  Monitoring's too. */
export const MONITORING_TAB = 'monitoring'

/** Reporting (spec 143 1.1, SPL-2351): /reporting, its tabs as paths
 *  (/reporting/releases, ...). A page, so not one of the sidebar lists. */
export const REPORTING_TAB = 'reporting'

/** Notes (spec 155 2.6, B5 SPL-4123): /notes, the person's own list, one
 *  sheet like Calendar; a note opens as /notes?note=<id>. A page, so not one
 *  of the sidebar lists. */
export const NOTES_TAB = 'notes'

/** Names accepted after `/switch-pane:`. `messages` is the direct-message pane.
 *  `topic` and `topics` still parse (the Topics pane is gone, t1 e4bfddb1)
 *  and open Channels. */
const SWITCH_PANE_NAMES = {
  messages: 'dm',
  channels: 'channels',
  topics: 'channels',
  topic: 'channels',
  flow: 'flow',
}

/**
 * The open route picks a tab when the page is one of the three lists.
 * Search and settings return null so the reader's own choice stays.
 * The call site starts on direct messages.
 * @param {string} path vue-router path, no query
 * @returns {'dm' | 'channels' | 'flow' | 'users' | 'issues' | 'archive' | 'people' | 'calendar' | 'monitoring' | 'reporting' | 'notes' | null}
 */
export function tabForPath(path) {
  const p = productPath(path)
  if (p === '/dm' || p.startsWith('/dm/')) return 'dm'
  if (p === '/channel' || p.startsWith('/channel/')) return 'channels'
  /* `/` (the front door) and a topic's own page sit under Channels since
     the Topics tab went (t1 e4bfddb1) */
  if (p === '/' || p === '/t' || p.startsWith('/t/')) return 'channels'
  if (p === '/issues') return ISSUES_TAB
  if (p === '/users') return USERS_TAB
  if (p === '/archive') return ARCHIVE_TAB
  if (p === '/people' || p.startsWith('/people/')) return PEOPLE_TAB
  if (p === '/calendar') return CALENDAR_TAB
  /* SPL-2075: an old /agents or /boxes link redirects into Monitoring */
  if (p === '/monitoring' || p.startsWith('/monitoring/')) return MONITORING_TAB
  if (p === '/agents' || p.startsWith('/agents/') || p === '/boxes' || p.startsWith('/boxes/')) return MONITORING_TAB
  /* SPL-3250: and an old /events link into Monitoring -> Events */
  if (p === '/events') return MONITORING_TAB
  if (p === '/reporting' || p.startsWith('/reporting/')) return REPORTING_TAB
  if (p === '/notes') return NOTES_TAB
  return null
}

/** 081 T003: the page each page-backed tab opens, tabForPath's inverse. */
const TAB_ROUTES = {
  [ISSUES_TAB]: '/issues',
  [USERS_TAB]: '/users',
  [ARCHIVE_TAB]: '/archive',
  [PEOPLE_TAB]: '/people',
  [CALENDAR_TAB]: '/calendar',
  [MONITORING_TAB]: '/monitoring',
  [REPORTING_TAB]: '/reporting',
  [NOTES_TAB]: '/notes',
}

/** SPL-3785: the pages the page-backed tabs open (isSectionPage reads them). */
export const TAB_ROUTE_PATHS = Object.freeze(Object.values(TAB_ROUTES))

/**
 * 081 T003: where a tab goes, the forward of tabForPath:
 * tabForPath(routeForTab(id)) === id for every id it answers. Direct
 * messages, channels and flow are sidebar lists with no page of their own
 * (there is no /dm, and a channel is one of many), so they answer null and
 * the caller shows the list instead (useSidePane().request). No locale
 * prefix: the caller adds it (localePath).
 * @param {string} id
 * @returns {string | null}
 */
export function routeForTab(id) {
  return Object.prototype.hasOwnProperty.call(TAB_ROUTES, id) ? TAB_ROUTES[id] : null
}

/**
 * CLE-77884: the search page, whose hits the left panel lists (not a rail
 * tab: the sidebar holds that list while the reader opens hits).
 * @param {string} path vue-router path, no query
 */
export function isSearchPage(path) {
  const p = productPath(path)
  return p === '/search' || p.startsWith('/search/')
}

/**
 * Omnibox command `/switch-pane: <name>`.
 * `null` — this line is not the command (send it as a message).
 * `''` — it is the command, but the name is not a pane (do not send).
 * Otherwise the pane id: messages → dm, channels (also topics, topic), flow.
 * @param {string} text
 * @returns {'dm' | 'channels' | 'flow' | '' | null}
 */
export function switchPaneOf(text) {
  const s = String(text || '').trim()
  const m = s.match(/^\/switch-pane:\s*(.*)$/i)
  if (!m) return null
  const name = m[1].trim().toLowerCase()
  if (!name || /\s/.test(name)) return ''
  return Object.prototype.hasOwnProperty.call(SWITCH_PANE_NAMES, name) ? SWITCH_PANE_NAMES[name] : ''
}
