/**
 * SPL-5250: a read of the channel / DM feed answers for the feed it was asked
 * for. Switching feeds starts a new read while the old one is still in flight,
 * and whichever returned last used to win: the old feed's rows replaced the
 * open one's, and its `loading` went false while the open feed's read still
 * ran. A read that returns after the open feed changed now changes nothing.
 */

/**
 * The feed a read is for: the open channel or the open DM peer.
 * @param {{ active: { value: string | null }, peer: { value: string | null } }} s
 */
export function openFeed(s) {
  return { channel: s.active.value || undefined, peer: s.peer.value || undefined }
}

/**
 * True while `where` is still the feed on screen.
 * @param {{ channel?: string | null, peer?: string | null }} where
 * @param {{ active: { value: string | null }, peer: { value: string | null } }} s
 */
export function sameFeed(where, s) {
  return (where.channel || undefined) === (s.active.value || undefined) &&
    (where.peer || undefined) === (s.peer.value || undefined)
}

/**
 * The first page of the open feed (the channel store's refresh). `d` holds the
 * store's steps: read(where) -> page, withHeld(rows), keep(where, page),
 * showKept(err, where) -> kept?, follow(), failed(err) -> error text.
 * `background` (the mock tenant's poll) leaves `loading` alone (SPL-5037).
 * @param {any} s the channel store's state refs
 * @param {any} d
 * @param {{ background?: boolean }} [opts]
 */
export async function readFirstPage(s, d, { background = false } = {}) {
  const where = openFeed(s)
  if (!background) s.loading.value = true
  s.error.value = null
  try {
    const page = await d.read(where)
    if (!sameFeed(where, s)) return
    s.messages.value = d.withHeld(page.messages || [])
    s.totals.value = page.totals || {}
    s.olderCursor.value = page.next || null
    s.offlineAt.value = null
    d.keep(where, page)
    d.follow()
  } catch (e) {
    /* SPL-2149: no network - the copy of this feed this device read last */
    const kept = sameFeed(where, s) && await d.showKept(e, where)
    if (!kept && sameFeed(where, s)) s.error.value = d.failed(e)
  } finally {
    if (!background && sameFeed(where, s)) s.loading.value = false
  }
}
