/**
 * spec 090 section 22 (SPL-5240): the pure part of the Posts section
 * (MarketingPostEditor.vue): the channel labels, which channels a draft can
 * still go to, and the catalogue key of every answer the hub gives. Node
 * tests import it directly (tests/unit/marketing-drafts.test.mjs).
 */

/** The platforms' own names: brands, the same in every language. */
export const DRAFT_PLATFORMS = { linkedin: 'LinkedIn', facebook_page: 'Facebook', instagram_business: 'Instagram', x: 'X' }

/** The hub's cap on a draft's text (rdb 0273, LinkedIn's 3,000). */
export const DRAFT_MAX_CHARS = 3000

/** "LinkedIn · FirstName LastName" for a channel { platform, name }. */
export function draftChannelLabel(ch) {
  const brand = DRAFT_PLATFORMS[ch?.platform] || String(ch?.platform || '')
  return ch?.name ? `${brand} · ${ch.name}` : brand
}

/** The text's length as the hub counts it (code points). */
export function draftChars(body) {
  return [...String(body ?? '')].length
}

/** The channels the draft has not gone to yet. */
export function draftOpenChannels(draft, channels) {
  const sent = new Set((draft?.posts || []).map((p) => p.channel_id))
  return (Array.isArray(channels) ? channels : []).filter((c) => !sent.has(c.channel_id))
}

const OUTCOMES = new Set(['published', 'deferred', 'retried', 'failed', 'scheduled'])
const WHY = new Set(['already_recorded', 'instagram_needs_jpeg', 'instagram_too_long', 'x_too_long', 'not_configured', 'not_found'])

/** The key of one publish result: tenant_settings.posts_result_<outcome>, or a refusal's reason. */
export function draftResultKey(r) {
  if (r?.outcome === 'refused') return 'tenant_settings.posts_why_' + (WHY.has(r.error) ? r.error : 'internal')
  return 'tenant_settings.posts_result_' + (OUTCOMES.has(r?.outcome) ? r.outcome : 'failed')
}

/** The key of a post's state on a channel, from its marketing_posts status. */
export function draftStateKey(status) {
  if (status === 'published') return 'tenant_settings.posts_result_published'
  if (status === 'failed') return 'tenant_settings.posts_result_failed'
  return 'tenant_settings.posts_result_scheduled'
}

/** The key of a refused save, delete or publish, by the hub's status. */
export function draftErrorKey(e) {
  const status = e?.status
  if (status === 403) return 'tenant_settings.posts_not_author'
  if (status === 409) return 'tenant_settings.posts_locked'
  if (status === 400) return 'tenant_settings.posts_bad_input'
  return 'tenant_settings.posts_failed'
}
