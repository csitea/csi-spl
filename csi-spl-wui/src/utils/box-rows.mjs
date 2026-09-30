// CLE-77799: the Boxes section groups the roster by box, so the rail can list
// the tenant's boxes and a card can show who is seated on each. Owner, topic
// 1fc29f99: "people use boxes and agents use boxes" — a box's users are BOTH
// the humans (their browser / app sessions, on box-wui or a per-person box) and
// the agents (seated on box-desk / machine boxes), each linked to their People
// or Agents card. And "later on we will have more boxes than the current one
// box", so this is built for many boxes: it never assumes a single box-desk,
// and the rail filters and groups by status.
//
// The roster the DM list already loaded is the source (view-v1 §4.1): the
// box -> [ids] map (peopleRows carries {id, box, online} per seat) and the
// boxes[] detail (online + last_hello_at, keyed by box_id). No extra fetch.

import { BROWSER_BOX } from './view-api.mjs'
import { isAgentId, isHumanId } from './agent-kind.mjs'

/** The browser pseudo-box: where a human's WUI session is seated (view-api). */
export function isBrowserBox(id) {
  return String(id || '') === BROWSER_BOX
}

/**
 * A short machine tag for a box id: `box-desk` -> `desk`, `box-a` -> `a`. A box
 * id without the `box-` prefix is shown as it is. This is the label the rail
 * leads with, so a fleet of boxes reads as `desk`, `nea`, `osp`, … not a wall
 * of `box-` noise.
 * @param {string} id
 */
export function boxTag(id) {
  const s = String(id || '')
  return s.startsWith('box-') ? s.slice(4) : s
}

/**
 * One row per box, built from the roster. Each row carries the box id, its tag,
 * whether it is the browser box, its liveness and last hello, and the seats on
 * it split into people (HUM-*) and agents (<PREFIX>-<n>), each seat the
 * {id, box, online} peopleRows shape so a card can link straight to
 * /people/<id> or /agents/<id@box>.
 *
 * A box is online when its boxes[] detail says so, or — for a box with no
 * detail (the browser box) — when anyone seated on it is online. Sorted online
 * first, then machine boxes before the browser box, then by id, so the rail is
 * stable as boxes come and go.
 *
 * @param {Array<{ id: string, box: string, online?: boolean }>} people peopleRows()
 * @param {Record<string, { online?: boolean, last_hello_at?: string }>} [boxesDetail]
 * @returns {Array<{ id: string, tag: string, browser: boolean, online: boolean,
 *   lastHello: string, people: object[], agents: object[], userCount: number }>}
 */
export function boxRows(people, boxesDetail = {}) {
  const byBox = new Map()
  const ensure = (box) => {
    if (!byBox.has(box)) {
      byBox.set(box, { id: box, tag: boxTag(box), browser: isBrowserBox(box), people: [], agents: [] })
    }
    return byBox.get(box)
  }
  /* every box named in the detail, even one with no seat yet */
  for (const box of Object.keys(boxesDetail || {})) if (box) ensure(box)
  for (const p of Array.isArray(people) ? people : []) {
    const box = String((p && p.box) || '')
    if (!box) continue
    const row = ensure(box)
    if (isHumanId(p.id)) row.people.push(p)
    else if (isAgentId(p.id)) row.agents.push(p)
  }
  const out = []
  for (const row of byBox.values()) {
    const det = (boxesDetail && boxesDetail[row.id]) || null
    const anyOnline = row.people.some((x) => x.online) || row.agents.some((x) => x.online)
    row.online = det ? Boolean(det.online) || anyOnline : anyOnline
    row.lastHello = det ? String(det.last_hello_at || '') : ''
    row.userCount = row.people.length + row.agents.length
    out.push(row)
  }
  out.sort((a, b) => (Number(b.online) - Number(a.online))
    || (Number(a.browser) - Number(b.browser))
    || a.id.localeCompare(b.id))
  return out
}

/**
 * The single box's row (or a bare empty row when the roster has never named
 * it), for the /boxes/<id> card.
 * @param {string} id box_id
 * @param {Array<object>} people peopleRows()
 * @param {Record<string, object>} [boxesDetail]
 */
export function boxByID(id, people, boxesDetail = {}) {
  const box = String(id || '')
  const rows = boxRows(people, boxesDetail)
  return rows.find((r) => r.id === box)
    || { id: box, tag: boxTag(box), browser: isBrowserBox(box), online: false, lastHello: '', people: [], agents: [], userCount: 0 }
}

/**
 * Boxes the filter keeps: a case-insensitive match on the id or the tag. An
 * empty query keeps them all.
 * @param {Array<{ id: string, tag: string }>} rows
 * @param {string} q
 */
export function filterBoxes(rows, q) {
  const needle = String(q || '').trim().toLowerCase()
  if (!needle) return rows
  return (Array.isArray(rows) ? rows : []).filter((r) =>
    String(r.id || '').toLowerCase().includes(needle) || String(r.tag || '').toLowerCase().includes(needle))
}
