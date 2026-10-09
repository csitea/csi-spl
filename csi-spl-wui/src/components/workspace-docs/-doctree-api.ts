/* The doctree hub client (spec 113 T004 routes, /v1/workspace/doctree): one
   call per op, the doc rev the page read as every structural op's
   precondition. The mock tenant answers from -doctree-mock.ts, loaded on its
   first call. The `-` prefix keeps Nuxt from registering this file as a
   component. */
import { ref, type Ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import { docFetchTimeoutMs } from '~/utils/fetch-timeouts.mjs'

export type DocHead = { id: string, title: string, rev: number, items: number, root: string, topic_id: string, updated_at: string }
export type DocItem = { id: string, parent: string, ord: number, outline: string, depth: number, title: string, body: string, attrs: Record<string, unknown>, rev: number }
export type DocChildren = { doc: string, rev: number, parent: string, path: number[], outline: string, items: DocItem[] }
export type DocGrid = { doc: string, rev: number, total: number, items: DocItem[] }
export type DocWhere = 'sibling' | 'parent' | 'child'
export type DocMoveKind = 'indent' | 'outdent' | 'up' | 'down'

/** A refused call: 412 stale (reload), 404 gone, 422 refused, 413 too large. */
export class DocTreeError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message)
  }
}

type Mock = typeof import('./-doctree-mock')
let mockMod: Promise<Mock> | null = null

export function useDocTree() {
  const api = useSpoolApi()
  const mock = () => (mockMod ??= import('./-doctree-mock').catch((e) => {
    mockMod = null /* a chunk that failed to load (a deploy in between) is asked again next time */
    throw e
  }))

  async function call<T>(method: string, path: string, body?: Record<string, unknown>): Promise<T> {
    let status: number
    let out: unknown
    if (api.mock) {
      const r = (await mock()).mockDocTree(method, path, body)
      status = r.status
      out = JSON.parse(JSON.stringify(r.body)) /* a copy, as off the wire */
    } else {
      const headers: Record<string, string> = {}
      if (api.token) headers.authorization = `Bearer ${api.token}`
      if (body) headers['content-type'] = 'application/json'
      const r = await fetch(`${api.base}/v1/workspace/doctree${path}`, {
        method, headers, credentials: api.credentials, cache: 'no-cache',
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(docFetchTimeoutMs(method)),
      })
      status = r.status
      out = await r.json().catch(() => ({}))
    }
    if (status < 200 || status > 299) {
      const e = (out || {}) as { error?: string, message?: string }
      throw new DocTreeError(status, e.error || 'error', e.message || `doctree ${status}`)
    }
    return out as T
  }

  const enc = encodeURIComponent
  return {
    list: () => call<{ docs: DocHead[] }>('GET', '').then((r) => r.docs),
    create: (title: string) => call<{ id: string, root: string, rev: number }>('POST', '', { title }),
    head: (doc: string) => call<DocHead>('GET', `/${enc(doc)}`),
    /** the lazy unit: one node's children ('' = the top level) */
    children: (doc: string, parent = '') => call<DocChildren>('GET', `/${enc(doc)}/children${parent ? '?parent=' + enc(parent) : ''}`),
    /** the item and everything under it, in document order; no item = the whole document (the doc view, print) */
    subtree: (doc: string, item = '') => call<{ rev: number, items: DocItem[] }>('GET', `/${enc(doc)}/subtree${item ? '?item=' + enc(item) : ''}`),
    grid: (doc: string, q: string, sort: string, desc: boolean) => {
      const p = new URLSearchParams()
      if (q.trim()) p.set('q', q.trim())
      if (sort !== 'outline') p.set('sort', sort)
      if (desc) p.set('desc', '1')
      const qs = p.toString()
      return call<DocGrid>('GET', `/${enc(doc)}/grid${qs ? '?' + qs : ''}`)
    },
    add: (doc: string, rev: number, anchor: string, where: DocWhere, title: string) =>
      call<{ rev: number, item: string }>('POST', `/${enc(doc)}/items`, { rev, anchor, where, ord: 0, title, body: '' }),
    /** ord is the final position under parent, 0 = last */
    move: (doc: string, rev: number, item: string, parent: string, ord: number) =>
      call<{ rev: number }>('POST', `/${enc(doc)}/items/${enc(item)}/move`, { rev, parent, ord }),
    remove: (doc: string, rev: number, item: string) =>
      call<{ rev: number }>('DELETE', `/${enc(doc)}/items/${enc(item)}?rev=${rev}`),
    edit: (doc: string, item: string, field: 'title' | 'body', value: string, rev: number) =>
      call<{ item_rev: number }>('PATCH', `/${enc(doc)}/items/${enc(item)}`, { field, value, rev }),
    /** test hook (mock only): another writer moves the doc rev on */
    async bumpForTest(doc: string): Promise<number> {
      return api.mock ? (await mock()).mockDocTreeBumpRev(doc) : 0
    },
  }
}

export type DocTreeClient = ReturnType<typeof useDocTree>

/**
 * indent / outdent / up / down as one move: prev is the item's previous
 * sibling, parent its parent item (undefined at the top level), count the
 * number of its siblings including itself (0 = unknown). null = not possible.
 */
