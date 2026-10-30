import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { HUB_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

/**
 * Spec 155 2.6 (B5, SPL-4123): the person's own notes, from the hub's realm
 * routes (section 5, B4):
 *   GET  /v1/me/realm/notes   every note as a summary, archived ones too
 *   POST /v1/me/realm/notes   a new note
 * and, for the open note (B6, SPL-4186):
 *   GET    /v1/me/realm/notes/{id}        the note with its checklist and links
 *   PATCH  /v1/me/realm/notes/{id}        title, body, pinned, archived, position
 *   PUT    /v1/me/realm/notes/{id}/items  the whole checklist, in order
 *   DELETE /v1/me/realm/notes/{id}        sent when the Undo toast ends (D2)
 * A realm route takes the person from the session alone and refuses a
 * request naming a workspace (X-Spool-Tenant), so none is sent. The kill
 * switch (section 6) answers 404 `notes_off`: the store reads it as `off`.
 * The mock answers from a small list kept in memory, so the page works on
 * the mock bundle before the hub serves it. Links (B7) and the rest call
 * the same routes from here:
 *   POST   /v1/me/realm/notes/{id}/links            one more link (B7, SPL-4330)
 *   DELETE /v1/me/realm/notes/{id}/links/{link_id}  one link
 */

/** A list row, as the hub writes it (hub/realm_notes.go noteSummaryJSON). */
export type NoteSummary = {
  id: string
  title: string
  snippet: string
  pinned: boolean
  position: number
  archived: boolean
  archived_at?: string
  updated_at: string
  items_done: number
  items_total: number
  link_count: number
}

/** A checklist line (hub/realm_notes.go noteItemJSON). */
export type NoteItem = { id: string, text: string, done: boolean, position?: number }

/** A link (hub/realm_notes.go noteLinkJSON): a typed ref, spec 155 2.3. `left`: a workspace the person left (D4). */
export type NoteLink = {
  id: string
  kind: 'msg' | 'topic' | 'issue' | 'event' | 'doc' | 'channel' | 'url'
  workspace_id?: string
  ref: string
  day?: string
  label: string
  left?: boolean
  position?: number
  created_at?: string
}

/** A link as POST takes it: no id yet. */
export type NoteLinkIn = Omit<NoteLink, 'id' | 'left' | 'position' | 'created_at'>

/** A whole note, as GET / PATCH / PUT items answer it (noteJSON). */
export type Note = {
  id: string
  title: string
  body: string
  pinned: boolean
  position: number
  archived: boolean
  archived_at?: string
  created_at?: string
  updated_at: string
  items: NoteItem[]
  links: NoteLink[]
}

/** The fields PATCH takes; the others are kept. */
export type NotePatch = Partial<Pick<Note, 'title' | 'body' | 'pinned' | 'archived' | 'position'>>

type NotesApi = { base: string, token?: string, credentials?: RequestCredentials, mock?: boolean }

/** A refusal as an Error with the hub's `status` and `error` token. */
async function refusal(r: Response, what: string) {
  let token = ''
  try { token = String((await r.json())?.error || '') } catch { /* not json */ }
  return Object.assign(new Error(`${what} ${r.status}`), { status: r.status, token })
}

function notesUrl(api: NotesApi, tail = '') {
  return `${String(api.base).replace(/\/+$/, '')}/v1/me/realm/notes${tail}`
}

function headersOf(api: NotesApi, extra: Record<string, string> = {}) {
  const h: Record<string, string> = { accept: 'application/json', ...extra }
  if (api.token) h.authorization = `Bearer ${api.token}`
  return h
}

const mockItems = (texts: string[], done: number): NoteItem[] => texts.map((text, i) => ({ id: `mock-item-${i + 1}`, text, done: i < done, position: i }))
const mockLinks = (n: number): NoteLink[] => Array.from({ length: n }, (_, i) => ({ id: `mock-link-${i + 1}`, kind: 'url', ref: `https://example.com/${i + 1}`, label: '' }))

const MOCK_NOTES: Note[] = [
  { id: 'mock-note-1', title: 'Release checklist', body: 'Things to check before the next release.', pinned: true, position: 1, archived: false, updated_at: '2026-10-28T09:00:00Z', items: mockItems(['Tests green', 'Docs updated', 'Dev deployed', 'Prd deployed', 'Release note'], 2), links: mockLinks(3) },
  { id: 'mock-note-2', title: 'Ideas', body: 'A shorter onboarding page.', pinned: false, position: 2, archived: false, updated_at: '2026-10-27T15:30:00Z', items: [], links: mockLinks(1) },
  { id: 'mock-note-3', title: '', body: 'Call back about the invoice\nand the new address', pinned: false, position: 3, archived: false, updated_at: '2026-10-26T08:10:00Z', items: [], links: [] },
  { id: 'mock-note-4', title: 'Old plan', body: 'Kept for reference.', pinned: false, position: 4, archived: true, archived_at: '2026-10-20T12:00:00Z', updated_at: '2026-10-20T12:00:00Z', items: mockItems(['Draft'], 1), links: [] },
]

/** The list row of a whole note (the hub's noteSummaryOut). */
export function summaryOf(n: Note): NoteSummary {
  return {
    id: n.id, title: n.title || '', snippet: String(n.body || '').slice(0, 200), pinned: Boolean(n.pinned), position: Number(n.position) || 0,
    archived: Boolean(n.archived), archived_at: n.archived_at, updated_at: n.updated_at,
    items_done: (n.items || []).filter((i) => i.done).length, items_total: (n.items || []).length, link_count: (n.links || []).length,
  }
}

const copyNote = (n: Note): Note => ({ ...n, items: n.items.map((i) => ({ ...i })), links: n.links.map((l) => ({ ...l })) })

/** Pinned first, each group by the person's own order (position, then newest). */
export function sortNotes(list: readonly NoteSummary[]): NoteSummary[] {
  return [...list].sort((a, b) => Number(b.pinned) - Number(a.pinned) || a.position - b.position || b.updated_at.localeCompare(a.updated_at))
}

/** The rows the filter box and the Archived switch leave, in list order. */
export function filterNotes(list: readonly NoteSummary[], query: string, archived: boolean): NoteSummary[] {
  const q = query.trim().toLowerCase()
  return sortNotes(list).filter((n) => n.archived === archived && (!q || `${n.title}\n${n.snippet}`.toLowerCase().includes(q)))
}

/** What a note read answers: the note, or why there is none. */
export type NoteRead = { note: Note } | { missing: true } | { failed: true }

/** B7: a note's link routes; a write answers the link or throws the refusal. */
function hubNoteLinks(api: NotesApi) {
  const at = (id: string, tail = '') => `/${encodeURIComponent(id)}/links${tail}`
  return {
    async addLink(id: string, link: NoteLinkIn): Promise<NoteLink> {
      const r = await fetch(notesUrl(api, at(id)), {
        method: 'POST', credentials: api.credentials, headers: headersOf(api, { 'content-type': 'application/json' }),
        body: JSON.stringify(link), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
      })
      if (!r.ok) throw await refusal(r, 'notes link add')
      return (await r.json()) as NoteLink
    },
    async removeLink(id: string, linkId: string): Promise<void> {
      const r = await fetch(notesUrl(api, at(id, '/' + encodeURIComponent(linkId))), {
        method: 'DELETE', credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
      })
      if (!r.ok && r.status !== 404) throw await refusal(r, 'notes link delete')
    },
  }
}

/** The hub's notes routes; a write answers the note or throws the refusal. */
function hubNotes(api: NotesApi) {
  const one = (id: string, tail = '') => `/${encodeURIComponent(id)}${tail}`
  async function send(tail: string, method: string, body: unknown, what: string): Promise<Note> {
    const r = await fetch(notesUrl(api, tail), {
      method, credentials: api.credentials, headers: headersOf(api, { 'content-type': 'application/json' }),
      body: JSON.stringify(body), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
    })
    if (!r.ok) throw await refusal(r, what)
    return normalNote(await r.json())
  }
  return {
    ...hubNoteLinks(api),
    async list(): Promise<NoteSummary[]> {
      const r = await fetch(notesUrl(api), { credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
      if (!r.ok) throw await refusal(r, 'notes list')
      return ((await r.json())?.notes || []) as NoteSummary[]
    },
    create: () => send('', 'POST', { title: '', body: '' }, 'notes create'),
    async get(id: string): Promise<NoteRead> {
      try {
        const r = await fetch(notesUrl(api, one(id)), { credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
        if (r.status === 404) return { missing: true }
        return r.ok ? { note: normalNote(await r.json()) } : { failed: true }
      } catch {
        return { failed: true }
      }
    },
    patch: (id: string, fields: NotePatch) => send(one(id), 'PATCH', fields, 'notes patch'),
    putItems: (id: string, items: NoteItem[]) => send(one(id, '/items'), 'PUT', { items: items.map((i) => ({ id: i.id.startsWith('new-') ? '' : i.id, text: i.text, done: i.done })) }, 'notes items'),
    async remove(id: string, keepalive: boolean): Promise<boolean> {
      try {
        const r = await fetch(notesUrl(api, one(id)), { method: 'DELETE', keepalive, credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS) })
        return r.ok || r.status === 404
      } catch {
        return false
      }
    },
  }
}

/** The mock bundle's notes: the same calls, answered from memory for the tab. */
function mockNotes(): ReturnType<typeof hubNotes> {
  let all = MOCK_NOTES.map(copyNote)
  function write(id: string, edit: (n: Note) => void): Note {
    const n = all.find((x) => x.id === id)
    if (!n) throw Object.assign(new Error('notes 404'), { status: 404, token: 'not_found' })
    edit(n)
    n.updated_at = new Date().toISOString()
    return copyNote(n)
  }
  return {
    list: async () => all.map(summaryOf),
    async create() {
      const position = Math.min(0, ...all.map((n) => n.position)) - 1
      const note: Note = { id: `mock-note-${Date.now()}`, title: '', body: '', pinned: false, position, archived: false, updated_at: new Date().toISOString(), items: [], links: [] }
      all = [note, ...all]
      return copyNote(note)
    },
    async get(id: string) {
      const n = all.find((x) => x.id === id)
      return n ? { note: copyNote(n) } : { missing: true as const }
    },
    patch: async (id: string, fields: NotePatch) => write(id, (n) => {
      Object.assign(n, fields)
      if (fields.archived !== undefined) n.archived_at = fields.archived ? new Date().toISOString() : undefined
    }),
    putItems: async (id: string, items: NoteItem[]) => write(id, (n) => {
      n.items = items.map((i, k) => ({ ...i, id: i.id.startsWith('new-') ? `mock-item-${Date.now()}-${k}` : i.id, position: k }))
    }),
    async addLink(id: string, link: NoteLinkIn) {
      const added: NoteLink = { ...link, label: link.label || '', id: `mock-link-${Date.now()}`, left: false }
      write(id, (n) => { n.links = [...n.links, { ...added, position: n.links.length }] })
      return added
    },
    async removeLink(id: string, linkId: string) {
      write(id, (n) => { n.links = n.links.filter((l) => l.id !== linkId) })
    },
    async remove(id: string) {
      all = all.filter((n) => n.id !== id)
      return true
    },
  }
}

/** B7: add and remove one link; the list row's link count follows. A refusal is thrown. */
function linkActions(wire: () => ReturnType<typeof hubNotes>, notes: Ref<NoteSummary[]>) {
  const count = (id: string, by: number) => {
    notes.value = notes.value.map((n) => (n.id === id ? { ...n, link_count: Math.max(0, n.link_count + by) } : n))
  }
  return {
    async addLink(id: string, link: NoteLinkIn): Promise<NoteLink> {
      const added = await wire().addLink(id, link)
      count(id, 1)
      return added
    },
    async removeLink(id: string, linkId: string): Promise<void> {
      await wire().removeLink(id, linkId)
      count(id, -1)
    },
  }
}

export const useNotesStore = defineStore('notes', () => {
  const api = useSpoolApi() as unknown as NotesApi
  /* chosen per call, as before B6: the mock flag is the client's, read when it is used */
  const hub = hubNotes(api)
  let mock: ReturnType<typeof mockNotes> | null = null
  const wire = () => (api.mock ? (mock ??= mockNotes()) : hub)
  const notes = ref<NoteSummary[]>([])
  const state = ref<'idle' | 'loading' | 'ready' | 'failed' | 'off'>('idle')
  /* D2: a deleted note waiting for its Undo toast to end; the list leaves it out */
  const hidden = ref<string[]>([])
  let seq = 0

  async function load() {
    const mine = ++seq
    if (state.value !== 'ready') state.value = 'loading'
    try {
      const got = await wire().list()
      if (mine !== seq) return
      notes.value = got.filter((n) => !hidden.value.includes(n.id))
      state.value = 'ready'
    } catch (e) {
      if (mine !== seq) return
      state.value = (e as { token?: string }).token === 'notes_off' ? 'off' : 'failed'
    }
  }

  /** A new, empty note on top of the list; its id, or '' when the hub refused. */
  async function create(): Promise<string> {
    try {
      return keep(await wire().create()).id
    } catch {
      return ''
    }
  }

  /** The list row follows what the hub answered; a new note goes on top. */
  function keep(n: Note): Note {
    const row = summaryOf(n)
    notes.value = notes.value.some((x) => x.id === n.id) ? notes.value.map((x) => (x.id === n.id ? row : x)) : [row, ...notes.value]
    return n
  }

  /** B6: the open note with its checklist; a 404 (or a deleted one) is "Note not found". */
  async function get(id: string): Promise<NoteRead> {
    return hidden.value.includes(id) ? { missing: true } : wire().get(id)
  }

  /** PATCH title, body, pinned, archived or position; the saved note, or a refusal thrown. */
  const patch = async (id: string, fields: NotePatch) => keep(await wire().patch(id, fields))
  /** PUT the whole checklist, in the order given. */
  const putItems = async (id: string, items: NoteItem[]) => keep(await wire().putItems(id, items))

  /** D2: Delete takes the note off the list at once; the DELETE waits for the toast. */
  function hide(id: string) {
    if (!hidden.value.includes(id)) hidden.value = [...hidden.value, id]
    const row = notes.value.find((n) => n.id === id)
    notes.value = notes.value.filter((n) => n.id !== id)
    return row
  }

  /** Undo: the note is back where it was; nothing was sent. */
  function unhide(row: NoteSummary) {
    hidden.value = hidden.value.filter((x) => x !== row.id)
    if (!notes.value.some((n) => n.id === row.id)) notes.value = [...notes.value, row]
  }

  /** The DELETE, once the toast ended or the page goes (keepalive); false when it failed. */
  async function remove(id: string, keepalive = false): Promise<boolean> {
    hidden.value = hidden.value.filter((x) => x !== id)
    notes.value = notes.value.filter((n) => n.id !== id)
    return wire().remove(id, keepalive)
  }

  return { notes, state, hidden, load, create, get, patch, putItems, ...linkActions(wire, notes), hide, unhide, remove }
})

/** A note from the hub, with the arrays always present. */
function normalNote(n: Partial<Note> & { id: string }): Note {
  return {
    id: n.id, title: n.title || '', body: n.body || '', pinned: Boolean(n.pinned), position: Number(n.position) || 0, archived: Boolean(n.archived),
    archived_at: n.archived_at, created_at: n.created_at, updated_at: n.updated_at || '', items: n.items || [], links: n.links || [],
  }
}
