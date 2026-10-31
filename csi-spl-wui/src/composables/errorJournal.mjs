// csi-spl-wui/src/composables/errorJournal.mjs
//
// ONE error channel for the WUI (ported from the donor WUI).
//
// Every failure the UI swallows or renders as a sentence also lands here, in
// order, and the gated DebugPanel renders it. Without it the only record of
// "the viewer showed an error" is a screenshot with no handle on it.
//
//   * pure ES module — no Vue, no DOM, no network of its own. It must keep
//     working when the hub is dead, so everything it needs is in the bundle.
//   * mutations are CLIENT-ONLY. `nuxt generate` must never bake a build-time
//     failure into a static page.
//   * nothing here throws. It runs when things are already going wrong.
//
// SECURITY — the control is NEVER CAPTURE, not redact-at-render: a buffer that
// never held the secret cannot leak it through the copy button, a memory dump,
// a screenshot, or a future feature. Request bodies, response bodies, every
// HTTP header in both directions, and the whole URL query string are not
// captured at all — the query string is where ?token= / ?code= / ?state= live,
// i.e. view-token and OAuth material.
//
// The pure text half (redaction, origin scoping, summary and clipboard
// formatters) lives in utils/error-journal-format.mjs, the ring buffer in
// utils/error-journal-store.mjs. This file builds records, owns the error
// reference ids and is the one import path for callers: it re-exports both.

// Relative, not the `@/` alias: this module is imported and EXECUTED directly
// by `node tests/unit/*.test.mjs`, which has no Vite resolver and no
// node_modules. A test that cannot import the real thing ends up asserting
// against a re-implementation of it.
import { isAbortError, statusFrom } from './apiHealth.mjs'
import { redactPath, redactText, redactUrl } from '../utils/error-journal-format.mjs'
import { mergeRecord, pushRecord } from '../utils/error-journal-store.mjs'

export {
  ageParts,
  formatRecords,
  groupByOrigin,
  redactPath,
  redactText,
  redactUrl,
  shouldCollapseOnRouteChange,
  summariseRecord,
} from '../utils/error-journal-format.mjs'
export {
  ERROR_JOURNAL_LIMIT,
  clearErrors,
  getErrors,
  resetErrorJournal,
  subscribeErrors,
} from '../utils/error-journal-store.mjs'

/** Longest message we keep. Long enough to diagnose, short enough to read. */
const MAX_MESSAGE_CHARS = 800

// ── record shape ───────────────────────────────────────────────────────────

function randomToken() {
  try {
    const c = typeof globalThis !== 'undefined' ? globalThis.crypto : undefined
    if (c && typeof c.getRandomValues === 'function') {
      const b = new Uint8Array(2)
      c.getRandomValues(b)
      return [...b].map((x) => x.toString(16).padStart(2, '0')).join('')
    }
  } catch {
    // fall through
  }
  return Math.floor(Math.random() * 0x10000).toString(16).padStart(4, '0')
}

// One token per tab, so two records from the same session are recognisably
// related and a reference id read aloud is unambiguous. It identifies the
// RECORD, not the person: no session, user or device information goes into it.
const tabToken = randomToken()
let seq = 0

function nowIso() {
  try {
    return new Date().toISOString()
  } catch {
    return ''
  }
}

function currentRoute() {
  try {
    return typeof window !== 'undefined' && window.location
      ? redactPath(window.location.pathname, 200)
      : ''
  } catch {
    return ''
  }
}

