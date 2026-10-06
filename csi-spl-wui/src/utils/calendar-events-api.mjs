// spec 089 T008 v1: the event dialog's three writes (spec 6.1.2) - create,
// edit and delete - in the hub or, for the mock workspace, in calendar-mock.
// Create is the one call messages' "Add to calendar" already makes
// (msg-ai-actions createCalendarEvent). A refusal throws an Error carrying
// the HTTP `status` and the hub's error `token` (e.g. private_owner_only).
// spec 097 T013: an update may carry If-Match: "<updated_at>" (spec 4.2); a
// stale one is 409 `edit_conflict`, its Error carrying the current `event`.

import { createCalendarEvent } from './msg-ai-actions.mjs'

function headers(api, ifMatch = '') {
  const h = { accept: 'application/json', 'content-type': 'application/json' }
  if (api && api.token) h.authorization = `Bearer ${api.token}`
  if (ifMatch) h['if-match'] = `"${ifMatch}"`
  return h
}

async function refusal(r, what) {
  let token = ''
  let event = null
  try {
    const body = await r.json()
    token = String(body?.error || body?.token || '')
    if (body?.event?.id) event = body.event
  } catch { /* not JSON */ }
  return Object.assign(new Error(`calendar ${what} ${r.status}`), { status: r.status, token, event })
}

async function send(api, method, id, body, what, ifMatch = '') {
  const r = await fetch(`${String((api && api.base) || '')}/v1/calendar/events/${encodeURIComponent(id)}`, {
    method, credentials: api && api.credentials, headers: headers(api, ifMatch), body: body ? JSON.stringify(body) : undefined,
  })
  if (!r.ok) throw await refusal(r, what)
  const out = await r.json()
  if (!out || !out.event || !out.event.id) throw new Error(`calendar ${what}: no event`)
  return out.event
}

/** POST /v1/calendar/events: the created event. */
export function calendarCreate(api, body) {
  return createCalendarEvent(api, body)
}

/**
 * PATCH /v1/calendar/events/{id}: the event as stored. `ifMatch` (the
 * `updated_at` the caller read) makes it conditional; the mock workspace
 * checks it against its own copy, which every tab shares.
 */
export async function calendarUpdate(api, id, patch, todayIso, ifMatch = '') {
  if (api && api.mock) {
    const { mockCalendarItems, mockCalendarUpdate } = await import('./calendar-mock.mjs')
    const cur = ifMatch ? mockCalendarItems(todayIso).find((x) => x.id === id && x.source === 'event') : null
    if (cur && Date.parse(cur.updated_at) !== Date.parse(ifMatch)) {
      throw Object.assign(new Error('calendar update 409'), { status: 409, token: 'edit_conflict', event: cur })
    }
    return mockCalendarUpdate(id, patch, todayIso)
  }
  return send(api, 'PATCH', id, patch, 'update', ifMatch)
}

/** DELETE /v1/calendar/events/{id}: the event as it was. */
export async function calendarDelete(api, id, todayIso) {
  if (api && api.mock) {
    const { mockCalendarDelete } = await import('./calendar-mock.mjs')
    return mockCalendarDelete(id, todayIso)
  }
  return send(api, 'DELETE', id, null, 'delete')
}
