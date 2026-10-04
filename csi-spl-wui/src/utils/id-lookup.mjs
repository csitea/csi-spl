/**
 * Ids the tab has not loaded still become links (HUM-10, topic cd357c76:
 * "the links conversion should work in the direct msgs too"). The linker
 * (id-links.mjs) links an id only when its row is already in a store, so a
 * direct message quoting a topic of a channel this tab never opened stayed
 * text. Here a rendered body hands over its text; the ids it holds that the
 * catalog cannot resolve are asked from the hub in ONE call,
 * POST /v1/view/ids, after the body is on screen. The answers are kept for
 * the tab and fed to the catalog as rows, so the linker builds the same
 * targets and kind labels it builds for a loaded row.
 *
 * No request when every id is already resolved, already asked or already
 * known to be unknown. Bodies noted in the same tick share one request (at
 * most LOOKUP_MAX ids each). A failed request marks its ids unknown, so a
 * repaint never asks again.
 */

const UUID_SRC = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
const TOKEN_RE = new RegExp(`(?<![0-9a-fA-F-])(?:${UUID_SRC}|[0-9a-fA-F]{8})(?![0-9a-fA-F-])`, 'g')
const HAS_HEX = /[0-9a-fA-F]{8}/
/* id-links.mjs leaves an id in code, in a link or in a url alone. So do we. */
const PROTECT_RE = /```[\s\S]*?```|`{1,2}[^`\n]+`{1,2}|\[[^\]\n]+\]\([^)\n]+\)|https?:\/\/[^\s<>)\]]+|www\.[^\s<>)\]]+/gi

/** The most ids one request carries (the hub refuses more). */
export const LOOKUP_MAX = 50
/* bodies whose tokens are kept; past it the memo starts again */
const SCANNED_MAX = 4000

/** The distinct id tokens of text, lower case, outside code and links. */
export function bodyTokens(text) {
  const s = String(text ?? '')
  if (!HAS_HEX.test(s)) return []
  const ranges = []
  PROTECT_RE.lastIndex = 0
  for (const m of s.matchAll(PROTECT_RE)) ranges.push([m.index, m.index + m[0].length])
  const open = s.lastIndexOf('```')
  if (open >= 0 && !ranges.some(([a, b]) => open >= a && open < b)) ranges.push([open, s.length])
  const out = new Set()
  TOKEN_RE.lastIndex = 0
  for (const m of s.matchAll(TOKEN_RE)) {
    const a = m.index
    const b = a + m[0].length
    if (!ranges.some(([x, y]) => a >= x && b <= y)) out.add(m[0].toLowerCase())
  }
  return [...out]
}

function splitPeer(peer) {
  const p = String(peer || '')
  const at = p.indexOf('@')
  return at > 0 ? [p.slice(0, at), p.slice(at + 1)] : [p, '']
}

/**
 * Hub answers as catalog rows: a topic as a topic row, a message as a
 * message row whose ends are the reader and the peer, the shape the linker
 * reads from a loaded row.
 * @param {Iterable<{ kind?: string, task_id?: string, msg_id?: string, channel?: string, peer?: string, archived?: boolean }>} hits
 * @param {string} [self] the reader's id
 */
export function hitRows(hits, self = '') {
  const topics = []
  const messages = []
  for (const h of hits || []) {
    if (!h || typeof h !== 'object') continue
    const channel = String(h.channel || '')
    const archived = h.archived === true
    if (h.kind === 'topic') {
      topics.push({ task_id: String(h.task_id || ''), channel, participants: h.peer ? [String(h.peer)] : [], archived })
    } else if (h.kind === 'message' && h.msg_id) {
      const [to, toBox] = splitPeer(h.peer)
      messages.push({
        msg_id: String(h.msg_id),
        task_id: String(h.task_id || ''),
        parent_task_id: null,
        channel: channel || null,
        from: channel ? '' : String(self || ''),
        to: channel ? '' : to,
        to_box: channel ? '' : toBox,
        archived,
      })
    }
  }
  return { topics, messages }
}

function defaultSchedule(fn) {
  const w = typeof window === 'undefined' ? null : window
  if (w && typeof w.requestIdleCallback === 'function') w.requestIdleCallback(() => fn(), { timeout: 400 })
  else setTimeout(fn, 30)
}

/**
 * The tokens of a body, or null when that body was already checked against
 * this same catalog: a repaint on an unchanged catalog has nothing new to
 * ask, so it costs one Set lookup. Each text is scanned once.
 */
function bodyMemo() {
  const scanned = new Map()
  let settled = new Set()
  let settledFor = null
  return (text, index) => {
    const key = String(text ?? '')
    if (index !== settledFor) {
      settled = new Set()
      settledFor = index
    } else if (settled.has(key)) return null
    if (settled.size < SCANNED_MAX) settled.add(key)
    let toks = scanned.get(key)
    if (!toks) {
      toks = bodyTokens(key)
      if (scanned.size >= SCANNED_MAX) scanned.clear()
      scanned.set(key, toks)
    }
    return toks
  }
}