// ── the error reference id ────────────────────────────────────────────────
//
// What a reader can quote. `ref` above (`E3-1a2f`) identifies a record INSIDE
// this tab and means nothing to an operator reading the hub log; this is the
// id that also exists on the server side, so a screenshot and a log line can
// be joined.
//
// The shape is one contract, shared with the server half:
//
//   PREFIX-YYYYMMDD-HHMMSS-XXXX     UTC, XXXX = UPPERCASE hex
//   ERR-20260830-210542-9B2F        server-side error   (API `error.error_id`)
//   ERR-CLIENT-20260830-210542-9B2F browser-side failure (generated here)
//
// SECURITY — why this is a strict MATCH and never a redaction. Everything else
// in this module is scrubbed on the way in by `redactText`/`redactPath`; an id
// is not. Two reasons it must not be:
//
//   1. An id must never carry payload, and a validator is the only control
//      that can PROVE that. `redactText` removes what its rules recognise; an
//      exact-shape match admits nothing else at all, so a server that started
//      appending a user's e-mail to the field would be rejected outright
//      rather than half-scrubbed.
//   2. `redactText` would eat it anyway. `ERR-20260830-210542-9B2F` is exactly
//      24 characters of `[A-Za-z0-9+/_-]`, so the blob rule collapses it to
//      `<redacted:blob>` — and `ERR-CLIENT-…` (31 chars) with it. Anything
//      that puts an id through the free-text scrubber destroys it. Do not
//      "tidy" that by widening the blob rule: it is doing its job.
//
// So: a value either matches ERROR_ID_RE and is kept verbatim, or it is
// dropped and a client-side id is minted in its place.

/** The only id shape accepted or produced. Do not relax it. */
export const ERROR_ID_RE = /^ERR(?:-CLIENT)?-\d{8}-\d{6}-[0-9A-F]{4}$/

/** UPPERCASE hex, 4 digits, from the CSPRNG where there is one. */
function salt4() {
  return randomToken().slice(0, 4).toUpperCase().padStart(4, '0')
}

/**
 * Mint `ERR-CLIENT-YYYYMMDD-HHMMSS-XXXX` for a failure the server never saw:
 * a transport drop, a DNS timeout, a 502 emitted by the load balancer before
 * the app was reached, an in-page exception. Those are exactly the failures
 * that are invisible to server-side monitoring, so the id is the only handle
 * anyone will ever have on them — it reaches an operator through the RUM
 * beacon (`client_error`) and the staff panel.
 *
 * @param {Date} [when] defaults to now; injectable so the test is not a clock.
 * @returns {string}
 */
export function newClientErrorId(when) {
  let iso = ''
  try {
    const d = when instanceof Date ? when : new Date()
    iso = d.toISOString()
  } catch {
    // An unreadable clock is not a reason to have no id — see below.
  }
  // Parsed, not sliced. The repo bans ISO truncation by offset (it is how
  // locale-dependent date output keeps coming back), and an anchored match is
  // the better instrument anyway: a Date that could not produce an ISO string
  // simply fails to match, and the id falls back to a zero stamp rather than
  // to six characters of whatever the string happened to contain. A zeroed
  // stamp is still unique enough to grep for and still says "client side".
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/.exec(iso)
  const ymd = m ? `${m[1]}${m[2]}${m[3]}` : '00000000'
  const hms = m ? `${m[4]}${m[5]}${m[6]}` : '000000'
  return `ERR-CLIENT-${ymd}-${hms}-${salt4()}`
}

/** Keep a candidate only if it is exactly an id. @param {unknown} v */
function acceptId(v) {
  if (typeof v !== 'string') return ''
  const s = v.trim()
  return ERROR_ID_RE.test(s) ? s : ''
}

/**
 * The SERVER's error id for a failure, or '' when there is not one.
 *
 * Probed in the order the value is most likely to be trustworthy — body first
 * (the API's own envelope), header second. Both are the same value by the API
 * contract; the header exists because a response the client cannot parse still
 * has headers.
 *
 * Accepts anything: a caught ofetch error, an ofetch hook context, a raw
 * envelope, a bare string. Never throws — a getter on a foreign object may.
 *
 * NOTE for the deploy window: the WUI ships ahead of the API by roughly six
 * minutes on a push, and `X-Error-Id` is a non-simple response header that a
 * cross-origin read only sees once the API lists it in
 * Access-Control-Expose-Headers. A missing id is therefore an ordinary state,
 * not a defect — the caller falls back to `newClientErrorId()`.
 *
 * @param {unknown} input
 * @returns {string}
 */
