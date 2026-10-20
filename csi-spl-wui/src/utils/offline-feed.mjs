/**
 * SPL-2149 (UI suggestion 8, owner HUM-10 t1 1061f05f): recently read
 * channels stay readable offline.
 *
 * Every first page a channel or DM feed read from the hub, and the channel
 * list, is kept here as the last copy this browser saw. When a read fails
 * because there is no network, the store shows that copy instead of an empty
 * feed, with the time it was read (components/OfflineBanner.vue).
 *
 * One localStorage key, so sign-out drops it in one call (stores/session.ts,
 * specs/005-spool-wui/client-state.md section 3): the next member on this
 * browser never reads the previous member's messages. At most MAX_FEEDS
 * feeds and MAX_CHARS characters; the feed read longest ago goes first.
 */
import { storageGetJson, storageSet } from './prefs.mjs'
import { isOffline } from './offline-queue.mjs'

export const OFFLINE_FEEDS_KEY = 'spool.offline-feeds'
export const MAX_FEEDS = 8
/* well under the ~5 M characters a browser gives one origin's localStorage */
export const MAX_CHARS = 1_500_000

/**
 * A read that failed for want of a network, not because the hub said no: the
 * browser is offline, the request never left (fetch's network TypeError), or the
 * offline token the mock and the send queue throw.
 * @param {unknown} err
 * @param {{ onLine?: boolean } | undefined} [nav]
 */
export function readFailedOffline(err, nav = globalThis.navigator) {
  if (nav && nav.onLine === false) return true
  if (!err || typeof err !== 'object') return false
  if (/** @type {{ status?: unknown }} */ (err).status) return false
  if (/** @type {{ token?: unknown }} */ (err).token === 'closed') return true
  /* Chrome, Firefox, Safari: a fetch that never reached a server (a bug's TypeError says otherwise) */
  return err instanceof TypeError && /failed to fetch|networkerror|load failed/i.test(err.message)
}

/** The feed's key: tenant + channel or DM peer. */
export function feedKey(tenant, { channel, peer } = {}) {
  const where = channel ? `ch:${channel}` : peer ? `dm:${peer}` : ''
  return where ? `${tenant || '-'}|${where}` : ''
}

function readAll(store) {
  const all = storageGetJson(OFFLINE_FEEDS_KEY, null, store)
  if (!all || typeof all !== 'object' || typeof all.feeds !== 'object' || !all.feeds) return { feeds: {}, channels: {} }
  return { feeds: all.feeds, channels: all.channels && typeof all.channels === 'object' ? all.channels : {} }
}

/** Write the map, dropping the oldest feeds until it fits (or the store refuses it all). */
function writeAll(all, store) {
  const keys = Object.keys(all.feeds).sort((a, b) => String(all.feeds[b].at).localeCompare(String(all.feeds[a].at)))
  for (const k of keys.slice(MAX_FEEDS)) delete all.feeds[k]
  for (;;) {
    const text = JSON.stringify(all)
    const left = Object.keys(all.feeds).sort((a, b) => String(all.feeds[a].at).localeCompare(String(all.feeds[b].at)))
    if (text.length <= MAX_CHARS && storageSet(OFFLINE_FEEDS_KEY, text, store)) return true
    if (!left.length) return false
    delete all.feeds[left[0]]
  }
}

/**
 * Keep the first page of a feed as read from the hub.
 * @param {string} key feedKey()
 * @param {{ messages: unknown[], totals?: object }} page
 * @param {{ store?: Storage, now?: () => number }} [opts]
 */
export function saveFeed(key, page, { store, now = Date.now } = {}) {
  if (!key || !page || !Array.isArray(page.messages)) return false
  const all = readAll(store)
  all.feeds[key] = { at: new Date(now()).toISOString(), messages: page.messages, totals: page.totals || {} }
  /* true only when this page itself was kept, not just what was left */
  return writeAll(all, store) && key in all.feeds
}

/** The last copy of a feed: { at, messages, totals } or null. */
export function loadFeed(key, { store } = {}) {
  const f = key ? readAll(store).feeds[key] : null
  return f && Array.isArray(f.messages) ? f : null
}

/** Keep the channel list as read from the hub. */
export function saveChannels(tenant, rows, { store, now = Date.now } = {}) {
  if (!Array.isArray(rows)) return false
  const all = readAll(store)
  all.channels[tenant || '-'] = { at: new Date(now()).toISOString(), rows }
  return writeAll(all, store)
}

/** The last channel list: { at, rows } or null. */
export function loadChannels(tenant, { store } = {}) {
  const c = readAll(store).channels[tenant || '-']
  return c && Array.isArray(c.rows) ? c : null
}

/* The store's calls (stores/channel.ts), here so the entry chunk carries none of this. */

/** Keep a first page read from the hub. */
export function keepPage(tenant, where, page, opts) {
  return saveFeed(feedKey(tenant, where), { messages: (page && page.messages) || [], totals: (page && page.totals) || {} }, opts)
}

/** The kept copy of a feed when its read failed for want of a network, else null. */
export function keptPage(tenant, err, where, opts) {
  return readFailedOffline(err, opts && opts.nav) ? loadFeed(feedKey(tenant, where), opts) : null
}

/**
 * The channel store's failed first page (stores/channel.ts refresh). Offline,
 * the copy of this feed this device kept is shown (true). With no copy, never
 * another feed's rows or saved time (false: the error shows). `s` is the
 * store's state; `withHeld(rows)` adds the sends not on the hub yet.
 */
export function showKept(s, withHeld, err, where, opts) {
  const kept = keptPage(s.api.tenant, err, where, opts)
  if (where.channel !== (s.active.value || undefined) || where.peer !== (s.peer.value || undefined)) return false
  s.offlineAt.value = kept ? kept.at : null
  if (kept) { s.totals.value = kept.totals || {}; s.olderCursor.value = null }
  if (kept || isOffline(opts && opts.nav)) s.messages.value = withHeld(kept ? kept.messages : [])
  return Boolean(kept)
}

/** The kept channel rows when the list read failed for want of a network, else null. */
export function keptChannelRows(tenant, err, opts) {
  const c = readFailedOffline(err, opts && opts.nav) ? loadChannels(tenant, opts) : null
  return c ? c.rows : null
}

/** Sign-out: drop every kept feed and channel list. */
export function clearOfflineFeeds(store) {
  try {
    const s = store || globalThis.localStorage
    if (s) s.removeItem(OFFLINE_FEEDS_KEY)
  } catch {
    /* storage blocked: nothing was kept */
  }
}
