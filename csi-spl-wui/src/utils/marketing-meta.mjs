/**
 * Spec 090 T035 (SPL-4494): the connected Facebook Pages and Instagram
 * accounts of a workspace, and the text a Meta publish sends. Pure helpers
 * for MarketingAccounts.vue and MarketingPublish.vue; the hub half is
 * internal/hub/marketing_meta_channels.go (T033) and marketing_meta_dispatch.go
 * (T034). Imported only by those lazy components: never from the first screen.
 */

/** The platforms' text caps (marketing/meta_publish.go). */
export const META_LIMITS = Object.freeze({ facebook_page: 63206, instagram_business: 2200 })

/** The Page tasks that let the connecting member post on it (Meta's Page roles). */
const META_POST_TASKS = Object.freeze(['MANAGE', 'CREATE_CONTENT'])

/** The blog post's address on the app origin (marketing.BlogPostURL). */
export function blogPostUrl(appUrl, id) {
  return String(appUrl || '').replace(/\/+$/, '') + '/blog/' + encodeURIComponent(String(id || ''))
}

/** The length Meta counts: characters (code points), not UTF-16 units. */
export function metaCharCount(text) {
  return [...String(text || '')].length
}

/** A count with its thousands grouped by a narrow no-break space (2 200), the same in every locale. */
export function metaNumber(n) {
  return String(Math.trunc(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, '\u202f')
}

/**
 * The text the hub sends for post p on platform (hub metaCaption): the title,
 * then the summary; Instagram, which links nothing, adds the post's address.
 * over = longer than the cap, so the hub shortens the summary to fit.
 */
export function metaCaption(platform, p, appUrl) {
  const head = String(p?.title || '').trim()
  const summary = String(p?.summary || '').trim()
  const tail = platform === 'instagram_business' ? '\n\n' + blogPostUrl(appUrl, p?.id) : ''
  const text = head + (summary ? '\n\n' + summary : '') + tail
  const limit = META_LIMITS[platform] || META_LIMITS.facebook_page
  const count = metaCharCount(text)
  return { text, count, limit, over: count > limit }
}

/** Instagram takes only a JPEG picture (T034: 422 instagram_needs_jpeg). */
export function metaNeedsJpeg(platform, image) {
  if (platform !== 'instagram_business') return false
  const path = String(image || '').split(/[?#]/)[0]
  return !/\.jpe?g$/i.test(path)
}

/** Can the member who connected a Page post on it? Unknown tasks = yes (the hub decides). */
export function metaPageCanPost(tasks) {
  if (!Array.isArray(tasks)) return true
  return tasks.some((x) => META_POST_TASKS.includes(String(x).toUpperCase()))
}

/** Up to two initials of an account name, for its avatar. */
export function metaInitials(name) {
  const words = String(name || '').replace(/^@/, '').split(/[\s._-]+/).filter(Boolean)
  const s = words.slice(0, 2).map((w) => [...w][0] || '').join('')
  return (s || '?').toUpperCase()
}

/** One Page's rows: the Page, then its Instagram account (which posts with the Page's token). */
function pageRows(p, tasks) {
  const canPost = metaPageCanPost(tasks)
  const rows = [{ id: p.channel_id, platform: 'facebook_page', name: String(p.name || p.page_id || ''), status: String(p.status || ''), canPost, linked: '' }]
  const ig = p.instagram
  if (ig && typeof ig.channel_id === 'string') {
    rows.push({ id: ig.channel_id, platform: 'instagram_business', name: '@' + String(ig.username || ig.ig_user_id || ''),
      status: String(ig.status || ''), canPost, linked: p.channel_id })
  }
  return rows
}

/**
 * The account rows: each connected Page, then its Instagram account, from
 * GET /v1/marketing/facebook/pages; a Page's tasks come from GET
 * /v1/marketing/channels (metadata.tasks), keyed by channel id.
 */
export function metaAccountRows(pages, channels) {
  const tasksOf = new Map()
  for (const c of Array.isArray(channels) ? channels : []) {
    if (c && c.channel_id && Array.isArray(c.metadata?.tasks)) tasksOf.set(c.channel_id, c.metadata.tasks)
  }
  return (Array.isArray(pages) ? pages : [])
    .filter((p) => p && typeof p.channel_id === 'string')
    .flatMap((p) => pageRows(p, tasksOf.get(p.channel_id)))
}

/** The rows left after channel id is disconnected: a Page takes its Instagram account with it. */
export function metaRowsWithout(rows, id) {
  return (Array.isArray(rows) ? rows : []).filter((r) => r.id !== id && r.linked !== id)
}

/** What the section shows for a failed accounts read: 503 = not configured, 404/403 = hidden (the switch says why). */
export function metaLoadView(err) {
  const status = err && typeof err === 'object' ? err.status : 0
  if (status === 503) return 'not_configured'
  if (status === 404 || status === 403) return 'hidden'
  return 'failed'
}

/** The i18n key (under tenant_settings.) for a refused Meta publish. */
export function metaPublishErrorKey(err) {
  const status = err && typeof err === 'object' ? err.status : 0
  if (status === 422) return 'marketing_meta_needs_jpeg'
  if (status === 409) return 'marketing_meta_conflict'
  if (status === 403) return 'marketing_meta_forbidden'
  if (status === 503) return 'marketing_meta_not_configured'
  return 'marketing_publish_failed'
}

/**
 * The hub's DELETE /v1/marketing/channels/{id} (SPL-4496, e8e02f87e) and its
 * OPTIONS preflight are served on dev and prd: the live client offers
 * Disconnect too (SPL-4520). False takes it back to the mock only.
 */
export const META_DISCONNECT_LIVE = true

/** Does this client offer Disconnect? */
export function metaCanDisconnect(isMock) {
  return Boolean(isMock) || META_DISCONNECT_LIVE
}
