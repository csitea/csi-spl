/**
 * Spec 112 WUI-3 (5.3 (a), 6, 12.6): a workspace's goals, as the roadmap's
 * goal rows and the goal page show them. Pure: the page hands in the synced
 * events, the spec rows of roadmap.json, today and the day-of function
 * (date-iso isoDate, the viewer's zone, spec 089), so a test pins them all.
 *
 * - A goal is the `goal:<G01>:` events of ONE workspace (HUB-1 `?source_key=`):
 *   `goal:G01:deadline` (kind goal) and `goal:G01:m:<key>` (kind milestone).
 *   The hub writes them only for an approved goal (12.3), so a goal read here
 *   is approved; a draft never reaches the calendar (spec 2).
 * - Its specs and done-lines ride the deadline event (`specs`, `done_lines`,
 *   ORC-2 writes them); a goal without them shows none.
 * - Progress (6): share-done = linked specs in state `done` / linked specs
 *   found in roadmap.json; mean pct = floor of the mean of their numeric pct.
 * - The workspace filter (12.6) lists only what the viewer may see: their
 *   memberships, or signed out the page host's workspace when its roadmap is
 *   public (the public read answered goal events). Nothing else, whatever
 *   the URL says.
 */
import { inWindow, roadmapRows } from './roadmap-rows.mjs'

const GOAL_KEY = /^goal:(G\d{2}):(deadline|m:([a-z0-9-]{1,32}))$/
const GOAL_ID = /^G\d{2}$/
const WS_ID = /^[a-z0-9][a-z0-9-]{0,62}$/

const str = (v) => (typeof v === 'string' ? v.trim() : '')
const first = (v) => str(Array.isArray(v) ? v[0] : v)

/** 'G01' from a ?goal= value or a /goals/<id> param ('G01-first-million' too), else ''. */
export function roadmapGoalId(value) {
  const v = first(value).slice(0, 3).toUpperCase()
  return GOAL_ID.test(v) ? v : ''
}

/** A workspace slug from ?ws=, else ''. */
export function roadmapWs(value) {
  const v = first(value).toLowerCase()
  return WS_ID.test(v) ? v : ''
}

/** The three-digit spec ids of a `specs` list ('089', '089-calendar' and 89 all read '089'). */
function specIds(list) {
  const out = []
  for (const s of Array.isArray(list) ? list : []) {
    const m = String(s ?? '').match(/^(\d{1,3})(?:-|$)/)
    const id = m ? m[1].padStart(3, '0') : ''
    if (id && !out.includes(id)) out.push(id)
  }
  return out
}

const lines = (list) => (Array.isArray(list) ? list.map((l) => str(l)).filter(Boolean) : [])

/**
 * The goals of a list of synced events, by goal id. Events that are not a
 * `goal:` key are ignored; a goal with only milestones still shows (its
 * deadline empty).
 * @param {unknown[]} events
 * @returns {{ id: string, title: string, deadline: string, eventId: string, audience: string, roadmapUrl: string, strategyUrl: string, specs: string[], doneLines: string[], milestones: { key: string, title: string, at: string, eventId: string }[] }[]}
 */
export function roadmapGoals(events) {
  const byId = new Map()
  const goal = (id) => {
    if (!byId.has(id)) byId.set(id, { id, title: '', deadline: '', eventId: '', audience: '', roadmapUrl: '', strategyUrl: '', specs: [], doneLines: [], milestones: [] })
    return byId.get(id)
  }
  for (const e of Array.isArray(events) ? events : []) {
    const r = e && typeof e === 'object' ? e : {}
    const m = str(r.source_key).match(GOAL_KEY)
    const at = str(r.starts_at)
    if (!m || Number.isNaN(Date.parse(at))) continue
    const g = goal(m[1])
    if (m[2] === 'deadline') {
      Object.assign(g, {
        title: str(r.title),
        deadline: at,
        eventId: str(r.id),
        audience: str(r.audience),
        roadmapUrl: str(r.roadmap_url),
        strategyUrl: str(r.strategy_url),
        specs: specIds(r.specs),
        doneLines: lines(r.done_lines),
      })
    } else {
      g.milestones.push({ key: m[3], title: str(r.title), at, eventId: str(r.id) })
    }
  }
  const goals = [...byId.values()]
  for (const g of goals) g.milestones.sort((a, b) => a.at.localeCompare(b.at) || a.key.localeCompare(b.key))
  return goals.sort((a, b) => a.id.localeCompare(b.id))
}

/**
 * A goal's progress over the spec rows of roadmap.json (spec 6): its linked
 * specs found there, share-done and mean pct (null when nothing to count).
 * @param {{ specs: string[] }} goal
 * @param {{ id: string, state: string, pct: number | null }[]} specRows
 */
