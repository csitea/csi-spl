/* Spec 138: a URL that opens a Qto document at one section. The owner's
   picks (t1 topic 7c968b85): "Copy link" writes the stable id only, form A
   `#ws-doc-<item id>` (msg 748ecf3c); a readable anchor that carries the id
   still opens its section, form D `#1.2.3-title-words~3f2a91c0`, resolved
   ONLY through its 8-hex id suffix, so a move, rename or renumber never
   breaks it (msg 7f2f7bd9). A bare outline number or title slug is not
   resolved: it would point elsewhere after a move. The `-` prefix keeps Nuxt
   from registering this file as a component. */

export const ANCHOR = 'ws-doc-'
/* form D: anything, then `~` and the first 8 hex digits of the item id */
const ID_SUFFIX = /~([0-9a-f]{8})$/i

/** the canonical anchor of an item (form A), without the '#' */
export const anchorOf = (id: string) => ANCHOR + id

/** the item a location hash names, else '' (no hash, or an unknown anchor):
    form A by its full id, form D by its id suffix when exactly one id has it */
export function resolveAnchor(hash: string, ids: Iterable<string>): string {
  let h = hash.startsWith('#') ? hash.slice(1) : hash
  try {
    h = decodeURIComponent(h)
  } catch { /* a malformed escape: the raw text */ }
  if (!h) return ''
  const all = [...ids]
  if (h.startsWith(ANCHOR)) {
    const id = h.slice(ANCHOR.length)
    return all.includes(id) ? id : ''
  }
  const m = ID_SUFFIX.exec(h)
  if (!m) return ''
  const pre = m[1].toLowerCase()
  const hits = all.filter((id) => id.toLowerCase().startsWith(pre))
  return hits.length === 1 ? hits[0] : ''
}

/** a document's link, opened at one section (form A) when item is given: the
    path the router resolves for /workspace/docs, made absolute */
export function docLink(resolve: (to: { path: string, query: Record<string, string>, hash: string }) => { href: string }, origin: string, doc: string, item = ''): string {
  return new URL(resolve({ path: '/workspace/docs', query: { doc, view: 'doc' }, hash: item ? '#' + anchorOf(item) : '' }).href, origin).href
}
