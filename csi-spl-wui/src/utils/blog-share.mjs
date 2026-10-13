// Share targets for one public blog post.
// Plain URLs only: no third-party script and no tracker.
// Substack has no share URL, so blogShareHref returns null for it.
// That control copies the post URL and opens SUBSTACK_NOTES.

export const SUBSTACK_NOTES = 'https://substack.com/notes'

/** Copy link first, then the named sites, e-mail last. */
export const BLOG_SHARE_ORDER = [
  'copy',
  'linkedin',
  'facebook',
  'x',
  'whatsapp',
  'telegram',
  'reddit',
  'substack',
  'email',
]

/**
 * The share URL for one network, built from the post URL and its title.
 * Both are percent-encoded. `copy` and `substack` return null.
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
      return `https://www.facebook.com/sharer/sharer.php?u=${url}&quote=${title}`
    case 'x':
      return `https://x.com/intent/post?url=${url}&text=${title}`
    case 'whatsapp':
      return `https://wa.me/?text=${encodeURIComponent(`${post.title} ${post.url}`)}`
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
