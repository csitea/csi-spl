import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { HUB_READ_TIMEOUT_MS, HUB_WRITE_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

/**
 * Spec 155 2.6 (B5, SPL-4123): the person's own notes, from the hub's realm
 * routes (section 5, B4):
 *   GET  /v1/me/realm/notes   every note as a summary, archived ones too
 *   POST /v1/me/realm/notes   a new note
 * A realm route takes the person from the session alone and refuses a
 * request naming a workspace (X-Spool-Tenant), so none is sent. The kill
 * switch (section 6) answers 404 `notes_off`: the store reads it as `off`.
 * The mock answers from a small list kept in memory, so the page works on
 * the mock bundle before the hub serves it. The open note (B6), links (B7)
 * and the rest call the same routes from here.
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

const MOCK_NOTES: NoteSummary[] = [
  { id: 'mock-note-1', title: 'Release checklist', snippet: 'Things to check before the next release.', pinned: true, position: 1, archived: false, updated_at: '2026-10-28T09:00:00Z', items_done: 2, items_total: 5, link_count: 3 },
  { id: 'mock-note-2', title: 'Ideas', snippet: 'A shorter onboarding page.', pinned: false, position: 2, archived: false, updated_at: '2026-10-27T15:30:00Z', items_done: 0, items_total: 0, link_count: 1 },
  { id: 'mock-note-3', title: '', snippet: 'Call back about the invoice\nand the new address', pinned: false, position: 3, archived: false, updated_at: '2026-10-26T08:10:00Z', items_done: 0, items_total: 0, link_count: 0 },
  { id: 'mock-note-4', title: 'Old plan', snippet: 'Kept for reference.', pinned: false, position: 4, archived: true, archived_at: '2026-10-20T12:00:00Z', updated_at: '2026-10-20T12:00:00Z', items_done: 1, items_total: 1, link_count: 0 },
]

/** Pinned first, each group by the person's own order (position, then newest). */
export function sortNotes(list: readonly NoteSummary[]): NoteSummary[] {
  return [...list].sort((a, b) => Number(b.pinned) - Number(a.pinned) || a.position - b.position || b.updated_at.localeCompare(a.updated_at))
}

/** The rows the filter box and the Archived switch leave, in list order. */
export function filterNotes(list: readonly NoteSummary[], query: string, archived: boolean): NoteSummary[] {
  const q = query.trim().toLowerCase()
  return sortNotes(list).filter((n) => n.archived === archived && (!q || `${n.title}\n${n.snippet}`.toLowerCase().includes(q)))
}

export const useNotesStore = defineStore('notes', () => {
  const api = useSpoolApi() as unknown as NotesApi
  const notes = ref<NoteSummary[]>([])
  const state = ref<'idle' | 'loading' | 'ready' | 'failed' | 'off'>('idle')
  let mockList: NoteSummary[] | null = null
  let seq = 0

  async function load() {
    const mine = ++seq
    if (state.value !== 'ready') state.value = 'loading'
    try {
      const got = await readList()
      if (mine !== seq) return
      notes.value = got
      state.value = 'ready'
    } catch (e) {
      if (mine !== seq) return
      state.value = (e as { token?: string }).token === 'notes_off' ? 'off' : 'failed'
    }
  }

  async function readList(): Promise<NoteSummary[]> {
    if (api.mock) return [...(mockList ??= MOCK_NOTES.map((n) => ({ ...n })))]
    const r = await fetch(notesUrl(api), { credentials: api.credentials, headers: headersOf(api), signal: AbortSignal.timeout(HUB_READ_TIMEOUT_MS) })
    if (!r.ok) throw await refusal(r, 'notes list')
    return ((await r.json())?.notes || []) as NoteSummary[]
  }

  /** A new, empty note on top of the list; its id, or '' when the hub refused. */
  async function create(): Promise<string> {
    const top = Math.min(0, ...notes.value.map((n) => n.position)) - 1
    let row: NoteSummary
    try {
      row = api.mock ? mockNote(top) : await postNote()
    } catch {
      return ''
    }
    notes.value = [row, ...notes.value.filter((n) => n.id !== row.id)]
    return row.id
  }

  function mockNote(position: number): NoteSummary {
    const row: NoteSummary = { id: `mock-note-${Date.now()}`, title: '', snippet: '', pinned: false, position, archived: false, updated_at: new Date().toISOString(), items_done: 0, items_total: 0, link_count: 0 }
    mockList = [row, ...(mockList || [])]
    return row
  }

  async function postNote(): Promise<NoteSummary> {
    const r = await fetch(notesUrl(api), {
      method: 'POST', credentials: api.credentials, headers: headersOf(api, { 'content-type': 'application/json' }),
      body: JSON.stringify({ title: '', body: '' }), signal: AbortSignal.timeout(HUB_WRITE_TIMEOUT_MS),
    })
    if (!r.ok) throw await refusal(r, 'notes create')
    const n = await r.json()
    return {
      id: n.id, title: n.title || '', snippet: String(n.body || '').slice(0, 200), pinned: Boolean(n.pinned), position: Number(n.position) || 0,
      archived: Boolean(n.archived), updated_at: n.updated_at, items_done: 0, items_total: (n.items || []).length, link_count: (n.links || []).length,
    }
  }

  return { notes, state, load, create }
})
