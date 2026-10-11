// t1 3b8891e0 (c-983's finding): the level above a phone Documents level.
// A fresh load of /workspace/docs?in=<key> (a new tab, a reload, a shared
// link) has no history entry of ours below it, so the Back chevron used to
// leave Documents at once. The page's Back steps to drillParent(key) in place
// instead, one level a tap, up to the top of Documents; only from the top does
// Back leave. In-app drill-downs keep their own history entries, untouched.
//
// Keys (QtoFileTree): f:<folder>, d:<doc>, i:<doc>:<item>; '' = the top.

/**
 * @typedef {{ id: string, kind: 'folder' | 'doc', doc: string }} DrillNode
 * @typedef {{ id: string, parent: string }} DrillItem
 * @typedef {{
 *   nodes: (parent: string) => Promise<{ nodes: DrillNode[] }>,
 *   subtree: (doc: string) => Promise<{ items: DrillItem[] }>,
 * }} DrillClient
 */

/**
 * The folder whose listing holds a node matching `match` ('' = the top, also
 * when none does): a walk down the folders, the hub's /nodes having no parent
 * lookup. A folder that fails to list is skipped.
 * @param {(n: DrillNode) => boolean} match
 * @param {DrillClient['nodes']} nodes
 * @returns {Promise<string>}
 */
async function folderHolding(match, nodes) {
  const queue = ['']
  const seen = new Set()
  while (queue.length) {
    const at = /** @type {string} */ (queue.shift())
    if (seen.has(at)) continue
    seen.add(at)
    /** @type {DrillNode[]} */
    let list = []
    try {
      list = (await nodes(at)).nodes
    } catch {
      continue
    }
    if (list.some(match)) return at
    for (const n of list) if (n.kind === 'folder') queue.push(n.id)
  }
  return ''
}

/**
 * The key of the level above `key`: a section's parent section, else its
 * document; a document's or a folder's folder, else '' (the top). null for
 * the top itself: nothing above it inside Documents.
 * @param {string} key
 * @param {DrillClient} client
 * @returns {Promise<string | null>}
 */
export async function drillParent(key, client) {
  if (!key) return null
  const [kind, id, item] = key.split(':')
  if (kind === 'i' && id) {
    /** @type {DrillItem[]} */
    let items = []
    try {
      items = (await client.subtree(id)).items
    } catch { /* unread: the document's own level */ }
    const up = items.find((it) => it.id === items.find((x) => x.id === item)?.parent)
    /* the document's root item has no parent: a top section's level is the document */
    return up && up.parent ? `i:${id}:${up.id}` : `d:${id}`
  }
  const holder = kind === 'd' && id
    ? await folderHolding((n) => n.kind === 'doc' && n.doc === id, client.nodes)
    : kind === 'f' && id
      ? await folderHolding((n) => n.kind === 'folder' && n.id === id, client.nodes)
      : ''
  return holder ? 'f:' + holder : ''
}
