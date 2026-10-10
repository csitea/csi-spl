/* The doctree hub client (spec 113 T004 routes, /v1/workspace/doctree): one
   call per op, the doc rev the page read as every structural op's
   precondition. The mock tenant answers from -doctree-mock.ts, loaded on its
   first call. The `-` prefix keeps Nuxt from registering this file as a
   component. */
import { ref, type Ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'
import { docFetchTimeoutMs } from '~/utils/fetch-timeouts.mjs'

export type DocHead = { id: string, title: string, description?: string, rev: number, items: number, root: string, topic_id: string, updated_at: string }
export type DocItem = { id: string, parent: string, ord: number, outline: string, depth: number, title: string, body: string, attrs: Record<string, unknown>, rev: number }
export type DocChildren = { doc: string, rev: number, parent: string, path: number[], outline: string, items: DocItem[] }
export type DocGrid = { doc: string, rev: number, total: number, items: DocItem[] }
export type DocHit = { doc: string, item: string, title: string, rank: number }
export type DocWhere = 'sibling' | 'parent' | 'child'
export type DocMoveKind = 'indent' | 'outdent' | 'up' | 'down'
/** attrs is the item's JSON object as a string: its code block (src) and image (img_http_path, img_name) */
export type DocField = 'title' | 'body' | 'attrs'

/** the hub's own image route: an uploaded image's img_http_path starts with it */
export const HUB_IMAGE_PREFIX = '/v1/workspace/doctree/'

/** the image types the hub stores (no svg) and its size cap */
export const DOC_IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp']
export const DOC_IMAGE_MAX = 5 << 20

/** A refused call: 412 stale (reload), 404 gone, 422 refused, 413 too large. */
export class DocTreeError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message)
  }
}

type Mock = typeof import('./-doctree-mock')
let mockMod: Promise<Mock> | null = null

type SpoolApi = ReturnType<typeof useSpoolApi>

/** the image half of the client: an image's src for an <img>, and the upload */
function docImages(api: SpoolApi, mock: () => Promise<Mock>) {
  /* an image's src: an https URL as is; a hub path (the upload's
     img_http_path) read with the session's credentials into an object URL,
     since an <img> cannot send the Authorization header. Cached per path. */
  const images = new Map<string, Promise<string>>()
  function imageSrc(path: string): Promise<string> {
    if (!path.startsWith(HUB_IMAGE_PREFIX)) return Promise.resolve(path.startsWith('https://') ? path : '')
    let p = images.get(path)
    if (!p) {
      p = api.mock
        ? mock().then((m) => m.mockDocTreeImageUrl(path))
        : fetch(`${api.base}${path}`, {
          headers: api.token ? { authorization: `Bearer ${api.token}` } : {},
          credentials: api.credentials,
          signal: AbortSignal.timeout(docFetchTimeoutMs('GET')),
        }).then(async (r) => (r.ok ? URL.createObjectURL(await r.blob()) : ''))
      p = p.catch(() => '')
      images.set(path, p)
    }
    return p
  }

  /** POST the image's bytes as they are; the answer's img_http_path is the item's attrs value */
  async function uploadImage(doc: string, file: Blob): Promise<{ name: string, img_http_path: string }> {
    if (api.mock) {
      const r = (await mock()).mockDocTreeImage(doc, file)
      if (r.status !== 200) throw new DocTreeError(r.status, 'bad_image', 'refused image')
      return r.body as { name: string, img_http_path: string }
    }
    const headers: Record<string, string> = { 'content-type': file.type }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const r = await fetch(`${api.base}/v1/workspace/doctree/${encodeURIComponent(doc)}/images`, {
      method: 'POST', headers, credentials: api.credentials, body: file,
      signal: AbortSignal.timeout(docFetchTimeoutMs('POST')),
    })
    const out = await r.json().catch(() => ({})) as { error?: string, message?: string, name?: string, img_http_path?: string }
    if (!r.ok) throw new DocTreeError(r.status, out.error || 'error', out.message || `doctree ${r.status}`)
    return { name: out.name || '', img_http_path: out.img_http_path || '' }
  }
  return { imageSrc, uploadImage }
}

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

  const { imageSrc, uploadImage } = docImages(api, mock)

  const enc = encodeURIComponent
  return {
    imageSrc,
    uploadImage,
    /** rename the document under the doc rev read; '' gives the default title */
    rename: (doc: string, rev: number, title: string) => call<{ rev: number, title: string }>('PATCH', `/${enc(doc)}`, { title, rev }),
    list: () => call<{ docs: DocHead[] }>('GET', '').then((r) => r.docs),
    /** description is the meta description (rdb 0164), '' = none */
    create: (title: string, description = '') => call<{ id: string, root: string, rev: number }>('POST', '', { title, description }),
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
    edit: (doc: string, item: string, field: DocField, value: string, rev: number) =>
      call<{ item_rev: number }>('PATCH', `/${enc(doc)}/items/${enc(item)}`, { field, value, rev }),
    /** Qto's search on Enter: the items of every document (doc '' ) or one, best first */
    search: (q: string, doc = '') => call<{ hits: DocHit[] }>('GET', `/search?q=${enc(q.trim())}${doc ? '&doc=' + enc(doc) : ''}`).then((r) => r.hits),
    /** test hook (mock only): another writer's raw call, behind the page's back */
    async callForTest(method: string, path: string, body?: Record<string, unknown>): Promise<unknown> {
      return api.mock ? call(method, path, body) : null
    },
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

/**
 * The starter outline of a new document (the owner, t1 519a4ee9: a document
 * never starts from nothing): headings 1, 1.1 and 1.1.1, every level the
 * view draws; the view shows a paragraph placeholder under levels 2 and 3
 * only (owner msg 9debc0df). Titles and texts are empty, so the view shows
 * them as placeholders the user types over. Best effort: a
 * refused add leaves the document as far as it got.
 */
export async function seedStarterDoc(client: DocTreeClient, doc: string, rev: number): Promise<void> {
  let r = rev
  const add = async (anchor: string, where: DocWhere) => {
    const out = await client.add(doc, r, anchor, where, '')
    r = out.rev
    return out.item
  }
  try {
    const h1 = await add('', 'child')
    const h11 = await add(h1, 'child')
    await add(h11, 'child')
  } catch { /* the document opens with what was added */ }
}

/** delete branch: the item and everything under it. */
export async function removeDocItem(s: DocSession, it: DocItem): Promise<boolean> {
  const r = await s.run(() => s.client.remove(s.doc, s.rev.value, it.id))
  if (r) s.rev.value = r.rev
  return Boolean(r)
}

/**
 * set (a string) or drop ('') attrs keys of an item, the others kept, as one
 * attrs edit under the item's rev; the item is updated in place.
 */
export async function editDocAttrs(s: DocSession, it: DocItem, set: Record<string, string>): Promise<boolean> {
  const next: Record<string, unknown> = { ...(it.attrs || {}) }
  for (const [k, v] of Object.entries(set)) {
    if (v) next[k] = v
    else delete next[k]
  }
  const value = JSON.stringify(next)
  if (value === JSON.stringify(it.attrs || {})) return true
  const r = await s.run(() => s.client.edit(s.doc, it.id, 'attrs', value, it.rev))
  if (!r) return false
  it.attrs = next
  it.rev = r.item_rev
  return true
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
