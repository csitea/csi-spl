/**
 * The cards of internal link previews (topic e1f8f797), asked from the hub
 * in batches: every body on screen notes the ids its links name, and the ids
 * noted in the same tick go out in ONE POST /v1/view/previews (at most
 * PREVIEW_ASK_MAX each). An answer is kept for the tab for PREVIEW_TTL_MS, so
 * a repaint, a scroll back or a second link to the same topic asks nothing.
 * An id the hub leaves out (unknown, or not readable by this reader) is kept
 * as null: its link stays plain and is not asked again until the TTL.
 * A failed request is kept the same way.
 *
 * Loaded only with LinkPreviews.vue, never on the first paint.
 */

/** The most ids one request carries (the hub refuses more). */
export const PREVIEW_ASK_MAX = 20
/** How long an answer is reused before it is asked again. */
export const PREVIEW_TTL_MS = 5 * 60 * 1000

function defaultSchedule(fn) {
  setTimeout(fn, 0)
}

/**
 * @param {{
 *   fetchPreviews: (ids: string[]) => Promise<unknown>,
 *   onChange: () => void,
 *   schedule?: (fn: () => void) => void,
 *   now?: () => number,
 *   max?: number,
 * }} opts
 */
export function createPreviewLookup(opts) {
  const fetchPreviews = opts.fetchPreviews
  const onChange = opts.onChange
  const schedule = opts.schedule || defaultSchedule
  const now = opts.now || (() => Date.now())
  const max = Number(opts.max) > 0 ? Number(opts.max) : PREVIEW_ASK_MAX
  /** id -> { hit, at }; hit undefined while asked, null when there is none */
  const known = new Map()
  const queued = new Set()
  let armed = false

  async function ask(ids) {
    let rows = []
    try {
      const res = await fetchPreviews(ids)
      rows = res && Array.isArray(res.previews) ? res.previews : []
    } catch { /* none for this tab until the TTL */ }
    const byId = new Map()
    for (const r of rows) if (r && typeof r.id === 'string') byId.set(r.id.toLowerCase(), r)
    const at = now()
    for (const id of ids) known.set(id, { hit: byId.get(id) || null, at })
    onChange()
  }

  function flush() {
    armed = false
    const all = [...queued]
    queued.clear()
    for (let i = 0; i < all.length; i += max) void ask(all.slice(i, i + max))
  }

  /** A body is on screen: ask for the ids not known (or known too long). */
  function want(ids) {
    let added = false
    for (const raw of ids || []) {
      const id = String(raw || '').toLowerCase()
      if (!id) continue
      const k = known.get(id)
      if (k && (k.hit === undefined || now() - k.at < PREVIEW_TTL_MS)) continue
      known.set(id, { hit: undefined, at: now() })
      queued.add(id)
      added = true
    }
    if (added && !armed) {
      armed = true
      schedule(flush)
    }
  }

  /** The card for id: the hub's row, or null (none, or not answered yet). */
  function get(id) {
    const k = known.get(String(id || '').toLowerCase())
    return k && k.hit ? k.hit : null
  }

  return { want, get }
}

const TITLE_MAX = 100
const LINE_MAX = 160
const LINES = 3

function cut(s, n) {
  const r = [...s]
  return r.length <= n ? s : r.slice(0, n - 1).join('') + '…'
}

function linesOf(body) {
  return String(body ?? '').split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('```'))
}

/**
 * The hub's text rule (view_previews.go): the title is the first non-empty
 * line (100 characters), the excerpt the next three (160 each).
 * @param {unknown} body
 * @returns {{ title: string, excerpt: string }}
 */
export function previewText(body) {
  const ls = linesOf(body)
  if (!ls.length) return { title: '', excerpt: '' }
  return { title: cut(ls[0], TITLE_MAX), excerpt: ls.slice(1, 1 + LINES).map((l) => cut(l, LINE_MAX)).join('\n') }
}

/**
 * The mock tenant's answer (no hub): every id of rows, as the hub answers a
 * reader who may read them all.
 * @param {unknown[]} rows every mock message
 * @param {string[]} ids
 */
export function mockPreviews(rows, ids) {
  const list = (Array.isArray(rows) ? rows : []).filter((m) => m && typeof m === 'object')
  const at = (m) => String(m.ts || m.received_at || '')
  const starter = (task) => list.filter((m) => String(m.task_id) === task)
    .sort((a, b) => (at(a) < at(b) ? -1 : at(a) > at(b) ? 1 : String(a.msg_id) < String(b.msg_id) ? -1 : 1))[0]
  const out = []
  for (const raw of ids || []) {
    const id = String(raw || '').toLowerCase()
    const st = starter(id)
    if (st) {
      out.push({ id, kind: 'topic', task_id: id, channel: st.channel || undefined, archived: false,
        ...previewText(st.body), from: String(st.from || ''), ts: at(st) })
      continue
    }
    const m = list.find((r) => String(r.msg_id) === id)
    if (!m) continue
    const task = String(m.parent_task_id || m.task_id || '')
    const top = starter(task)
    const own = previewText(m.body)
    const same = top && String(top.msg_id) === id
    out.push({ id, kind: 'message', task_id: task, msg_id: id, channel: m.channel || undefined, archived: false,
      title: top && !same ? previewText(top.body).title : own.title,
      excerpt: top && !same ? linesOf(m.body).slice(0, LINES).map((l) => cut(l, LINE_MAX)).join('\n') : own.excerpt,
      from: String(m.from || ''), ts: at(m) })
  }
  return { previews: out }
}