export function extractErrorId(input) {
  try {
    if (input == null) return ''
    if (typeof input === 'string') return acceptId(input)
    if (typeof input !== 'object') return ''

    /** @type {any} */
    const o = input
    // A hook context, a caught error, a raw envelope and the RESPONSE object
    // are all probed the same way, so a caller never has to know which one it
    // is holding. The response is in the list because ofetch hands the same
    // object to its onResponseError hook and to the FetchError it throws
    // afterwards — stamping it there (see stampErrorId) is what makes the
    // banner quote the id the journal already recorded, rather than minting a
    // second one for one failure.
    const errs = [o, o.error, o.cause, o.response, o.error && o.error.response]
      .filter((x) => x && typeof x === 'object')

    for (const e of errs) {
      // Already resolved by an earlier pass (see stampErrorId below).
      const stamped = acceptId(e.errorId)
      if (stamped) return stamped
      // `error.error_id` in the API envelope, wherever ofetch parked the body.
      for (const bag of [e.data, e._data, e.response && e.response._data, e.error]) {
        const env = bag && typeof bag === 'object' ? bag.error : null
        const hit = acceptId(env && typeof env === 'object' ? env.error_id : '')
        if (hit) return hit
      }
      // The envelope itself, unwrapped.
      const flat = acceptId(e.error_id)
      if (flat) return flat
    }

    for (const e of errs) {
      const res = e.response
      const h = res && res.headers
      if (h && typeof h.get === 'function') {
        const hit = acceptId(h.get('X-Error-Id'))
        if (hit) return hit
      }
    }
    return ''
  } catch {
    return ''
  }
}

/**
 * Remember the resolved id ON the error object, so a component that is handed
 * the same rejection later shows the id the journal already recorded rather
 * than minting a second one for one failure. Non-enumerable, so it cannot
 * appear in a `JSON.stringify` of the error or widen anything that iterates
 * its keys. Silently gives up on a frozen or exotic object.
 *
 * @param {unknown} err
 * @param {string} id
 */
function stampErrorId(err, id) {
  try {
    if (!err || typeof err !== 'object' || !acceptId(id)) return
    if (acceptId(/** @type {any} */ (err).errorId)) return
    Object.defineProperty(err, 'errorId', {
      value: id, enumerable: false, configurable: true, writable: true,
    })
  } catch {
    /* a frozen error is still a perfectly good error */
  }
}

/** Longest component trail a Vue error's record keeps in `path` (the hub's cap). */
const MAX_TRAIL_CHARS = 200

/**
 * Build one redacted record. Exported so the redaction table can be tested
 * directly, on any platform, without the client-only gate in the way.
 *
 * @param {{
 *   source?: unknown, method?: unknown, url?: unknown, status?: unknown,
 *   code?: unknown, message?: unknown, name?: unknown, route?: unknown,
 *   error?: unknown, trail?: unknown, inline?: unknown
 * }} [input]  `trail`: a Vue error's component trail, kept in `path` when
 *   the record has no URL (utils/vue-error-trail.mjs); `inline: true` = the
 *   page already says it in place, so the snackbar skips it (SPL-1833)
 * @returns {object | null}
 */
export function buildErrorRecord(input) {
  if (!input || typeof input !== 'object') return null
  const err = input.error && typeof input.error === 'object' ? input.error : null

  const status = (() => {
    const direct = Number(input.status)
    if (Number.isFinite(direct) && direct > 0) return direct
    const derived = statusFrom(input)
    return Number.isFinite(derived) && derived > 0 ? derived : 0
  })()

  const url = redactUrl(input.url)
  const { origin } = url
  const path = url.path || (input.trail ? redactPath(input.trail, MAX_TRAIL_CHARS) : '')

  // The API's stable error envelope: { error: { code, message } }. `code` is a
  // enumerated identifier (error.email_taken, …) — that is the useful half.
  const envelope = err && err.data && typeof err.data === 'object' ? err.data.error : null
  // a hub socket refusal has no envelope; its reason is the
  // rejection's `token` (unknown_channel, forbidden, …). Without it the
  // owner's ERR-CLIENT-20260927-204316-6D9A read "did not reach the hub" in
  // the event log, with the reason nowhere.
  const token = err && typeof err.token === 'string' ? err.token : ''
  const code = redactText(
    input.code ?? (envelope && typeof envelope === 'object' ? envelope.code : token),
    120,
  )
  const message = redactText(
    input.message
      ?? (envelope && typeof envelope === 'object' ? envelope.message : null)
      ?? (err ? err.message : null),
    MAX_MESSAGE_CHARS,
  )
  const name = redactText(input.name ?? (err ? err.name : ''), 80)

  // The reference a human quotes. The server's own id when the response
  // carried one, a freshly minted ERR-CLIENT-… when it did not (transport
  // drop, LB 5xx, in-page exception, or a hub that does not emit one). Never empty: a record nobody can cite is the
  // thing this feature exists to abolish.
  //
  // NOT passed through redactText — see the ERROR_ID_RE section above; the
  // scrubber would collapse a 24-character id to <redacted:blob>, and an
  // exact-shape match is the stronger control anyway.
  const errorId = extractErrorId(input) || newClientErrorId()

  seq += 1
  return {
    seq,
    ref: `E${seq}-${tabToken}`,
    errorId,
    at: nowIso(),
    source: redactText(input.source, 80),
    method: redactText(input.method, 12).toUpperCase(),
    origin,
    path,
    status,
    code,
    message,
    name,
    // `route` is a pathname too — scrubbed per segment like `path`.
    route: input.route === undefined ? currentRoute() : redactPath(input.route, 200),
    ...(input.inline === true ? { inline: true } : {}),
  }
}

