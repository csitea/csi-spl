/**
 * Spec 090 X row (SPL-5194): the connected X accounts of a workspace and the
 * post an X publish sends. Pure helpers for MarketingXAccounts.vue and
 * MarketingPublish.vue; the hub half is internal/marketing/x.go (XPostText,
 * XWeightedLength) and internal/hub/marketing_x_*.go. Imported only by those
 * lazy components: never from the first screen.
 */
import { blogPostUrl } from './marketing-meta.mjs'

/** X's length limit and a link's weight (marketing/x.go XPostMaxWeight, XURLWeight). */
export const X_POST_MAX = 280
export const X_URL_WEIGHT = 23

// characters in these ranges weigh 1, every other 2 (X's counting)
const X_LIGHT = [[0, 4351], [8192, 8205], [8208, 8223], [8242, 8247]]

function xRuneWeight(cp) {
  return X_LIGHT.some(([a, b]) => cp >= a && cp <= b) ? 1 : 2
}

const ELLIPSIS = '…'
const ELLIPSIS_WEIGHT = xRuneWeight(ELLIPSIS.codePointAt(0))

/** The length X counts: a whitespace-separated http(s) link is 23, a heavy character 2. */
export function xWeightedLength(text) {
  const s = String(text || '')
  let n = 0
  let i = 0
  while (i < s.length) {
    if (s.startsWith('https://', i) || s.startsWith('http://', i)) {
      const m = /[ \t\n\r]/.exec(s.slice(i))
      n += X_URL_WEIGHT
      i = m ? i + m.index : s.length
      continue
    }
    const cp = s.codePointAt(i)
    n += xRuneWeight(cp)
    i += cp > 0xffff ? 2 : 1
  }
  return n
}

/** The longest prefix of s that weighs at most room, trailing space cut ('' when only space fits). */
function xFit(s, room) {
  let n = 0
  let out = ''
  for (const ch of s) {
    const w = xRuneWeight(ch.codePointAt(0))
    if (n + w > room) break
    n += w
    out += ch
  }
  out = out.replace(/[ \t\n]+$/, '')
  return out.trim() ? out : ''
}

/**
 * The post the hub sends for blog post p (marketing.XPostText): the title,
 * the summary, the link, the summary (else the title) shortened with "…" to
 * fit 280. over = the full text did not fit, so it was shortened.
 */
export function xPostText(p, appUrl) {
  const head = String(p?.title || '').trim()
  const tail = '\n\n' + blogPostUrl(appUrl, p?.id)
  let summary = String(p?.summary || '').trim()
  if (summary) summary = '\n\n' + summary
  let text = head + summary + tail
  const over = xWeightedLength(text) > X_POST_MAX
  if (over) {
    const s = xFit(summary, X_POST_MAX - xWeightedLength(head + tail) - ELLIPSIS_WEIGHT)
    if (s) text = head + s + ELLIPSIS + tail
    else if (xWeightedLength(head + tail) > X_POST_MAX) text = xFit(head, X_POST_MAX - xWeightedLength(tail) - ELLIPSIS_WEIGHT) + ELLIPSIS + tail
    else text = head + ELLIPSIS + tail
  }
  return { text, count: xWeightedLength(text), limit: X_POST_MAX, over }
}

/** The account rows of GET /v1/marketing/x/accounts. */
export function xAccountRows(accounts) {
  return (Array.isArray(accounts) ? accounts : [])
    .filter((a) => a && typeof a.channel_id === 'string')
    .map((a) => ({ id: a.channel_id, platform: 'x', name: a.username ? '@' + String(a.username) : String(a.name || a.user_id || ''), status: String(a.status || '') }))
}

/** What the X section shows for a failed accounts read: 503 = not configured, 404/403 = hidden. */
export function xLoadView(err) {
  const status = err && typeof err === 'object' ? err.status : 0
  if (status === 503) return 'not_configured'
  if (status === 404 || status === 403) return 'hidden'
  return 'failed'
}

/** The i18n key (under tenant_settings.) for a refused X publish. */
export function xPublishErrorKey(err) {
  const status = err && typeof err === 'object' ? err.status : 0
  if (status === 422) return 'marketing_x_too_long'
  if (status === 409) return 'marketing_meta_conflict'
  if (status === 403) return 'marketing_x_forbidden'
  if (status === 503) return 'marketing_x_not_configured'
  return 'marketing_publish_failed'
}
