/**
 * Spec 096: a member's manual status ("Busy", "Unavailable until 14:00"),
 * without Vue. The hub's contract (spec 7.3 / 7.4):
 *
 * - the roster read's humans[].status = { state, note?, until? }, omitted
 *   when available or expired;
 * - a live frame { type: "status", peer: "HUM-12@<box>", state, note?, until? },
 *   state "available" (note and until omitted) clears it;
 * - PUT /v1/me/status { state, note?, until?, all_workspaces?, pause_notify? }
 *   and DELETE /v1/me/status.
 *
 * Presence (the dot's fill) is not touched here: the ring is the status.
 * Expiry is evaluated on read: a status whose `until` has passed is absent.
 * The whole module loads on demand: with the first status the roster sees,
 * or with the picker / composer line (the 027 initial-chunk budget).
 */
/* only helpers the first screen already uses: importing another one from
   date-iso.mjs would keep it in the entry chunk for this lazy module (027) */
import { isoClock, isoDate, isoDateTime, isoDateTimeSec } from './date-iso.mjs'

export const STATUS_NOTE_MAX = 80


/** The id part of a peer label: `HUM-12@wui` -> `HUM-12`. */
function idOf(peer) {
  return String(peer || '').split('@')[0]
}

function timeOf(value) {
  if (!value) return NaN
  const t = new Date(value).getTime()
  return Number.isNaN(t) ? NaN : t
}

/**
 * Spec 3: trim, drop control characters and line breaks, cut to 80
 * characters (code points, so an emoji is not split).
 */
export function cleanStatusNote(note) {
  // eslint-disable-next-line no-control-regex
  const flat = String(note ?? '').replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]+/g, ' ').trim()
  return Array.from(flat).slice(0, STATUS_NOTE_MAX).join('').trim()
}

/**
 * One status as the WUI keeps it, or null for available / not a status.
 * Spec 096 T005 (Q1): `pauseNotify: true` only on an Unavailable status whose
 * pause box is ticked (`pause_notify`, which only GET/PUT /v1/me/status and
 * the reader's own picker carry); absent otherwise.
 * @param {unknown} raw { state, note?, until?, pause_notify? }
 * @returns {{ state: 'busy' | 'unavailable', note: string, until: string, pauseNotify?: true } | null}
 */
export function normalizeHumanStatus(raw) {
  if (!raw || typeof raw !== 'object') return null
  const r = /** @type {Record<string, unknown>} */ (raw)
  const state = String(r.state || r.status || '')
  if (state !== 'busy' && state !== 'unavailable') return null
  const until = Number.isNaN(timeOf(r.until)) ? '' : new Date(timeOf(r.until)).toISOString()
  const out = { state, note: cleanStatusNote(r.note), until }
  if (state === 'unavailable' && (r.pause_notify === true || r.pauseNotify === true)) out.pauseNotify = true
  return out
}

/** The status, or null once its `until` is at or before `now` (expiry on read). */
export function liveStatus(st, now = Date.now()) {
  if (!st) return null
  const t = timeOf(st.until)
  if (!Number.isNaN(t) && t <= now) return null
  return st
}

/** The roster read's humans[] -> { HUM-x: status } (available members absent). */
export function statusMapFromHumans(humans, now = Date.now()) {
  const out = {}
  if (!Array.isArray(humans)) return out
  for (const h of humans) {
    const id = String((h && (h.human_id || h.id)) || '')
    const st = liveStatus(normalizeHumanStatus(h && h.status), now)
    if (id && st) out[id] = st
  }
  return out
}

/**
 * Apply one `status` frame. Returns the same map when nothing changed, so a
 * caller can skip the write; anything that is not a status frame is ignored.
 * The hub's frame never carries `pause_notify` (it is the member's own), so
 * it drops a held pause; the store then reads it back (getMyStatus).
 */
export function applyStatusFrame(map, frame) {
  const f = frame && typeof frame === 'object' ? frame : null
  if (!f || f.type !== 'status') return map
  const id = idOf(f.peer)
  if (!id) return map
  const st = normalizeHumanStatus(f)
  const had = map[id]
  if (!st) {
    if (!had) return map
    const next = { ...map }
    delete next[id]
    return next
  }
  if (had && had.state === st.state && had.note === st.note && had.until === st.until && had.pauseNotify === st.pauseNotify) return map
  return { ...map, [id]: st }
}

/** Drop expired entries; the same map when none expired. */
export function pruneExpired(map, now = Date.now()) {
  let next = map
  for (const [id, st] of Object.entries(map)) {
    if (liveStatus(st, now)) continue
    if (next === map) next = { ...map }
    delete next[id]
  }
  return next
}