// ── capture ────────────────────────────────────────────────────────────────

function isClient(opts) {
  if (opts && Object.prototype.hasOwnProperty.call(opts, 'isClient')) {
    return !!opts.isClient
  }
  return typeof window !== 'undefined'
}

// ── one failure, one record (SPL-4523) ─────────────────────────────────────
//
// prd human_events, n=100 (SPL-4419): 73 rows were `api ... TypeError Failed
// to fetch`, because one network drop journaled one record per request (up to
// 14 a minute), and 3 rows inside 1 ms carried ONE error_id, because channel,
// topic and promise each re-journaled the same stamped Error. Both now merge
// into the record already in the buffer (count + lastAt) instead of pushing a
// new one. The merged record keeps its `seq`, so the event shipper and the
// snackbar, which take each seq once, do not see it again.

/** A transport drop joins the open drop record while drops keep coming this close together. */
export const TRANSPORT_COALESCE_MS = 30_000

/** A fetch that never got an answer: the browser's TypeError, no HTTP status. */
function isTransportInput(input) {
  const err = input.error && typeof input.error === 'object' ? input.error : null
  return input.source === 'api' && !!err && err.name === 'TypeError' && !(Number(statusFrom(input)) > 0)
}

function isTransportRecord(r) {
  return r.source === 'api' && r.name === 'TypeError' && !r.status
}

/** The record this failure belongs to, merged; null when it is a new one. */
function mergeSameFailure(input, nowMs) {
  const lastAt = new Date(nowMs).toISOString()
  const bump = (r) => ({ ...r, count: (Number(r.count) || 1) + 1, lastAt })
  const known = extractErrorId(input)
  if (known) {
    const hit = mergeRecord((r) => r.errorId === known, bump)
    if (hit) return hit
  }
  if (!isTransportInput(input)) return null
  return mergeRecord((r) => isTransportRecord(r)
    && nowMs - Date.parse(String(r.lastAt || r.at)) <= TRANSPORT_COALESCE_MS, bump)
}

/**
 * Record one failure. No-op on the server. Never throws. Returns the stored
 * record (so a caller can quote its reference id) or null. A failure the
 * buffer already holds (same error id, or a transport drop within
 * TRANSPORT_COALESCE_MS of the last one) is merged into that record.
 *
 * @param {object} input see buildErrorRecord
 * @param {{ isClient?: boolean, now?: number }} [opts] `now`: ms, for tests
 * @returns {object | null}
 */
export function noteError(input, opts) {
  try {
    if (!isClient(opts)) return null
    if (!input || typeof input !== 'object') return null
    // A cancelled in-flight request (locale switch, navigation) is not a
    // failure — same rule the outage banner already applies.
    if (isAbortError(input.error)) return null
    const nowMs = opts && Number.isFinite(opts.now) ? Number(opts.now) : Date.now()
    const merged = mergeSameFailure(input, nowMs)
    const rec = merged || buildErrorRecord(input)
    if (!rec) return null
    // The UI shows what the journal recorded — one failure, one id.
    stampErrorId(input.error, rec.errorId)
    if (merged) return merged
    rec.count = 1
    rec.lastAt = new Date(nowMs).toISOString()
    pushRecord(rec)
    return rec
  } catch {
    // Capture must never become the thing that breaks the page.
    return null
  }
}
