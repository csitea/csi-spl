// Share targets for one public blog post.
// Plain URLs only: no third-party script and no tracker.
// Substack has no share URL, so blogShareHref returns null for it.
// That control copies the post URL and opens SUBSTACK_NOTES.
// Instagram has no share URL either: the row copies the caption and
// opens Instagram (spec 090 T037). Facebook, WhatsApp and Viber come from
// marketing-share-links.mjs, the hub's twin.

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
 * The share URL for one network, built from the post URL and its title.
 * Both are percent-encoded. `copy` and `substack` return null;
 * `instagram` is the page to open after the caption is copied.
 * @param {string} network
 * @param {{ url: string, title: string }} post
 * @returns {string | null}
 */
export function blogShareHref(network, post) {
  const url = encodeURIComponent(post.url)
  const title = encodeURIComponent(post.title)
  switch (network) {
    case 'linkedin':
      // share-offsite reads `url`. `title` is in the query so the link is
      // built from both; the card title still comes from the page.
      return `https://www.linkedin.com/sharing/share-offsite/?url=${url}&title=${title}`
    case 'facebook':
    case 'whatsapp':
    case 'viber':
      return marketingShareLinks(post)[network]
    case 'instagram':
      return INSTAGRAM_OPEN
    case 'x':
      return `https://x.com/intent/post?url=${url}&text=${title}`
    case 'telegram':
      return `https://t.me/share/url?url=${url}&text=${title}`
    case 'reddit':
      return `https://www.reddit.com/submit?url=${url}&title=${title}`
    case 'email':
      return `mailto:?subject=${title}&body=${url}`
    default:
      return null
  }
}