export function goalProgress(goal, specRows) {
  const rows = Array.isArray(specRows) ? specRows : []
  const linked = goal.specs.map((id) => rows.find((s) => String(s.id).slice(0, 3) === id)).filter(Boolean)
  const done = linked.filter((s) => s.state === 'done').length
  const pcts = linked.map((s) => s.pct).filter((p) => typeof p === 'number')
  return {
    linked,
    done,
    shareDone: linked.length ? Math.floor((100 * done) / linked.length) : null,
    meanPct: pcts.length ? Math.floor(pcts.reduce((a, b) => a + b, 0) / pcts.length) : null,
  }
}

/** Whole days from `today` to the deadline's day (negative once passed), or null. */
export function goalDaysLeft(deadline, today, dayOf) {
  const day = deadline ? dayOf(deadline) : ''
  const a = Date.parse(`${day}T00:00:00Z`)
  const b = Date.parse(`${today}T00:00:00Z`)
  return Number.isNaN(a) || Number.isNaN(b) ? null : Math.round((a - b) / 86400000)
}

/** True when the goal has its deadline or a milestone inside the `when` window (5.3 (a)). */
export function goalInWindow(goal, when, today, dayOf) {
  if (!when) return true
  return [goal.deadline, ...goal.milestones.map((m) => m.at)].some((at) => at && inWindow(dayOf(at), when, today))
}

/**
 * The spec rows shown for `when` and `goal`: WUI-1's rule (b) (tasks.md
 * changed in the window) or rule (a) (a goal the spec serves has a date in
 * the window); `goal` keeps that goal's specs only. roadmap.json's order.
 * @template {{ id: string, tasks_changed?: string }} T
 * @param {T[]} specs
 * @param {ReturnType<typeof roadmapGoals>} goals
 * @param {{ when: string, goal: string, today: string, dayOf: (iso: string) => string }} f
 * @returns {T[]}
 */
export function roadmapGoalSpecRows(specs, goals, { when, goal, today, dayOf }) {
  const byB = new Set(roadmapRows(specs, when, today, dayOf).map((s) => s.id))
  const inA = new Set(goals.filter((g) => goalInWindow(g, when, today, dayOf)).flatMap((g) => g.specs))
  const only = goal ? new Set((goals.find((g) => g.id === goal) || { specs: [] }).specs) : null
  return specs.filter((s) => {
    const id = String(s.id).slice(0, 3)
    if (only && !only.has(id)) return false
    return !when || byB.has(s.id) || inA.has(id)
  })
}

/**
 * The workspace filter's rows (12.6). Signed in: the session's memberships
 * (claims.tenants), else the one workspace the session or the client names.
 * Signed out: the page host's workspace, and only when its roadmap is public.
 * @param {{ signedOut: boolean, claims: unknown, tenant: string, hostPublic: boolean }} who
 * @returns {{ options: { id: string, label: string }[], active: string }}
 */
export function roadmapWorkspaces({ signedOut, claims, tenant, hostPublic }) {
  const host = roadmapWs(tenant)
  if (signedOut) return { options: host && hostPublic ? [{ id: host, label: host }] : [], active: host && hostPublic ? host : '' }
  const c = claims && typeof claims === 'object' ? claims : {}
  const seen = new Set()
  const options = []
  for (const t of Array.isArray(c.tenants) ? c.tenants : []) {
    const id = roadmapWs(t && typeof t === 'object' ? t.tenant_id : '')
    if (!id || seen.has(id)) continue
    seen.add(id)
    options.push({ id, label: str(t.display_name) || str(t.name) || id })
  }
  const named = roadmapWs(c.active_tenant) || roadmapWs(c.t)
  if (!options.length) {
    const one = named || host
    return { options: one ? [{ id: one, label: str(c.tenant_name) || one }] : [], active: one }
  }
  return { options, active: seen.has(named) ? named : options[0].id }
}

/**
 * The workspace the page shows: ?ws= when the filter lists it, else the
 * active one. `blocked` is a ?ws= the viewer may not see (never read).
 * @param {{ options: { id: string }[], active: string }} list
 * @param {string} want
 */
export function roadmapPickWs(list, want) {
  if (want && list.options.some((o) => o.id === want)) return { ws: want, blocked: '' }
  return { ws: list.active, blocked: want && want !== list.active ? want : '' }
}

/** /calendar?d=<day>&event=<id> (4.4), '' for an event with no id (a signed-out read). */
export function goalCalendarHref(at, eventId, dayOf) {
  const d = at ? dayOf(at) : ''
  return d && eventId ? `/calendar?d=${d}&event=${encodeURIComponent(eventId)}` : ''
}
