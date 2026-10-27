// One-click share links for Facebook, Viber, WhatsApp and Instagram
// (spec 090 T037, SPL-3872). The hub builds the same links in
// internal/hub/marketing_share_links.go for
// GET /v1/marketing/posts/{id}/share-links; both encode alike, so the
// public blog row and the hub agree.
// Plain URLs only: no third-party script and no tracker.

/** The Viber client's limit on a forwarded text, in characters. */
export const VIBER_MAX_TEXT = 200

/** Instagram has no web share intent: copy the caption, then open it. */
export const INSTAGRAM_OPEN = 'https://www.instagram.com/'

/**
 * encodeURIComponent, plus ! ' ( ) *: every byte but A-Z a-z 0-9 - . _ ~
 * is %XX, a space included (RFC 3986; Go's url.QueryEscape with %20).
 * @param {string} s
 * @returns {string}
 */
export function shareEscape(s) {
  return encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
}

/**
 * "<headline> <link>" in at most VIBER_MAX_TEXT characters (code points):
 * the headline is shortened and ends in an ellipsis, the link is never cut.
 * @param {string} title
 * @param {string} link
 * @returns {string}
 */
export function viberText(title, link) {
  const head = String(title || '').trim()
  const linkLen = Array.from(link).length
  if (Array.from(head).length + 1 + linkLen <= VIBER_MAX_TEXT) return `${head} ${link}`
  const room = VIBER_MAX_TEXT - linkLen - 2
  if (room <= 0) return link
  return `${Array.from(head).slice(0, room).join('').trim()}… ${link}`
}

/**
 * The Instagram caption: the headline, the summary when there is one, the link.
 * @param {{ url: string, title: string, summary?: string }} post
 * @returns {string}
 */
export function instagramCaption(post) {
  const parts = [String(post.title || '').trim()]
  const summary = String(post.summary || '').trim()
  if (summary) parts.push(summary)
  parts.push(post.url)
  return parts.join('\n\n')
}

/**
 * The four apps' links for one post. `url` is the post's public page.
 * @param {{ url: string, title: string, summary?: string, images?: string[] }} post
 */
export function marketingShareLinks(post) {
  const title = String(post.title || '').trim()
  return {
    facebook: `https://www.facebook.com/sharer/sharer.php?u=${shareEscape(post.url)}`,
    viber: `viber://forward?text=${shareEscape(viberText(title, post.url))}`,
    whatsapp: `https://wa.me/?text=${shareEscape(`${title} ${post.url}`)}`,
    instagram: { caption: instagramCaption(post), images: post.images || [], open: INSTAGRAM_OPEN },
  }
}
