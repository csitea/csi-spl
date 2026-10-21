// csi-spl-wui/src/utils/error-journal-format.mjs
//
// The pure text half of the error journal (composables/errorJournal.mjs):
// the redaction table applied on capture, the origin-scoping predicates the
// DebugPanel groups by, and the one-line summary and clipboard formatters.
// No state, no Vue, no DOM write, no network; nothing here throws.
//
// Relative imports only: `node tests/unit/*.test.mjs` executes this module
// with no Vite resolver (see the note in composables/errorJournal.mjs).
import { displayVersion } from './display-version.mjs'

/** Longest any other single field may be. */
const MAX_FIELD_CHARS = 400
/** Longest one-line summary (the RUM sink caps `label` at 256 runes). */
const MAX_SUMMARY_CHARS = 200

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
 * so the run does not stop at a segment boundary. `/v1/view/topics/<uuid>`
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
const RECENT_ERROR_MS = 15000

/**
 * Comparable form of a route path: redacted the same way a captured route is
 * (so a raw `useRoute().path` and a stored `record.route` end up the same
 * shape), with a trailing slash removed.
 *
 * @param {unknown} raw
 * @returns {string}
 */
function normaliseRoute(raw) {
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
function isSameRoute(a, b) {
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
    ctx && ctx.version ? `version ${displayVersion(ctx.version)}` : '',
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
