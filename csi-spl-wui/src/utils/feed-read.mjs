/**
 * SPL-5250: a read of the channel / DM feed answers for the feed it was asked
 * for. Switching feeds starts a new read while the old one is still in flight,
 * and whichever returned last used to win: the old feed's rows replaced the
 * open one's, and its `loading` went false while the open feed's read still
 * ran. A read that returns after the open feed changed now changes nothing.
 *
 * Comparing the feed alone is not enough: after A -> B -> A the first read of
 * A matches the open feed again (R7 c-544, msg 819963d6). So every opening of
 * a feed (a foreground first-page read) starts a new generation, and a read
 * lands only while its generation is still the newest one.
 */

/* the generation per channel store; a WeakMap, so the store's state needs no new field */
const generations = new WeakMap()
const generation = (s) => generations.get(s) || 0

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
 * Start a read of the open feed. `opening` (a foreground first-page read)
 * starts a new generation, so every read started before it goes stale.
 * `current()` is true while the read may still write the store.
 * @param {object} s the channel store's state
 * @param {{ opening?: boolean }} [opts]
 */
function startRead(s, { opening = false } = {}) {
  if (opening) generations.set(s, generation(s) + 1)
  const mine = generation(s)
  const where = openFeed(s)
  return { where, current: () => mine === generation(s) && sameFeed(where, s) }
}

/**
 * The first page of the open feed (the channel store's refresh). `d` holds the
 * store's steps: read(where) -> page, withHeld(rows), keep(where, page),
 * showKept(err, where) -> kept?, follow(), failed(err) -> error text.
 * `background` (the mock tenant's poll) leaves `loading` alone (SPL-5037) and
 * starts no new generation: it re-reads the feed already open.
 * @param {any} s the channel store's state refs
 * @param {any} d
 * @param {{ background?: boolean }} [opts]
 */
export async function readFirstPage(s, d, { background = false } = {}) {
  const { where, current } = startRead(s, { opening: !background })
  if (!background) s.loading.value = true
  s.error.value = null
  try {
    const page = await d.read(where)
    if (!current()) return
    s.messages.value = d.withHeld(page.messages || [])
    s.totals.value = page.totals || {}
    s.olderCursor.value = page.next || null
    s.offlineAt.value = null
    d.keep(where, page)
    d.follow()
  } catch (e) {
    /* SPL-2149: no network - the copy of this feed this device read last */
    const kept = current() && await d.showKept(e, where)
    if (!kept && current()) s.error.value = d.failed(e)
  } finally {
    if (!background && current()) s.loading.value = false
  }
}

/**
 * A follow-up read of the open feed (Load more's older page, the catch-up
 * after a reconnect): `d.read(where)` -> page, then `d.land(page, where)` or,
 * on a failure, `d.fail(err)`, each only while the read is current.
 * @param {any} s the channel store's state refs
 * @param {{ read: (where: any) => Promise<any>, land: (page: any, where: any) => void, fail: (e: unknown) => void }} d
 */
export async function readMore(s, d) {
  const { where, current } = startRead(s)
  try {
    const page = await d.read(where)
    if (current()) d.land(page, where)
  } catch (e) {
    if (current()) d.fail(e)
  }
}