/** Milliseconds until the soonest `until` in the map, or null when none. */
export function msToNextExpiry(map, now = Date.now()) {
  let soonest = Infinity
  for (const st of Object.values(map)) {
    const t = timeOf(st && st.until)
    if (!Number.isNaN(t) && t < soonest) soonest = t
  }
  return soonest === Infinity ? null : Math.max(0, soonest - now)
}

/** The ring on the dot: '' (none), 'busy' (amber) or 'unavailable' (red). */
export function statusRing(st) {
  return st && (st.state === 'busy' || st.state === 'unavailable') ? st.state : ''
}

/**
 * The `until` in the viewer's zone: HH:MM today, else YYYY-MM-DD HH:MM
 * (the WUI's one date format, utils/date-iso.mjs).
 */
export function statusUntilLabel(until, now = Date.now()) {
  if (Number.isNaN(timeOf(until))) return ''
  return isoDate(until) === isoDate(now) ? isoClock(until) : isoDateTime(until)
}

/**
 * The words for a status, as an i18n key + params. `short` is the label
 * alone ("Busy", "Unavailable until 14:00"); the full text adds the note.
 * Null for available.
 * @returns {{ key: string, params: Record<string, string>, note: string } | null}
 */
export function statusWords(st, now = Date.now()) {
  const live = liveStatus(st, now)
  if (!live) return null
  const when = statusUntilLabel(live.until, now)
  /* literal keys: the catalogue split keeps only these four on the first screen */
  const key = live.state === 'busy' ? (when ? 'status.busy_until' : 'status.busy') : (when ? 'status.unavailable_until' : 'status.unavailable')
  return { key, params: when ? { when } : {}, note: live.note }
}

/**
 * The words a person reads: `short` is the label ("Busy", "Unavailable
 * until 14:00"), `full` adds the note after a dot; `ring` is the state.
 * Null for available. `t` is vue-i18n's translate.
 * @param {{ state: string, note: string, until: string } | null} st
 * @param {(key: string, params?: Record<string, string>) => string} t
 */
export function statusLabel(st, t, now = Date.now()) {
  const w = statusWords(st, now)
  if (!w || !st) return null
  const short = t(w.key, w.params)
  return { short, full: w.note ? `${short} · ${w.note}` : short, note: w.note, ring: st.state }
}

/** Spec 096 §7.5: the client re-checks expiry at least once a minute. */
export const STATUS_RECHECK_MS = 60 * 1000

/**
 * The status map's machinery, loaded with the first status the roster sees
 * (stores/roster.ts keeps only thin delegates on the first screen). `map` is
 * a ref-like { value }: frames and roster reads replace it, and a timer drops
 * an expired status at its `until` (at least once a minute), so a tab that
 * missed the clearing frame stops showing it.
 * @param {{ value: Record<string, { state: string, note: string, until: string }> }} map
 * @param {{ set: (fn: () => void, ms: number) => unknown, clear: (id: unknown) => void }} [timers]
 */
export function statusController(map, timers = { set: (fn, ms) => setTimeout(fn, ms), clear: (id) => clearTimeout(/** @type {any} */ (id)) }) {
  let timer = null
  function schedule() {
    if (timer !== null) timers.clear(timer)
    timer = null
    const due = msToNextExpiry(map.value)
    if (due === null) return
    timer = timers.set(() => {
      timer = null
      put(pruneExpired(map.value))
      if (timer === null) schedule()
    }, Math.min(due + 250, STATUS_RECHECK_MS))
  }
  function put(next) {
    if (next === map.value) return
    map.value = next
    schedule()
  }
  const self = {
    /** one `status` frame (spec 7.4) */
    apply(frame) { put(applyStatusFrame(map.value, frame)) },
    /** the roster read's humans[]; `mock`: the lde mock's own statuses
        (localStorage `spool.mock.human-status`, a JSON map HUM-x -> status,
        written by its Set a status and by e2e) */
    fill(humans, mock = false) {
      let list = humans
      if (mock) {
        let st = {}
        try { st = JSON.parse(localStorage.getItem(MOCK_STATUS_KEY) || '{}') || {} } catch { /* none */ }
        list = humans.map((h) => (st[h.human_id] ? { ...h, status: st[h.human_id] } : h))
      }
      put(statusMapFromHumans(list))
    },
    /** a member's live status (id or id@box), null when available or expired */
    of(id) { return liveStatus(map.value[idOf(id)] || null) },
    /** the same in words (statusLabel) */
    label(id, t) { return statusLabel(self.of(id), t) },
  }
  return self
}

