// Share targets for one public blog post (spec 111 share row, spec 090 T043).
// Plain URLs only: no third-party script and no tracker.
//
// Two texts per post (spec 090 section 23): the short teaser (`share_text`
// front matter, else its summary, else its title) for X, Reddit and Viber,
// whose limits it fits, and the long share text (`share_long`: a hook, the
// key points each led by an emoji, a call to read the post; else the
// teaser) for the others: BLOG_SHARE_LONG_TARGETS. The post link is always
// added last, never written in the front matter. Where the platform takes
// no text in its share URL (Facebook, Instagram, Substack) or where the
// text survives only for a signed-in member (LinkedIn), the click also
// copies "<long text>\n\n<link>" and the row shows a "paste it" hint:
// BLOG_SHARE_COPY_TARGETS, spec 090 T043. Facebook, WhatsApp and Viber
// come from marketing-share-links.mjs, the hub's twin.

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
 * The targets that share the long text (`share_long`). X (280), Reddit (a
 * title) and Viber (200, VIBER_MAX_TEXT) keep the short teaser.
 */
export const BLOG_SHARE_LONG_TARGETS = ['linkedin', 'facebook', 'instagram', 'substack', 'whatsapp', 'telegram', 'email']

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
 * The long share text: share_long, else the teaser (share_text, summary, title).
 * @param {{ title?: string, summary?: string, shareText?: string, shareLong?: string }} post
 * @returns {string}
 */
export function shareLongText(post) {
  const long = String(post.shareLong || '').trim()
  return long || shareTeaser(post)
}

/**
 * What a copy target puts on the clipboard: the long text, a blank line, the link.
 * @param {{ url: string, title?: string, summary?: string, shareText?: string, shareLong?: string }} post
 * @returns {string}
 */
export function shareCopyText(post) {
  const text = shareLongText(post)
  return text ? `${text}\n\n${post.url}` : post.url
}

/**
 * The share URL for one network: the post URL and its text (the long text
 * on BLOG_SHARE_LONG_TARGETS, else the teaser), percent-encoded. `copy` and
 * `substack` return null; `instagram` is the page to open after the text
 * is copied.
 * @param {string} network
 * @param {{ url: string, title: string, summary?: string, shareText?: string, shareLong?: string }} post
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
      return `https://www.linkedin.com/feed/?shareActive=true&text=${encodeURIComponent(shareCopyText(post))}`
    case 'facebook':
    case 'whatsapp':
      return marketingShareLinks({ url: post.url, title: shareLongText(post) })[network]
    case 'viber':
      return marketingShareLinks({ url: post.url, title: teaser }).viber
    case 'instagram':
      return INSTAGRAM_OPEN
    case 'x':
      return `https://x.com/intent/post?url=${url}&text=${text}`
    case 'telegram':
      return `https://t.me/share/url?url=${url}&text=${encodeURIComponent(shareLongText(post))}`
    case 'reddit':
      return `https://www.reddit.com/submit?url=${url}&title=${text}`
    case 'email':
      return `mailto:?subject=${encodeURIComponent(String(post.title || teaser))}&body=${encodeURIComponent(shareCopyText(post))}`
    default:
      return null
  }
}
