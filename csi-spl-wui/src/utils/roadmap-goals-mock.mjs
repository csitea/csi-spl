/**
 * Spec 112 WUI-3: the mock's synced-event fixtures, so the goal rows, the
 * workspace filter and the goal page run without a hub (NUXT_PUBLIC_USE_MOCK).
 * Two workspaces, as ORC-2 writes them (HUB-2 sets the audience from the
 * workspace's roadmap switch): `demo` (the mock workspace, A) with goals G01
 * and G02, and `beta-ws` (B) with its own G01. The mock answers:
 *
 * - the member read GET /v1/calendar/events?source_key=goal: of the session's
 *   workspace, and only when the viewer is a member of it (the hub's
 *   humanTenant); B's events never leave this file for a member of A only;
 * - the signed-out read GET /v1/public/calendar/events of the page host's
 *   workspace: its `public` events, so nothing while the roadmap is
 *   `internal`. NOTE: today's hub answers a signed-out reader only title,
 *   description and dates (calendar_web.go); the fixture also sends
 *   `source_key`, `kind`, `roadmap_url`, `specs` and `done_lines`, the
 *   fields a public goal row needs (a hub follow-up, named in WUI-3's row).
 *
 * The roadmap switch is the e2e's to set: localStorage
 * `spool.mock.roadmap-public` = a JSON list of public workspace ids.
 * Loaded lazily by the roadmap and goal pages only.
 */
import { calAddDays, calIsoDay } from './calendar-year.mjs'

export const MOCK_ROADMAP_PUBLIC_KEY = 'spool.mock.roadmap-public'
export const MOCK_GOAL_WS = Object.freeze({ a: 'demo', b: 'beta-ws' })

function publicSet() {
  try {
    const list = JSON.parse(globalThis.localStorage?.getItem(MOCK_ROADMAP_PUBLIC_KEY) || '[]')
    return new Set(Array.isArray(list) ? list.map(String) : [])
  } catch {
    return new Set()
  }
}

/** The fixture's synced goal events of workspace `ws` around `today`. */
export function mockGoalFixture(ws, today = calIsoDay(Date.now())) {
  const at = (days, hhmm = '12:00') => `${calAddDays(today, days)}T${hhmm}:00Z`
  const audience = publicSet().has(ws) ? 'public' : 'internal'
  const ev = (n, fields) => ({
    id: `00000000-0000-4000-8000-0000000112${n}`,
    source: 'event',
    description: '',
    all_day: false,
    audience,
    creator_type: 'system',
    creator_id: 'roadmap-sync',
    strategy_url: '',
    ...fields,
    ends_at: fields.starts_at,
  })
  if (ws === MOCK_GOAL_WS.a) {
    return [
      ev('01', { kind: 'goal', source_key: 'goal:G01:deadline', title: 'G01 Every workspace has its roadmap', starts_at: at(40), roadmap_url: '/roadmap?ws=demo&goal=G01#spec-112', specs: ['112', '089'], done_lines: ['Every workspace shows its own goals', 'A public roadmap reads signed out'] }),
      ev('02', { kind: 'milestone', source_key: 'goal:G01:m:filter', title: 'G01 The workspace filter ships', starts_at: at(0) }),
      ev('03', { kind: 'goal', source_key: 'goal:G02:deadline', title: 'G02 One rule for done', starts_at: at(300), roadmap_url: '/roadmap?ws=demo&goal=G02#spec-027', specs: ['027'], done_lines: ['Every spec row counts from one action'] }),
    ]
  }
  if (ws === MOCK_GOAL_WS.b) {
    return [
      ev('11', { kind: 'goal', source_key: 'goal:G01:deadline', title: 'G01 Workspace B private goal', starts_at: at(10), roadmap_url: '/roadmap?ws=beta-ws&goal=G01#spec-001', specs: ['001'], done_lines: ['B only'] }),
    ]
  }
  return []
}

/**
 * GET /v1/calendar/events?source_key=<prefix> in the mock: the session
 * workspace's synced events with that key prefix, or a 403 like the hub's
 * when the viewer is not a member of it.
 * @param {string} ws the session's workspace
 * @param {string[]} memberOf the viewer's workspaces
 * @param {string} prefix
 */
export function mockGoalEvents(ws, memberOf, prefix = 'goal:') {
  if (!memberOf.includes(ws)) throw Object.assign(new Error('calendar 403'), { status: 403, token: 'not_member' })
  return { source_key: prefix, events: mockGoalFixture(ws).filter((e) => e.source_key.startsWith(prefix)) }
}

/**
 * GET /v1/public/calendar/events in the mock, for the page host `ws`: its
 * `public` synced events only (see the NOTE above for the extra fields).
 * @param {string} ws
 */
export function mockPublicGoalEvents(ws) {
  const events = mockGoalFixture(ws).filter((e) => e.audience === 'public')
    .map(({ title, description, starts_at, ends_at, all_day, source_key, kind, roadmap_url, specs, done_lines }) => ({ title, description, starts_at, ends_at, all_day, source_key, kind, roadmap_url, specs, done_lines }))
  return { events }
}
