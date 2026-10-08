/**
 * Spec 107 Q7 = B (T019): the header timer for time worked outside the app.
 *
 * Loaded only by the lazy HoursTimer chunk, never by the header itself: the
 * header reads HOURS_TIMER_KEY inline to know whether to load it (027).
 *
 * Where a running timer lives: this device's localStorage, one row per
 * workspace + member ({target, label, start, stopped?}). Not the hub: the hub
 * has nowhere to keep it without a new table, a second device rarely needs
 * it, and a running timer is nobody's business until it is stopped (spec
 * 1.7). A reload or a closed tab keeps it; another browser does not see it.
 *
 * On stop the interval goes to POST /v1/me/hours/timer once; the hub splits it
 * at the member's midnight and adds it to that day's row. A refusal keeps the
 * row with its stop time, so Retry sends the same interval and Discard drops it.
 */

/** The localStorage key; the header only asks whether it holds anything. */
export const HOURS_TIMER_KEY = 'spool.hours-timer'
/** the lde mock's written intervals, and its freeze switch (e2e) */
export const HOURS_TIMER_MOCK_LOG = 'spool.mock.hours-timer-log'
export const HOURS_TIMER_MOCK_FROZEN = 'spool.mock.hours-frozen'

function readAll(storage) {
  try {
    const all = JSON.parse(storage.getItem(HOURS_TIMER_KEY) || '{}')
    return all && typeof all === 'object' && !Array.isArray(all) ? all : {}
  } catch {
    return {}
  }
}

/** the row key of a member in a workspace */
export function hoursTimerOwner(tenant, hum) {
  return `${String(tenant || '')}/${String(hum || '')}`
}

/** The member's timer, or null. A row without a target or a start is none. */
export function hoursTimerRead(storage, owner) {
  const r = readAll(storage)[owner]
  if (!r || typeof r.target !== 'string' || !r.target || !Number.isFinite(Date.parse(r.start))) return null
  return { target: r.target, label: String(r.label || r.target), start: r.start, stopped: typeof r.stopped === 'string' ? r.stopped : '' }
}

/** Write (row) or drop (null) the member's timer; the key goes when empty. */
export function hoursTimerWrite(storage, owner, row) {
  try {
    const all = readAll(storage)
    if (row) all[owner] = row
    else delete all[owner]
    if (Object.keys(all).length) storage.setItem(HOURS_TIMER_KEY, JSON.stringify(all))
    else storage.removeItem(HOURS_TIMER_KEY)
  } catch {
    /* private mode: the timer lives as long as the page */
  }
}

/** h:mm:ss of ms (never negative) */
export function hoursTimerClock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000))
  const pad = (n) => String(n).padStart(2, '0')
  return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`
}

/** h:mm of minutes */
export function hoursTimerMinutes(m) {
  const n = Math.max(0, Math.round(Number(m) || 0))
  return `${Math.floor(n / 60)}:${String(n % 60).padStart(2, '0')}`
}

/** The i18n key of a stop refusal: { status, error } as postHoursTimer throws it. */
export function hoursTimerRefusalKey(err) {
  const code = err && typeof err === 'object' ? String(err.error || '') : ''
  if (code === 'period_frozen') return 'hours_timer.err_frozen'
  if (code === 'day_cap') return 'hours_timer.err_day_cap'
  if (code === 'bad_timer') return 'hours_timer.err_bad'
  if (err && typeof err === 'object' && (err.status === 401 || err.status === 403)) return 'hours_timer.err_session'
  return 'hours_timer.err_network'
}

/** the mock hub: one piece per local day of the browser's zone */
function mockPieces(start, end) {
  const out = []
  for (let at = new Date(start); at < end;) {
    const next = new Date(at.getFullYear(), at.getMonth(), at.getDate() + 1)
    const stop = next < end ? next : end
    const minutes = Math.round((stop - at) / 60000)
    const d = `${at.getFullYear()}-${String(at.getMonth() + 1).padStart(2, '0')}-${String(at.getDate()).padStart(2, '0')}`
    if (minutes > 0) out.push({ day: d, minutes })
    at = stop
  }
  return out
}

function mockPost(body) {
  if (localStorage.getItem(HOURS_TIMER_MOCK_FROZEN) === '1') {
    throw Object.assign(new Error('status 409'), { status: 409, error: 'period_frozen', detail: "the day's hours period is frozen" })
  }
  const written = mockPieces(new Date(body.start), new Date(body.end))
  let log = []
  try { log = JSON.parse(localStorage.getItem(HOURS_TIMER_MOCK_LOG) || '[]') || [] } catch { /* none */ }
  log.push({ target: body.target, start: body.start, end: body.end, written })
  localStorage.setItem(HOURS_TIMER_MOCK_LOG, JSON.stringify(log))
  return { written }
}

/**
 * POST /v1/me/hours/timer {target, start, end} -> {written: [{day, minutes}]}.
 * `api` is the spool client (base, token, credentials, mock). Throws
 * { status, error, detail } on a refusal, { status: 0 } off the network.
 */
export async function postHoursTimer(api, body) {
  if (api.mock) return mockPost(body)
  const headers = { accept: 'application/json', 'content-type': 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  let res
  try {
    res = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/me/hours/timer`, {
      method: 'POST',
      credentials: api.credentials,
      headers,
      body: JSON.stringify(body),
    })
  } catch {
    throw Object.assign(new Error('network'), { status: 0 })
  }
  const out = await res.json().catch(() => null)
  if (!res.ok) {
    throw Object.assign(new Error(`status ${res.status}`), { status: res.status, error: String(out?.error || ''), detail: String(out?.detail || out?.message || '') })
  }
  return out || { written: [] }
}
