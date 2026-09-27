import { openParentSection } from './parent-section-open.mjs'

/**
 * 022 §10 (CLE-35063): what "Open original" does for a posted hit (a message,
 * a topic, a file). Loaded only when a row is opened: pages/search.vue
 * imports this file dynamically.
 *
 * 1. The place the hit was posted in, by the one Open parent section rule
 *    (utils/parent-section-open.mjs): its channel or DM with the topic open on
 *    the right and #<msg_id>, or the Issues tab with the issue selected.
 * 2. A row that cannot name that place (a DM topic carries no peer, a file the
 *    reader sent names only the reader) opens its topic page, /t/<task>#<msg>.
 * 3. FR-052: the hit is marked where it now shows. The thread pane's hash rule
 *    (LiveFeed) moves the line to the top and focuses it; this adds the
 *    search-focus flash on every copy of that message on screen.
 *
 * search-results.mjs stays out of this file (its static importer is the
 * search page only, tests/unit/search.test.mjs), so the caller hands over the
 * fallback page (search-results.mjs topicPageOf).
 *
 * @param {Record<string, any>} row a posted search row (search-results.mjs isPlacedRow)
 * @param {{ self: string, api: any, router: any, localePath: (p: string) => string, fallback: string }} deps
 * @returns {Promise<boolean>} false when the row names no place and no topic
 */
export async function openOriginal(row, deps) {
  const { router, localePath } = deps
  const msg = row.type === 'topics' ? { ...row, msg_id: '' } : row
  const opened = await openParentSection(msg, deps).catch(() => false)
  if (!opened) {
    const page = String(deps.fallback || '')
    if (!page) return false
    const [path, hash] = page.split('#')
    await router.push({ path: localePath(path), hash: hash ? '#' + hash : undefined })
  }
  if (row.type !== 'topics' && row.msg_id) markHit(String(row.msg_id))
  return true
}

/** Flash the hit once it has rendered (at most tries x every ms). */
export function markHit(msgId, { tries = 60, every = 100, hold = 2400 } = {}) {
  if (typeof document === 'undefined' || !msgId) return
  const sel = `.msg[data-msg-id="${CSS.escape(msgId)}"]`
  const els = [...document.querySelectorAll(sel)]
  if (!els.length) {
    if (tries > 0) setTimeout(() => markHit(msgId, { tries: tries - 1, every, hold }), every)
    return
  }
  for (const el of els) {
    el.classList.add('search-focus')
    setTimeout(() => el.classList.remove('search-focus'), hold)
  }
}
