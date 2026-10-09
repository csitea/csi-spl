/* The mock tenant's doctree (spec 113 T006): /v1/workspace/doctree answered
   in memory, the same routes, wire shapes and four outcomes as the hub
   (csi-spl-api internal/hub/wsdoc_tree.go): committed (200 + the doc rev it
   produced), 412 stale_rev, 404 not_found, 422 refused. CI's e2e runs on the
   mock bundle, so this is what the doc and grid views are driven against.
   The `-` prefix keeps Nuxt from registering this file as a component. */

export type MockReply = { status: number, body: unknown }

type Item = { id: string, parent: string, ord: number, title: string, body: string, attrs: Record<string, unknown>, rev: number }
type Doc = { id: string, title: string, rev: number, root: string, items: Map<string, Item>, updated: string }
type Wire = { id: string, parent: string, ord: number, outline: string, depth: number, title: string, body: string, attrs: Record<string, unknown>, rev: number }
type Body = Record<string, unknown>

const docs = new Map<string, Doc>()
let seq = 0

function uuid(): string {
  seq++
  return `00000000-0000-4000-8000-${seq.toString(16).padStart(12, '0')}`
}

function fail(status: number, code: string, message: string): MockReply {
  return { status, body: { error: code, message } }
}

const STALE = (): MockReply => fail(412, 'stale_rev', 'the document changed since you read it: reload')
const GONE = (): MockReply => fail(404, 'not_found', 'no such document or item')

function kids(d: Doc, parent: string): Item[] {
  return [...d.items.values()].filter((it) => it.parent === parent).sort((a, b) => a.ord - b.ord)
}

/** item with its outline (1 / 1.1 / 1.1.1) and depth, as the hub's docTreeItem */
function wire(d: Doc, it: Item): Wire {
  const path: number[] = []
  let cur: Item | undefined = it
  while (cur && cur.parent) {
    path.unshift(cur.ord)
    cur = d.items.get(cur.parent)
  }
  return { id: it.id, parent: it.parent, ord: it.ord, outline: path.join('.'), depth: path.length, title: it.title, body: it.body, attrs: it.attrs, rev: it.rev }
}

/** item and everything under it, in document order */
function subtree(d: Doc, id: string): Item[] {
  const it = d.items.get(id)
  if (!it) return []
  const out = [it]
  for (const k of kids(d, id)) out.push(...subtree(d, k.id))
  return out
}

function head(d: Doc) {
  const root = d.items.get(d.root)
  return { id: d.id, title: d.title, rev: d.rev, items: d.items.size - 1, root: d.root, topic_id: String(root?.attrs.topic_id ?? ''), updated_at: d.updated }
}

function bump(d: Doc): number {
  d.rev++
  d.updated = new Date().toISOString()
  return d.rev
}

/** close the gaps: 1..n under parent */
function renumber(d: Doc, parent: string) {
  kids(d, parent).forEach((k, i) => { k.ord = i + 1 })
}

function create(title: string): Doc {
  const d: Doc = { id: uuid(), title, rev: 1, root: uuid(), items: new Map(), updated: new Date().toISOString() }
  d.items.set(d.root, { id: d.root, parent: '', ord: 1, title: '', body: '', attrs: {}, rev: 1 })
  docs.set(d.id, d)
  return d
}

/** a slot under parent at ord (0 or past the end = last), siblings shifted */
function slot(d: Doc, parent: string, ord: number): number {
  const sib = kids(d, parent)
  const at = ord < 1 || ord > sib.length + 1 ? sib.length + 1 : ord
  for (const s of sib) if (s.ord >= at) s.ord++
  return at
}

function insert(d: Doc, parent: string, ord: number, title: string, body = ''): Item {
  const it: Item = { id: uuid(), parent, ord: slot(d, parent, ord), title, body, attrs: {}, rev: 1 }
  d.items.set(it.id, it)
  return it
}

