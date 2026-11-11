/**
 * Spec 090 phase 4, T041 (SPL-5258): the LinkedIn Company Pages of a
 * workspace and the post a Company Page publish sends. Pure helpers for
 * MarketingLinkedInPages.vue and MarketingPublish.vue; the hub half is
 * internal/marketing/linkedin_org.go and internal/hub/marketing_linkedin_org_*.go.
 * Imported only by those lazy components: never from the first screen.
 */
import { blogPostUrl } from './marketing-meta.mjs'

/** LinkedIn's commentary limit of a post, in characters. */
export const LI_COMMENTARY_MAX = 3000

/**
 * The commentary the hub sends for blog post p (marketing.BlogArticle): the
 * title, the summary and the link, each after its emoji. The article card
 * under it carries the title, the summary and the picture.
 */
export function liPageCaption(p, appUrl) {
  const text = '\u{1F4DD} ' + String(p?.title || '').trim() + '\n\n\u{1F4A1} ' + String(p?.summary || '').trim() +
    '\n\n\u{1F449} ' + blogPostUrl(appUrl, p?.id)
  const count = [...text].length
  return { text, count, limit: LI_COMMENTARY_MAX, over: count > LI_COMMENTARY_MAX }
}

/** The Company Page's public address, or '' without a vanity name. */
export function liPageUrl(vanity) {
  const v = String(vanity || '').trim()
  return v ? 'https://www.linkedin.com/company/' + encodeURIComponent(v) : ''
}

/** The rows of GET /v1/marketing/linkedin-org/pages. */
export function liPageRows(pages) {
  return (Array.isArray(pages) ? pages : [])
    .filter((p) => p && typeof p.channel_id === 'string')
    .map((p) => ({
      id: p.channel_id,
      platform: 'linkedin_page',
      name: String(p.name || p.organization_id || ''),
      url: liPageUrl(p.vanity_name),
      status: String(p.status || ''),
      expiresAt: typeof p.expires_at === 'string' ? p.expires_at.slice(0, 10) : '',
    }))
}

/** What the Company Page section shows for a failed read: 503 = not configured, 404/403 = hidden. */
export function liPageLoadView(err) {
  const status = err && typeof err === 'object' ? err.status : 0
  if (status === 503) return 'not_configured'
  if (status === 404 || status === 403) return 'hidden'
  return 'failed'
}

/** The i18n key (under tenant_settings.) for a refused Company Page publish. */
export function liPagePublishErrorKey(err) {
  const status = err && typeof err === 'object' ? err.status : 0
  if (status === 409) return 'marketing_meta_conflict'
  if (status === 403) return 'marketing_li_page_forbidden'
  if (status === 503) return 'marketing_li_page_not_configured'
  return 'marketing_publish_failed'
}