/**
 * The per-tab lookup.
 * @param {{
 *   fetchIds: (ids: string[]) => Promise<unknown>,
 *   resolves: (token: string, index: unknown) => boolean,
 *   onHits: () => void,
 *   schedule?: (fn: () => void) => void,
 *   max?: number,
 * }} opts
 *   fetchIds: POST /v1/view/ids, answers `{ ids: [...] }`;
 *   resolves: whether the catalog already links the token;
 *   onHits: called once a request brought at least one hit (repaint).
 */
export function createIdLookup(opts) {
  const fetchIds = opts.fetchIds
  const resolves = opts.resolves
  const onHits = opts.onHits
  const schedule = opts.schedule || defaultSchedule
  const max = Number(opts.max) > 0 ? Number(opts.max) : LOOKUP_MAX
  /** token -> hit, null when the hub does not know it, undefined while asked */
  const known = new Map()
  const queued = new Set()
  const tokensOf = bodyMemo()
  let armed = false
  let version = 0

  async function ask(ids) {
    let hits = []
    try {
      const res = await fetchIds(ids)
      hits = Array.isArray(res && res.ids) ? res.ids : []
    } catch { /* unknown for this tab: a repaint must not ask again */ }
    const byId = new Map()
    for (const h of hits) if (h && typeof h.id === 'string') byId.set(h.id.toLowerCase(), h)
    for (const id of ids) known.set(id, byId.get(id) || null)
    if (byId.size) {
      version += 1
      onHits()
    }
  }

  function flush() {
    armed = false
    const all = [...queued]
    queued.clear()
    for (let i = 0; i < all.length; i += max) void ask(all.slice(i, i + max))
  }

  /** A body is on screen: queue the ids of its text the catalog cannot link. */
  function note(text, index) {
    const toks = tokensOf(text, index)
    if (!toks || !toks.length) return
    let added = false
    for (const t of toks) {
      if (known.has(t)) continue
      let ok = false
      try { ok = resolves(t, index) } catch { ok = false }
      if (ok) continue
      queued.add(t)
      known.set(t, undefined)
      added = true
    }
    if (added && !armed) {
      armed = true
      schedule(flush)
    }
  }

  /** The hits so far, as catalog rows. */
  function rows(self = '') {
    const hits = []
    for (const h of known.values()) if (h) hits.push(h)
    return hitRows(hits, self)
  }

  return {
    note,
    rows,
    get version() { return version },
  }
}

/**
 * The mock tenant's answer (no hub): every id of rows, as the hub answers
 * it for a reader who may read them all.
 * @param {unknown[]} rows every mock message (archived cards included)
 * @param {unknown[]} archived the archived cards
 * @param {string[]} ids
 * @param {string} [self]
 */
export function mockLookupIds(rows, archived, ids, self = '') {
  const list = Array.isArray(rows) ? rows : []
  const gone = new Set()
  for (const a of archived || []) {
    if (a && a.msg_id) gone.add(String(a.msg_id))
    if (a && a.task_id) gone.add(String(a.task_id))
  }
  const peerOf = (m) => {
    for (const [id, box] of [[m.from, m.from_box], [m.to, m.to_box]]) {
      const i = String(id || '')
      if (!i || i === self || i.startsWith('@') || i === 'ALL-0') continue
      return box ? `${i}@${box}` : i
    }
    return ''
  }
  const topicHit = (id, ms) => {
    const ch = ms.find((m) => m.channel)
    const dm = ms.find((m) => !m.channel)
    return { id, kind: 'topic', task_id: id, channel: ch ? String(ch.channel) : undefined,
      peer: !ch && dm ? peerOf(dm) || undefined : undefined, archived: gone.has(id) }
  }
  const msgHit = (id, m) => {
    const task = String(m.parent_task_id || m.task_id || '')
    return { id, kind: 'message', task_id: task, msg_id: String(m.msg_id),
      channel: m.channel ? String(m.channel) : undefined, peer: m.channel ? undefined : peerOf(m) || undefined,
      archived: gone.has(String(m.msg_id)) || gone.has(String(m.task_id)) || gone.has(task) }
  }
  const out = []
  for (const raw of ids || []) {
    const tok = String(raw || '').toLowerCase()
    const match = (v) => (tok.length === 8 ? String(v || '').startsWith(tok) : String(v || '') === tok)
    const tasks = [...new Set(list.filter((m) => m && match(m.task_id)).map((m) => String(m.task_id)))]
    if (tasks.length === 1) {
      out.push({ ...topicHit(tasks[0], list.filter((m) => m && String(m.task_id) === tasks[0])), id: tok })
      continue
    }
    if (tasks.length > 1) continue
    const msgs = list.filter((m) => m && match(m.msg_id))
    if (msgs.length === 1) out.push(msgHit(tok, msgs[0]))
  }
  return { ids: out }
}