function seed() {
  if (docs.size) return
  const d = create('Handbook')
  const a = insert(d, d.root, 0, 'Introduction', 'Why this document exists: one place for how the team works, read top to bottom or by section.')
  const sc = insert(d, a.id, 0, 'Scope', 'What the handbook covers and what it leaves to other documents.')
  insert(d, sc.id, 0, 'In scope', 'Day-to-day operations, releases and the on-call rota.')
  insert(d, sc.id, 0, 'Out of scope', 'Contracts, pricing and anything a customer signs.')
  insert(d, a.id, 0, 'Audience', 'Everyone in the workspace; new members start here.')
  const b = insert(d, d.root, 0, 'Operations', 'How a change goes from a commit to production.')
  const dep = insert(d, b.id, 0, 'Deploy', 'Every deploy is one command, first to dev and then to prd.')
  dep.attrs = { src: 'ENV=dev ./run -a do_deploy\nENV=prd ./run -a do_deploy' }
  insert(d, d.root, 0, 'Glossary', 'The words this handbook uses, in one list.')
}

/** the structural precondition: 0 = none, else the doc rev the caller read */
const stale = (d: Doc, rev: number) => rev !== 0 && rev !== d.rev
const str = (v: unknown) => (typeof v === 'string' ? v : '')
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : 0)

function add(d: Doc, b: Body): MockReply {
  if (stale(d, num(b.rev))) return STALE()
  const anchor = d.items.get(str(b.anchor) || d.root)
  if (!anchor) return GONE()
  const where = str(b.where)
  let it: Item
  if (where === 'child') it = insert(d, anchor.id, num(b.ord), str(b.title), str(b.body))
  else if (where === 'sibling') {
    if (!anchor.parent) return fail(422, 'refused', 'refused: the root has no siblings')
    it = insert(d, anchor.parent, anchor.ord + 1, str(b.title), str(b.body))
  } else if (where === 'parent') {
    if (!anchor.parent) return fail(422, 'refused', 'refused: the root has no parent')
    /* in the anchor's place; the anchor becomes its only child */
    it = { id: uuid(), parent: anchor.parent, ord: anchor.ord, title: str(b.title), body: str(b.body), attrs: {}, rev: 1 }
    anchor.parent = it.id
    anchor.ord = 1
    d.items.set(it.id, it)
  } else return fail(422, 'refused', 'refused: where is sibling, parent or child')
  return { status: 200, body: { rev: bump(d), item: it.id } }
}

function move(d: Doc, id: string, b: Body): MockReply {
  if (stale(d, num(b.rev))) return STALE()
  const it = d.items.get(id)
  const parent = d.items.get(str(b.parent) || d.root)
  if (!it || !parent) return GONE()
  if (!it.parent) return fail(422, 'refused', 'refused: the root does not move')
  if (subtree(d, id).some((x) => x.id === parent.id)) return fail(422, 'refused', 'refused: a move into its own subtree')
  const from = it.parent
  it.parent = ''
  it.ord = 0
  renumber(d, from)
  it.ord = slot(d, parent.id, num(b.ord))
  it.parent = parent.id
  return { status: 200, body: { rev: bump(d), item: id } }
}

function remove(d: Doc, id: string, rev: number): MockReply {
  if (stale(d, rev)) return STALE()
  const it = d.items.get(id)
  if (!it) return GONE()
  if (!it.parent) return fail(422, 'refused', 'refused: the root is not deleted')
  for (const x of subtree(d, id)) d.items.delete(x.id)
  renumber(d, it.parent)
  return { status: 200, body: { rev: bump(d), item: id } }
}

