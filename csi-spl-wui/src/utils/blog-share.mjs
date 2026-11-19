// Share targets for one public blog post (spec 111 share row, spec 090 T043).
// Plain URLs only: no third-party script and no tracker.
//
// Each target opens with the post's teaser (`share_text` front matter, else
// its summary, else its title) and the post link pre-filled where the
// platform takes text in its share URL. Where it does not (Facebook,
// Instagram, Substack) or where the text survives only for a signed-in
// member (LinkedIn), the click also copies "<teaser>\n\n<link>" and the row
// shows a "paste it" hint: BLOG_SHARE_COPY_TARGETS, spec 090 T043.
// Facebook, WhatsApp and Viber come from marketing-share-links.mjs, the
// hub's twin, with the teaser as their headline.

import { INSTAGRAM_OPEN, marketingShareLinks } from './marketing-share-links.mjs'

export const SUBSTACK_NOTES = 'https://substack.com/notes'

/** Copy link first, then the named sites, e-mail last. */
export const BLOG_SHARE_ORDER = [
  'copy',
  'linkedin',
  'facebook',
  'instagram',
  'x',
  'whatsapp',
  'viber',
  'telegram',
  'reddit',
  'substack',
  'email',
]

/**
 * The targets whose click copies the teaser and the link, then opens the
 * site: no share URL takes text there (or not for every visitor).
 */
export const BLOG_SHARE_COPY_TARGETS = ['linkedin', 'facebook', 'instagram', 'substack']

/**
 * The stable DOM id of one share control (spec 090 T043): the contract an
 * automation clicks. `row` is `top` or `end`; `copy` and `native` too.
 * @param {string} target
 * @param {string} row
 * @returns {string}
 */
export function blogShareId(target, row) {
  return `blog-share-${target}-${row}`
}

/**
 * The teaser the share row pre-fills: share_text, else summary, else title.
 * @param {{ title?: string, summary?: string, shareText?: string }} post
 * @returns {string}
 */
export function shareTeaser(post) {
  for (const v of [post.shareText, post.summary, post.title]) {
    const s = String(v || '').trim()
    if (s) return s
  }
  return ''
}

/**
 * What a copy target puts on the clipboard: the teaser, a blank line, the link.
 * @param {{ url: string, title?: string, summary?: string, shareText?: string }} post
 * @returns {string}
 */
export function shareCopyText(post) {
  const teaser = shareTeaser(post)
  return teaser ? `${teaser}\n\n${post.url}` : post.url
}

/**
 * The share URL for one network: the post URL and its teaser, both
 * percent-encoded. `copy` and `substack` return null; `instagram` is the
 * page to open after the text is copied.
 * @param {string} network
 * @param {{ url: string, title: string, summary?: string, shareText?: string }} post
 * @returns {string | null}
 */
export function blogShareHref(network, post) {
  const url = encodeURIComponent(post.url)
  const teaser = shareTeaser(post)
  const text = encodeURIComponent(teaser)
  switch (network) {
    case 'linkedin':
      // share-offsite drops every text param; the feed composer takes
      // `text` (kept through the sign-in redirect, spec 090 T043).
      return `https://www.linkedin.com/feed/?shareActive=true&text=${encodeURIComponent(`${teaser} ${post.url}`)}`
    case 'facebook':
    case 'whatsapp':
    case 'viber':
      return marketingShareLinks({ url: post.url, title: teaser })[network]
    case 'instagram':
      return INSTAGRAM_OPEN
    case 'x':
      return `https://x.com/intent/post?url=${url}&text=${text}`
    case 'telegram':
      return `https://t.me/share/url?url=${url}&text=${text}`
    case 'reddit':
      return `https://www.reddit.com/submit?url=${url}&title=${text}`
    case 'email':
      return `mailto:?subject=${encodeURIComponent(String(post.title || teaser))}&body=${encodeURIComponent(shareCopyText(post))}`
    default:
      return null
  }
}