export function moveTarget(kind: DocMoveKind, it: DocItem, prev: DocItem | undefined, parent: DocItem | undefined, count: number): { parent: string, ord: number } | null {
  switch (kind) {
    case 'indent': return prev ? { parent: prev.id, ord: 0 } : null
    case 'outdent': return parent ? { parent: parent.parent, ord: parent.ord + 1 } : null
    case 'up': return it.ord > 1 ? { parent: it.parent, ord: it.ord - 1 } : null
    case 'down': return count === 0 || it.ord < count ? { parent: it.parent, ord: it.ord + 1 } : null
  }
}

/**
 * One open document: the client, the doc rev both views send as the
 * structural precondition, and the outcome of the last op. A 412 sets stale
 * (the page shows its reload prompt); 404 / 422 / 413 / anything else set
 * error to the i18n key that says it.
 */
export type DocSession = {
  client: DocTreeClient
  doc: string
  rev: Ref<number>
  stale: Ref<boolean>
  error: Ref<string>
  run: <T>(fn: () => Promise<T>) => Promise<T | null>
}

export function createDocSession(client: DocTreeClient, doc: string): DocSession {
  const rev = ref(0)
  const stale = ref(false)
  const error = ref('')
  async function run<T>(fn: () => Promise<T>): Promise<T | null> {
    error.value = ''
    try {
      return await fn()
    } catch (e) {
      const status = e instanceof DocTreeError ? e.status : 0
      if (status === 412) stale.value = true
      else error.value = status === 404 ? 'ws_doctree.err_gone' : status === 422 ? 'ws_doctree.err_refused' : status === 413 ? 'ws_doctree.err_too_large' : 'ws_doctree.err_failed'
      return null
    }
  }
  return { client, doc, rev, stale, error, run }
}

export type DocMenuId = 'add_sibling' | 'add_child' | 'add_parent' | DocMoveKind | 'print' | 'delete'

/** The item menu both views open (a row's ... button or right-click). */
export function docMenuItems(can: Record<DocMoveKind, boolean>): PointMenuItem[] {
  const off = (k: DocMoveKind) => (can[k] ? {} : { disabled: true, hintKey: 'ws_doctree.menu.cannot_' + k })
  return [
    { id: 'add_sibling', icon: 'plus', labelKey: 'ws_doctree.menu.add_sibling' },
    { id: 'add_child', icon: 'subtask-add', labelKey: 'ws_doctree.menu.add_child' },
    { id: 'add_parent', icon: 'parent', labelKey: 'ws_doctree.menu.add_parent' },
    { id: 'indent', icon: 'chevron-right', labelKey: 'ws_doctree.menu.indent', ...off('indent') },
    { id: 'outdent', icon: 'chevron-left', labelKey: 'ws_doctree.menu.outdent', ...off('outdent') },
    { id: 'up', icon: 'chevron-up', labelKey: 'ws_doctree.menu.up', ...off('up') },
    { id: 'down', icon: 'chevron-down', labelKey: 'ws_doctree.menu.down', ...off('down') },
    { id: 'print', icon: 'file-text', labelKey: 'ws_doctree.menu.print' },
    { id: 'delete', icon: 'delete', labelKey: 'ws_doctree.menu.delete', danger: true },
  ]
}

/** Where an item sits: its previous sibling, its parent item (none at the
    top level) and how many siblings it has, itself included. */
export type DocShape = { prev?: DocItem, parent?: DocItem, count: number }

/**
 * A menu op other than print and delete, through the session: an add
 * (titled untitled) or a move. Returns the new item's id and the item to
 * expand so the result stays in view, or null when it did not commit.
 */
export async function runDocOp(s: DocSession, op: Exclude<DocMenuId, 'print' | 'delete'>, it: DocItem, shape: DocShape, untitled: string): Promise<{ item?: string, expand?: string } | null> {
  if (op === 'add_sibling' || op === 'add_child' || op === 'add_parent') {
    const where = op.slice(4) as DocWhere
    const r = await s.run(() => s.client.add(s.doc, s.rev.value, it.id, where, untitled))
    if (!r) return null
    s.rev.value = r.rev
    return { item: r.item, expand: where === 'child' ? it.id : where === 'parent' ? r.item : undefined }
  }
  const to = moveTarget(op, it, shape.prev, shape.parent, shape.count)
  if (!to) return null
  const r = await s.run(() => s.client.move(s.doc, s.rev.value, it.id, to.parent, to.ord))
  if (!r) return null
  s.rev.value = r.rev
  return { expand: op === 'indent' ? to.parent : undefined }
}

/** delete branch: the item and everything under it. */
export async function removeDocItem(s: DocSession, it: DocItem): Promise<boolean> {
  const r = await s.run(() => s.client.remove(s.doc, s.rev.value, it.id))
  if (r) s.rev.value = r.rev
  return Boolean(r)
}

/** a text edit under the item's own rev; the item is updated in place. */
export async function editDocItem(s: DocSession, it: DocItem, field: 'title' | 'body', value: string): Promise<boolean> {
  if (it[field] === value) return true
  const r = await s.run(() => s.client.edit(s.doc, it.id, field, value, it.rev))
  if (!r) return false
  it[field] = value
  it.rev = r.item_rev
  return true
}