/** a text edit: the item rev is the precondition, the doc rev does not move */
function edit(d: Doc, id: string, b: Body): MockReply {
  const it = d.items.get(id)
  if (!it) return GONE()
  if (num(b.rev) !== it.rev) return STALE()
  const field = str(b.field)
  const value = str(b.value)
  if (field === 'title') it.title = value
  else if (field === 'body') it.body = value
  else if (field === 'attrs') {
    const attrs = parseAttrs(value)
    if (!attrs) return fail(422, 'refused', 'refused: attrs is not a JSON object the hub takes')
    it.attrs = attrs
  } else return fail(422, 'refused', `refused: field "${field}" is not editable`)
  it.rev++
  return { status: 200, body: { item_rev: it.rev } }
}

/** the hub's attrs gate (store.docAttrsCheck): an object, kind code | image,
    string keys, img_http_path an https URL or a hub image path */
function parseAttrs(value: string): Record<string, unknown> | null {
  let m: unknown
  try { m = JSON.parse(value) } catch { return null }
  if (!m || typeof m !== 'object' || Array.isArray(m)) return null
  const a = m as Record<string, unknown>
  if ('kind' in a && a.kind !== 'code' && a.kind !== 'image') return null
  for (const k of ['kind', 'src', 'lang', 'img_name', 'img_http_path']) if (k in a && typeof a[k] !== 'string') return null
  const p = str(a.img_http_path)
  if (p && !p.startsWith('https://') && !p.startsWith('/v1/workspace/doctree/')) return null
  return a
}

/** rename: the doc rev is the precondition; '' or blanks give the default */
function rename(d: Doc, b: Body): MockReply {
  if (stale(d, num(b.rev))) return STALE()
  const title = str(b.title).trim() || UNTITLED
  if (title.length > 500) return fail(400, 'bad_request', 'title is at most 500 characters')
  d.title = title
  return { status: 200, body: { rev: bump(d), title } }
}

const UNTITLED = 'Untitled document'

/* the uploaded images: hub path -> an object URL of the bytes */
const images = new Map<string, string>()
const IMAGE_EXT: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' }

/** test hook and the upload's mock twin: the hub's types and 5 MiB cap; the
    name is a stand-in for the hub's sha256 (unique per upload here) */
export function mockDocTreeImage(doc: string, file: Blob): MockReply {
  seed()
  if (!docs.has(doc)) return GONE()
  const ext = IMAGE_EXT[file.type]
  if (!ext) return fail(415, 'bad_image', 'an image is png, jpeg, gif or webp')
  if (file.size > 5 << 20) return fail(413, 'too_large', 'an image is at most 5242880 bytes')
  if (!file.size) return fail(400, 'bad_body', 'the image bytes did not arrive')
  const name = uuid().replace(/-/g, '').padEnd(64, '0') + '.' + ext
  const path = `/v1/workspace/doctree/${doc}/images/${name}`
  images.set(path, URL.createObjectURL(file))
  return { status: 200, body: { name, bytes: file.size, img_http_path: path } }
}

/** an uploaded image's object URL ('' = none) */
export function mockDocTreeImageUrl(path: string): string {
  return images.get(path) || ''
}

const SORTS: Record<string, (a: Wire, b: Wire) => number> = {
  title: (a, b) => a.title.toLowerCase().localeCompare(b.title.toLowerCase()),
  body: (a, b) => a.body.toLowerCase().localeCompare(b.body.toLowerCase()),
  rev: (a, b) => a.rev - b.rev,
  depth: (a, b) => a.depth - b.depth,
}

function grid(d: Doc, q: URLSearchParams): MockReply {
  const sort = q.get('sort') || 'outline'
  const cmp = SORTS[sort]
  if (sort !== 'outline' && !cmp) return fail(400, 'bad_query', 'sort is outline, title, body, rev, depth or attr:<key>')
  const needle = (q.get('q') || '').trim().toLowerCase()
  let rows = subtree(d, d.root).slice(1).map((it) => wire(d, it))
  if (needle) rows = rows.filter((r) => r.title.toLowerCase().includes(needle) || r.body.toLowerCase().includes(needle) || r.outline.startsWith(needle))
  const desc = q.get('desc') === '1'
  if (cmp) rows = rows.map((r, i) => ({ r, i })).sort((a, b) => (desc ? cmp(b.r, a.r) : cmp(a.r, b.r)) || a.i - b.i).map((x) => x.r)
  else if (desc) rows.reverse()
  return { status: 200, body: { doc: d.id, rev: d.rev, total: rows.length, items: rows } }
}

