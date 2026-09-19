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

// Relative, not the `@/` alias: this module is imported and EXECUTED directly
// by `node tests/unit/*.test.mjs`, which has no Vite resolver and no
// node_modules. A test that cannot import the real thing ends up asserting
// against a re-implementation of it.
import { isAbortError, statusFrom } from './apiHealth.mjs'

/** Ring-buffer cap. 50 × ≤2 KB ≈ 100 KB worst case, and it dies with the tab. */
export const ERROR_JOURNAL_LIMIT = 50
/** Longest message we keep. Long enough to diagnose, short enough to read. */
export const MAX_MESSAGE_CHARS = 800
/** Longest any other single field may be. */
export const MAX_FIELD_CHARS = 400
/** Longest one-line summary (the RUM sink caps `label` at 256 runes). */
export const MAX_SUMMARY_CHARS = 200

// ── redaction ──────────────────────────────────────────────────────────────
// Applied INSIDE the capture path, before a record enters the buffer.

/** Key names whose VALUE is never diagnostic and always dangerous. */
const SECRET_KEY = 'password|passwd|pwd|secret|client[_-]?secret|token|api[_-]?key|apikey|access[_-]?key|authorization|cookie|whsec|signature'

const RULES = [
  // scheme://user:pass@host — this is how a DSN leaks.
  [/([a-z][a-z0-9+.\-]*:\/\/)[^\s/@:]+:[^\s/@]*@/gi, '$1<redacted:credentials>@'],
  // JWT (header.payload.signature). Our own session cookie is HttpOnly, but a
  // third-party message can still carry one.
  [/\beyJ[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*/g, '<redacted:jwt>'],
  // Authorization-style prefixes.
  [/\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{8,}/gi, '$1 <redacted:token>'],
  // Publishable / secret keys of the sk_live_… shape.
  [/\b[a-z]{2,4}_(live|test)_[A-Za-z0-9]{8,}/gi, '<redacted:key>'],
  // key=value / "key": "value" for the dangerous key names.
  [new RegExp(`\\b(${SECRET_KEY})\\b(["']?\\s*[:=]\\s*["']?)[^\\s,;&"'}\\])]+`, 'gi'), '$1$2<redacted>'],
  // E-mail addresses are personal data (GDPR) and never needed to diagnose.
  [/\b[\w.+\-]+@[\w\-]+(?:\.[\w\-]+)+\b/g, '<redacted:email>'],
  // Card-shaped digit runs (13–19 digits, optionally spaced/dashed).
  [/\b\d(?:[ \-]?\d){12,18}\b/g, '<redacted:pan>'],
  // Private IPv4 literals only ever arrive here from a server-side message.
  [/\b(?:10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/g, '<redacted:ip>'],
  [/\b192\.168\.\d{1,3}\.\d{1,3}\b/g, '<redacted:ip>'],
  [/\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/g, '<redacted:ip>'],
  // Anything else long and opaque: session ids, signatures, base64 payloads.
  // `/` is in the class on purpose — standard base64 uses it, and a secret
  // must not survive by being chopped at a slash. In FREE TEXT that is right.
  // A URL PATH is a different shape and gets `redactPath` below; do not
  // "fix" this class for paths, it would cost real redaction in messages.
  [/\b[A-Za-z0-9+/_\-]{24,}={0,2}(?![A-Za-z0-9+/_\-])/g, '<redacted:blob>'],
]

/**
 * Scrub a free-text fragment. Never throws; a non-string becomes ''.
 * @param {unknown} input
 * @param {number} [max]
 * @returns {string}
 */
export function redactText(input, max = MAX_FIELD_CHARS) {
  let s
  try {
    if (input == null) return ''
    s = typeof input === 'string' ? input : String(input)
  } catch {
    return ''
  }
  try {
    for (const [re, to] of RULES) s = s.replace(re, to)
  } catch {
    return '<redacted>'
  }
  s = s.replace(/\s+/g, ' ').trim()
  return s.length > max ? s.slice(0, max - 1) + '…' : s
}

/**
 * Scrub a URL PATH — one segment at a time.
 *
 * Why not just `redactText` on the whole pathname: the blob rule collapses any
 * run of 24+ URL-safe characters, and `/` and `-` are both inside that class,
 * so the run does not stop at a segment boundary. `/v1/view/threads/<uuid>`
 * would collapse whole into `/<redacted:blob>` and no longer say which
 * endpoint had failed.
 *
 * The fix is to scrub segment by segment, because in a path `/` is STRUCTURE,
 * not payload. Every rule keeps its full reach inside a segment (an opaque id,
 * a UUID, a JWT, an e-mail, a card number and a private IP all live within one
 * segment), so what is still redacted after this change is:
 *
 *   * any single segment of 24+ opaque characters — a session id, a signature,
 *     a base64url token, a UUID. `-` stays in the class precisely so a UUID
 *     is caught; dropping it would recover a few more long kebab-case names
 *     and leak every UUID-shaped identifier, which is the wrong trade.
 *   * everything the other rules catch, unchanged.
 *
 * What is newly kept is a run that only got long by CROSSING slashes — i.e.
 * the route itself. A secret is not spread across path segments, so nothing
 * that was protected before is exposed now.
 *
 * The query string never reaches here: `redactUrl` drops it whole.
 *
 * @param {unknown} raw
 * @param {number} [max]
 * @returns {string}
 */
export function redactPath(raw, max = MAX_FIELD_CHARS) {
  let s
  try {
    if (raw == null) return ''
    s = typeof raw === 'string' ? raw : String(raw)
  } catch {
    return ''
  }
  if (!s) return ''
  let out
  try {
    // `max` per segment as well, so one absurd segment cannot be the reason a
    // later one is truncated away; the whole string is capped again below.
    out = s.split('/').map((seg) => redactText(seg, max)).join('/')
  } catch {
    return '<redacted>'
  }
  return out.length > max ? out.slice(0, max - 1) + '…' : out
}

/**
 * Split a URL into the two parts that are safe AND diagnostic: the origin
 * ("which host did this call actually go to" is frequently the whole answer)
 * and the pathname. The query string is DROPPED WHOLE — see the header.
 *
 * @param {unknown} raw
 * @returns {{ origin: string, path: string }}
 */
export function redactUrl(raw) {
  let s
  try {
    s = raw == null ? '' : String(raw)
  } catch {
    return { origin: '', path: '' }
  }
  if (!s) return { origin: '', path: '' }
  try {
    const base = typeof window !== 'undefined' && window.location
      ? window.location.origin
      : 'http://localhost'
    const u = new URL(s, base)
    // u.origin excludes username:password by construction.
    return {
      origin: redactText(u.origin, 120),
      path: redactPath(u.pathname, 200),
    }
  } catch {
    const cut = s.split('?')[0].split('#')[0]
    return { origin: '', path: redactPath(cut, 200) }
  }
}

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
    // afterwards — stamping it there (see noteFetchError) is what makes the
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

/**
 * Build one redacted record. Exported so the redaction table can be tested
 * directly, on any platform, without the client-only gate in the way.
 *
 * @param {{
 *   source?: unknown, method?: unknown, url?: unknown, status?: unknown,
 *   code?: unknown, message?: unknown, name?: unknown, route?: unknown,
 *   error?: unknown
 * }} [input]
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

  const { origin, path } = redactUrl(input.url)

  // The API's stable error envelope: { error: { code, message } }. `code` is a
  // enumerated identifier (error.email_taken, …) — that is the useful half.
  const envelope = err && err.data && typeof err.data === 'object' ? err.data.error : null
  const code = redactText(
    input.code ?? (envelope && typeof envelope === 'object' ? envelope.code : ''),
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
  }
}

// ── the buffer ─────────────────────────────────────────────────────────────

/** @type {object[]} */
let records = []
/** @type {Set<(r: object[]) => void>} */
const listeners = new Set()

function emit() {
  const snapshot = records.slice()
  for (const fn of listeners) {
    try { fn(snapshot) } catch { /* a bad subscriber must not break capture */ }
  }
}

function isClient(opts) {
  if (opts && Object.prototype.hasOwnProperty.call(opts, 'isClient')) {
    return !!opts.isClient
  }
  return typeof window !== 'undefined'
}

/**
 * Record one failure. No-op on the server. Never throws. Returns the stored
 * record (so a caller can quote its reference id) or null.
 *
 * @param {object} input see buildErrorRecord
 * @param {{ isClient?: boolean }} [opts]
 * @returns {object | null}
 */
export function noteError(input, opts) {
  try {
    if (!isClient(opts)) return null
    // A cancelled in-flight request (locale switch, navigation) is not a
    // failure — same rule the outage banner already applies.
    if (input && isAbortError(input.error)) return null
    const rec = buildErrorRecord(input)
    if (!rec) return null
    // The UI shows what the journal recorded — one failure, one id.
    stampErrorId(input && input.error, rec.errorId)
    records.push(rec)
    if (records.length > ERROR_JOURNAL_LIMIT) {
      records.splice(0, records.length - ERROR_JOURNAL_LIMIT)
    }
    emit()
    return rec
  } catch {
    // Capture must never become the thing that breaks the page.
    return null
  }
}

/**
 * ofetch hook adapter — `{ request, options, response, error }`, the same
 * context `reportApiFetchContext` receives. Only failures are recorded; a
 * successful response produces nothing.
 *
 * @param {object} ctx
 * @param {{ isClient?: boolean }} [opts]
 */
export function noteFetchError(ctx, opts) {
  try {
    const response = ctx && ctx.response
    const error = ctx && ctx.error
    const status = statusFrom({ response, error, status: response && response.status })
    // 4xx that are part of normal life (401 on /me for an anonymous visitor,
    // 404 for a product that moved) are still recorded: "what exactly went
    // wrong" is the whole point, and the panel is staff-only. Only a plain
    // success is skipped.
    if (typeof status === 'number' && status >= 200 && status < 400 && !error) return
    const rec = noteError({
      source: 'api',
      method: (ctx && ctx.options && ctx.options.method) || 'GET',
      url: (ctx && ctx.request) || '',
      status,
      error,
      // The response as well as the error: on a 4xx/5xx ofetch has not built
      // the FetchError yet, so `ctx.error` is undefined and the API's
      // `error.error_id` is reachable only through `ctx.response`. Nothing
      // reads this field except extractErrorId, and that returns an exact id
      // or nothing at all.
      response,
    }, opts)
    // Stamp the resolved id onto the RESPONSE, which is the one object ofetch
    // carries over to the FetchError it is about to throw. A component handed
    // that rejection then shows the id this record already holds.
    stampErrorId(response, rec && rec.errorId)
  } catch {
    /* never break the fetch pipeline */
  }
}

/** @returns {object[]} newest LAST (insertion order) */
export function getErrors() {
  return records.slice()
}

/** @returns {number} */
export function getErrorCount() {
  return records.length
}

/**
 * @param {(records: object[]) => void} fn
 * @returns {() => void} unsubscribe
 */
export function subscribeErrors(fn) {
  listeners.add(fn)
  return () => { listeners.delete(fn) }
}

/** Empty the buffer for this tab (the panel's Clear control). */
export function clearErrors() {
  if (!records.length) return
  records = []
  emit()
}

/** Test helper — the production UI never calls this. */
export function resetErrorJournal() {
  records = []
  emit()
}

// ── origin scoping ─────────────────────────────────────────────────────────
//
// Why this section exists: the buffer is per TAB and survives navigation, on
// purpose — an error recorded during a navigation that then redirects must
// still be readable on the page you land on. The cost of that, unaddressed, is
// that the panel replays a record from a page you left minutes ago as though
// this page were broken — one incident, reported twice from two pages.
//
// So NOTHING here drops, clears or hides a record. These are pure predicates
// the panel uses to SAY where and when a record came from. Every one of them
// is a plain function over a record array, so the unit suite can execute it
// under bare `node`, with no browser and no Vue.

/**
 * How recent a record has to be for the panel to treat it as "part of the
 * navigation that is happening right now".
 *
 * It exists for exactly one case: an error captured while leaving page A, on a
 * navigation that redirects, is attributed to A and lands the reader on B. The
 * panel must not tidy that away before it can be read. 15 s is longer than any
 * navigation on this site and shorter than the "I walked away and came back"
 * gap the scoping is for; when it is wrong it is wrong in the direction of
 * showing MORE, which is the only safe direction for a diagnostics panel.
 */
export const RECENT_ERROR_MS = 15000

/**
 * Comparable form of a route path: redacted the same way a captured route is
 * (so a raw `useRoute().path` and a stored `record.route` end up the same
 * shape), with a trailing slash removed.
 *
 * @param {unknown} raw
 * @returns {string}
 */
export function normaliseRoute(raw) {
  const s = redactPath(raw, 200)
  if (!s) return ''
  return s.length > 1 ? s.replace(/\/+$/, '') : s
}

/**
 * True when two route paths are the same page. An empty route never matches —
 * "we do not know where this came from" must not be read as "it came from
 * here".
 *
 * @param {unknown} a
 * @param {unknown} b
 * @returns {boolean}
 */
export function isSameRoute(a, b) {
  const x = normaliseRoute(a)
  return !!x && x === normaliseRoute(b)
}

/**
 * Split the buffer into "recorded on the page you are looking at" and
 * "recorded elsewhere in this session". Both halves keep insertion order and
 * together they hold every record — this is a grouping, never a filter.
 *
 * @param {object[]} records
 * @param {unknown} currentRoute
 * @returns {{ here: object[], elsewhere: object[] }}
 */
export function groupByOrigin(records, currentRoute) {
  const here = []
  const elsewhere = []
  for (const r of Array.isArray(records) ? records : []) {
    if (isSameRoute(r && r.route, currentRoute)) here.push(r)
    else elsewhere.push(r)
  }
  return { here, elsewhere }
}

/**
 * The age of a record as Intl.RelativeTimeFormat arguments, so every locale
 * is served by the platform rather than by hand-written strings per unit.
 * Truncates rather than rounds: 90 s reads "1 minute ago", never "2".
 *
 * @param {unknown} at ISO timestamp
 * @param {number} [nowMs]
 * @returns {{ value: number, unit: 'second'|'minute'|'hour'|'day' } | null}
 */
export function ageParts(at, nowMs) {
  let t
  try {
    t = Date.parse(String(at == null ? '' : at))
  } catch {
    return null
  }
  if (!Number.isFinite(t)) return null
  const now = Number.isFinite(nowMs) ? nowMs : Date.now()
  // A record "from the future" means the clock moved, not that we time-
  // travelled. Clamp, instead of rendering "in 3 hours" next to an HTTP 403.
  const secs = Math.max(0, Math.floor((now - t) / 1000))
  if (secs < 60) return { value: -secs, unit: 'second' }
  if (secs < 3600) return { value: -Math.floor(secs / 60), unit: 'minute' }
  if (secs < 86400) return { value: -Math.floor(secs / 3600), unit: 'hour' }
  return { value: -Math.floor(secs / 86400), unit: 'day' }
}

/**
 * Should the panel fall back to its collapsed one-line state now that the
 * reader has navigated to `currentRoute`?
 *
 * This is the ONLY behaviour change navigation causes, and it is deliberately
 * the mildest one available: the records stay in the buffer, the count stays
 * on screen, and one click reopens the list. It answers "stop shouting about
 * another page's failure" without answering "throw the failure away".
 *
 * It says no — keep the panel open — whenever ANY of these hold:
 *   * the buffer is empty (there is nothing to collapse away from);
 *   * a record was recorded on this very route;
 *   * a record is younger than RECENT_ERROR_MS, i.e. it belongs to the
 *     navigation that just happened — the redirect case;
 *   * a record has no readable timestamp, so its age cannot be ruled out.
 *
 * @param {object[]} records
 * @param {unknown} currentRoute
 * @param {number} [nowMs]
 * @param {number} [recentMs]
 * @returns {boolean}
 */
export function shouldCollapseOnRouteChange(records, currentRoute, nowMs, recentMs) {
  const list = Array.isArray(records) ? records : []
  if (!list.length) return false
  const now = Number.isFinite(nowMs) ? nowMs : Date.now()
  const fresh = Number.isFinite(recentMs) ? recentMs : RECENT_ERROR_MS
  for (const r of list) {
    if (isSameRoute(r && r.route, currentRoute)) return false
    const t = Date.parse(String((r && r.at) || ''))
    if (!Number.isFinite(t) || now - t < fresh) return false
  }
  return true
}

// ── presentation helpers (pure, so they are testable without a browser) ────

/**
 * One bounded line: what the beacon sends and what a person reads aloud.
 * @param {object} rec
 * @returns {string}
 */
export function summariseRecord(rec) {
  if (!rec || typeof rec !== 'object') return ''
  const parts = [
    // FIRST, deliberately. This line is what the `client_error` RUM beacon
    // sends as `label` and what the panel prints, and both are capped by
    // slicing the TAIL — so the one field an operator needs to join this to
    // a server log line must never be the field that falls off the end.
    rec.errorId || '',
    rec.method || '',
    rec.path || rec.origin || '',
    rec.status ? String(rec.status) : (rec.name || ''),
    rec.code || '',
    rec.ref ? `(${rec.ref})` : '',
  ].filter(Boolean)
  const line = parts.join(' ')
  return line.length > MAX_SUMMARY_CHARS ? line.slice(0, MAX_SUMMARY_CHARS - 1) + '…' : line
}

/**
 * The clipboard payload. Already-redacted fields only — this cannot widen what
 * the panel shows, because it reads the same records.
 *
 * `ctx.page` names the route the panel was READ on. Without it a pasted block
 * of records is ambiguous: every
 * record already carries the route it was recorded on, but nothing said which
 * of them was the page the reader was actually looking at.
 *
 * @param {object[]} recs
 * @param {{ version?: string, env?: string, page?: string }} [ctx]
 * @returns {string}
 */
export function formatRecords(recs, ctx) {
  const head = [
    `spool WUI diagnostics`,
    ctx && ctx.version ? `version ${ctx.version}` : '',
    ctx && ctx.env ? `env ${ctx.env}` : '',
    ctx && ctx.page ? `read on ${normaliseRoute(ctx.page)}` : '',
  ].filter(Boolean).join(' · ')
  const body = (Array.isArray(recs) ? recs : []).map((r) => {
    const lines = [`${r.at} ${summariseRecord(r)}`]
    if (r.origin) lines.push(`  origin: ${r.origin}`)
    if (r.source) lines.push(`  source: ${r.source}`)
    if (r.route) lines.push(`  route:  ${r.route}`)
    if (r.message) lines.push(`  detail: ${r.message}`)
    return lines.join('\n')
  }).join('\n')
  return body ? `${head}\n${body}` : head
}
