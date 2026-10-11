// `/` lands on Channels (owner HUM-10, t1 e4bfddb1, msg a78e06c8: "Remove
// the whole topics view"; `/` was the Topics list). pages/index.vue asks here
// where to go.

/**
 * Where `/` sends the reader: a desktop opens #lobby, with the query kept so
 * a `/?topic=<task_id>` deep link still opens that topic in the right pane.
 * A phone stays on `/`, whose screen is the left panel (the Channels list),
 * unless the link names a topic (`?topic=` / `?in=`, level 3): then #lobby too.
 * @param {{ phone: boolean, query?: Record<string, unknown> }} s
 * @returns {{ path: string, query: Record<string, unknown> } | null} null = stay
 */
export function lobbyHomeTarget({ phone, query } = { phone: false }) {
  const q = { ...(query || {}) }
  if (phone && !q.topic && !q.in) return null
  return { path: '/lobby', query: q }
}

/* the address as the document loaded it (plugins/0.loaded-url.client.ts);
   undefined until noted, null once taken */
let loaded

/** Note the first load's path and query (once per document). */
export function noteLoadedUrl(path, search) {
  if (loaded === undefined) loaded = { path: String(path || '/'), search: String(search || '') }
}

/**
 * The first load's query when that load was the front door `/` (any locale
 * prefix, isFrontDoor), once: every later call, and a load of any other page,
 * gets null, and the caller reads the router, which holds the real query by
 * then (an in-app visit).
 * @param {(path: string) => boolean} isFrontDoor
 * @returns {Record<string, string> | null}
 */
export function takeLoadedQuery(isFrontDoor) {
  const was = loaded
  loaded = null
  if (!was || !isFrontDoor(was.path)) return null
  const out = {}
  for (const [k, v] of new URLSearchParams(was.search)) out[k] = v
  return out
}