function reads(d: Doc, sub: string, q: URLSearchParams): MockReply {
  if (!sub) return { status: 200, body: head(d) }
  if (sub === 'children') {
    const parent = d.items.get(q.get('parent') || d.root)
    if (!parent) return GONE()
    const at = wire(d, parent)
    const path = at.outline ? at.outline.split('.').map(Number) : []
    return { status: 200, body: { doc: d.id, rev: d.rev, parent: parent.id, path, outline: at.outline, items: kids(d, parent.id).map((k) => wire(d, k)) } }
  }
  if (sub === 'subtree') {
    const from = q.get('item') || ''
    if (from && !d.items.has(from)) return GONE()
    const rows = subtree(d, from || d.root)
    return { status: 200, body: { doc: d.id, rev: d.rev, items: (from ? rows : rows.slice(1)).map((it) => wire(d, it)) } }
  }
  if (sub === 'grid') return grid(d, q)
  return fail(404, 'not_found', 'no such route')
}

/**
 * One hub call: the method, the path after /v1/workspace/doctree (with its
 * query) and the JSON body. Same status codes and bodies as the hub.
 */
export function mockDocTree(method: string, path: string, body: Body = {}): MockReply {
  seed()
  const url = new URL(path || '/', 'http://mock.invalid')
  const [docId, sub = '', id = '', verb = ''] = url.pathname.split('/').filter(Boolean)
  if (!docId && method === 'GET') return { status: 200, body: { docs: [...docs.values()].map(head) } }
  if (docId === 'search' && method === 'GET') {
    const q = (url.searchParams.get('q') || '').trim().toLowerCase()
    if (!q) return fail(400, 'bad_query', 'q is 1..200 characters')
    const only = url.searchParams.get('doc') || ''
    const hits: { doc: string, item: string, title: string, rank: number }[] = []
    for (const d of docs.values()) {
      if (only && d.id !== only) continue
      for (const it of d.items.values()) {
        if (it.parent && (it.title.toLowerCase().includes(q) || it.body.toLowerCase().includes(q))) hits.push({ doc: d.id, item: it.id, title: it.title, rank: it.title.toLowerCase().includes(q) ? 1 : 0.5 })
      }
    }
    hits.sort((a, b) => b.rank - a.rank)
    return { status: 200, body: { hits: hits.slice(0, 100) } }
  }
  if (!docId && method === 'POST') {
    const title = str(body.title).trim() || UNTITLED
    if (title.length > 500) return fail(400, 'bad_request', 'title is at most 500 characters')
    const d = create(title)
    return { status: 200, body: { id: d.id, root: d.root, rev: 1 } }
  }
  const d = docs.get(docId || '')
  if (!d) return GONE()
  if (method === 'GET') return reads(d, sub, url.searchParams)
  if (!sub && method === 'PATCH') return rename(d, body)
  if (sub === 'items' && method === 'POST' && !id) return add(d, body)
  if (sub === 'items' && method === 'POST' && verb === 'move') return move(d, id, body)
  if (sub === 'items' && method === 'DELETE' && id) return remove(d, id, Number(url.searchParams.get('rev') || 0))
  if (sub === 'items' && method === 'PATCH' && id) return edit(d, id, body)
  return fail(404, 'not_found', 'no such route')
}

/** test hook (mock only): another writer commits a structural op, so the
    page's doc rev goes stale and its next structural op answers 412 */
export function mockDocTreeBumpRev(doc: string): number {
  const d = docs.get(doc)
  return d ? bump(d) : 0
}
