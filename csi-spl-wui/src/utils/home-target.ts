// `/` lands on Channels (owner HUM-10, t1 e4bfddb1, msg a78e06c8: "Remove
// the whole topics view"; `/` was the Topics list). pages/index.vue asks here
// where to go.

/**
 * Where `/` sends the reader: a desktop opens #lobby, with the query kept so
 * a `/?topic=<task_id>` deep link still opens that topic in the right pane.
 * A phone stays on `/`, whose screen is the left panel (the Channels list),
 * unless the link names a topic (`?topic=` / `?in=`, level 3): then #lobby too.
 * null = stay.
 */
export function lobbyHomeTarget(
  { phone, query }: { phone: boolean, query?: Record<string, unknown> } = { phone: false },
): { path: string, query: Record<string, unknown> } | null {
  const q = { ...(query || {}) }
  if (phone && !q.topic && !q.in) return null
  return { path: '/lobby', query: q }
}

/* the address as the document loaded it (plugins/0.loaded-url.client.ts);
   undefined until noted, null once taken */
let loaded: { path: string, search: string } | null | undefined

/** Note the first load's path and query (once per document). */
export function noteLoadedUrl(path: string, search: string): void {
  if (loaded === undefined) loaded = { path: String(path || '/'), search: String(search || '') }
}

/**
 * The first load's query when that load was the front door `/` (any locale
 * prefix, isFrontDoor), once: every later call, and a load of any other page,
 * gets null, and the caller reads the router, which holds the real query by
 * then (an in-app visit).
 */
export function takeLoadedQuery(isFrontDoor: (path: string) => boolean): Record<string, string> | null {
  const was = loaded
  loaded = null
  if (!was || !isFrontDoor(was.path)) return null
  const out: Record<string, string> = {}
  for (const [k, v] of new URLSearchParams(was.search)) out[k] = v
  return out
}