/* ---- the picker and the composer line ---- */

export const STATUS_STATES = ['available', 'busy', 'unavailable']
/** Spec 12.6: the hub refuses an `until` further out than this. */
export const STATUS_UNTIL_MAX_DAYS = 90
/** Spec 3: the picker's "until" choices, in order. */
export const STATUS_UNTIL_CHOICES = ['30m', '1h', '2h', 'today', 'tomorrow', 'custom', 'none']

const MIN = 60 * 1000



/** Wall-clock fields of an instant in the viewer's zone (date-iso.mjs prints them). */
function wallFields(ms) {
  const m = isoDateTimeSec(ms).match(/^(\d+)-(\d+)-(\d+) (\d+):(\d+)/)
  return m ? m.slice(1).map(Number) : null
}

/**
 * The instant of a wall-clock time in the viewer's zone: the calendar day of
 * `base` there, plus `addDays`, at h:mi. Null when `base` is not a time.
 */
export function wallInstant(base, addDays, h, mi) {
  const f = wallFields(timeOf(base))
  if (!f) return null
  const want = Date.UTC(f[0], f[1] - 1, f[2] + (addDays || 0), h, mi)
  /* walk the guess by the zone's offset at it; twice, because the offset
     may differ between the first guess and the answer (a DST change) */
  let at = want
  for (let i = 0; i < 2; i++) {
    const g = wallFields(at)
    at += want - Date.UTC(g[0], g[1] - 1, g[2], g[3], g[4])
  }
  return new Date(at)
}

/** A typed `YYYY-MM-DDTHH:MM` (datetime-local) as an instant in the viewer's zone; null when not one. */
export function parseWallDateTime(value) {
  const m = String(value || '').trim().match(/^(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})$/)
  if (!m) return null
  const day = m[1]
  const h = Number(m[2])
  const mi = Number(m[3])
  /* noon UTC of the typed day is within one day of it in every zone; a day
     that does not exist (2026-02-30) comes back as another one */
  const noon = Date.parse(`${day}T12:00:00Z`)
  if (Number.isNaN(noon) || new Date(noon).toISOString().slice(0, 10) !== day || h > 23 || mi > 59) return null
  const seen = isoDate(noon)
  return wallInstant(noon, seen === day ? 0 : seen < day ? 1 : -1, h, mi)
}

/** Spec 9: the default "until" choice for a state (no end for Busy, 1 hour for Unavailable). */
export function defaultUntilChoice(state) {
  return state === 'unavailable' ? '1h' : 'none'
}

/**
 * The `until` instant for a picker choice, as an ISO string; '' for no end;
 * null when a custom value is not a valid time.
 * @param {string} choice one of STATUS_UNTIL_CHOICES
 * @param {number} now
 * @param {string} [custom] the datetime-local value for 'custom'
 */
export function untilFromChoice(choice, now = Date.now(), custom = '') {
  switch (choice) {
    case '30m': return new Date(now + 30 * MIN).toISOString()
    case '1h': return new Date(now + 60 * MIN).toISOString()
    case '2h': return new Date(now + 120 * MIN).toISOString()
    case 'today': {
      const d = wallInstant(now, 0, 23, 59)
      return d ? d.toISOString() : null
    }
    case 'tomorrow': {
      const d = wallInstant(now, 1, 9, 0)
      return d ? d.toISOString() : null
    }
    case 'custom': {
      const d = parseWallDateTime(custom)
      return d ? d.toISOString() : null
    }
    default: return ''
  }
}

/**
 * Why an `until` would be refused, as an i18n key; '' when it is fine.
 * Mirrors the hub's write check (spec 7.3): in the future, at most 90 days.
 */
export function untilProblem(until, now = Date.now()) {
  if (until === '') return ''
  const t = timeOf(until)
  if (until === null || Number.isNaN(t)) return 'status_edit.err_until_invalid'
  if (t <= now) return 'status_edit.err_until_past'
  if (t - now > STATUS_UNTIL_MAX_DAYS * 24 * 60 * MIN) return 'status_edit.err_until_far'
  return ''
}

/**
 * The PUT /v1/me/status body for a picker's values. `available` is a
 * DELETE, not a body: the caller clears instead (null here).
 */
export function statusBody({ state, note, until, allWorkspaces, pauseNotify }) {
  if (state !== 'busy' && state !== 'unavailable') return null
  const body = { state }
  const n = cleanStatusNote(note)
  if (n) body.note = n
  if (until) body.until = until
  if (allWorkspaces) body.all_workspaces = true
  if (pauseNotify && state === 'unavailable') body.pause_notify = true
  return body
}

/**
 * Spec 5.1: whom the composer line names - the DM peer, then every member
 * @mentioned in the draft, each once, the sender never, and only those with a
 * live status. `mentionIds` are member ids the draft names (resolved by the
 * caller from ids or display names).
 * @param {{ dmPeer?: string, mentionIds?: string[], selfId?: string, statusOf: (id: string) => object | null }} p
 * @returns {Array<{ id: string, status: { state: string, note: string, until: string } }>}
 */
export function composerStatusTargets({ dmPeer = '', mentionIds = [], selfId = '', statusOf }) {
  const out = []
  const seen = new Set([idOf(selfId)])
  for (const raw of [dmPeer, ...mentionIds]) {
    const id = idOf(raw)
    if (!id || seen.has(id)) continue
    seen.add(id)
    const st = statusOf(id)
    if (st) out.push({ id, status: st })
  }
  return out
}

/**
 * The member ids a draft @mentions: `@HUM-3` by id, or `@Name` by a member's
 * display name (the @ picker writes the name, SPL-1009). `names` maps a
 * member id to its display name. Longest names match first, so "Ann Lee"
 * wins over "Ann".
 * @param {string} text
 * @param {Array<{ id: string, name?: string }>} people
 */
export function draftMentionIds(text, people) {
  const s = String(text || '')
  if (!s.includes('@')) return []
  const out = []
  const byName = [...people].filter((p) => p.name).sort((a, b) => String(b.name).length - String(a.name).length)
  const re = /(^|[^\w@])@([^\s@]+(?:\s[^\s@]+)*)/g
  let m
  while ((m = re.exec(s)) !== null) {
    const rest = m[2]
    const idHit = /^([A-Za-z]+-\d+)/.exec(rest)
    if (idHit && people.some((p) => p.id === idHit[1])) {
      out.push(idHit[1])
      continue
    }
    const lower = rest.toLowerCase()
    const hit = byName.find((p) => {
      const n = String(p.name).toLowerCase()
      return lower.startsWith(n) && !/[\p{L}\p{N}]/u.test(lower.charAt(n.length))
    })
    if (hit) out.push(hit.id)
  }
  return [...new Set(out)]
}

/** the lde mock's statuses, read back by statusController's fill */
const MOCK_STATUS_KEY = 'spool.mock.human-status'

/**
 * Spec 096 §7.3: PUT /v1/me/status with a body, DELETE it with `null` (back
 * to available; `allWorkspaces` adds ?all_workspaces=true). Here, not in the
 * spool client, so the first screen carries none of it (027). `api` is the
 * spool client (base, token, credentials, mock); the mock writes localStorage.
 * Throws { status } on a refusal (400: bad note / until / state).
 */
export async function putMyStatus(api, selfId, body, { allWorkspaces = false } = {}) {
  if (api.mock) {
    let map = {}
    try { map = JSON.parse(localStorage.getItem(MOCK_STATUS_KEY) || '{}') || {} } catch { /* none */ }
    if (body) map[selfId] = { state: body.state, note: body.note || '', until: body.until || '', pause_notify: body.pause_notify === true }
    else delete map[selfId]
    localStorage.setItem(MOCK_STATUS_KEY, JSON.stringify(map))
    return null
  }
  const headers = { accept: 'application/json' }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  if (body) headers['content-type'] = 'application/json'
  const res = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/me/status${!body && allWorkspaces ? '?all_workspaces=true' : ''}`, {
    method: body ? 'PUT' : 'DELETE',
    credentials: api.credentials,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  })
  if (!res.ok) throw Object.assign(new Error(`status ${res.status}`), { status: res.status })
  return res.status === 204 ? null : res.json().catch(() => null)
}

/**
 * Spec 096 T005: GET /v1/me/status, the reader's own status with its
 * `pause_notify` (the roster never shows it), as a `status` frame for
 * `selfId` that the controller applies. The lde mock has no hub: null (its
 * fill already reads `pause_notify` from localStorage). Null on any failure.
 */
export async function getMyStatus(api, selfId) {
  if (api.mock || !selfId) return null
  try {
    const headers = { accept: 'application/json' }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const res = await fetch(`${String(api.base).replace(/\/+$/, '')}/v1/me/status`, { credentials: api.credentials, headers })
    const body = res.ok ? await res.json() : null
    return body && typeof body === 'object' ? { ...body, type: 'status', peer: selfId, pause_notify: body.pause_notify === true } : null
  } catch {
    return null
  }
}
