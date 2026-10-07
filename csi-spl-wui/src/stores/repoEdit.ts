import { defineStore } from 'pinia'
import type { Ref } from 'vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { conflictOf, editActionErrorOf, editsOf, ifMatchOf, noticeIdentity, saveErrorOf, type RepoEditConflict, type RepoEditIdentity, type RepoEditView } from '~/utils/repo-edit.mjs'
import { DOC_WRITE_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

/** The hub's answer to a save: the queued edit (spec 075 repo-edit §10). */
export type RepoEditSaved = { edit_id: string, status: string, path: string }
type Api = ReturnType<typeof useSpoolApi>
type Answer = { status: number, body: unknown }
type Pending = { path: string, text: string, base: string }
type SaveError = { key: string, params: Record<string, string | number> }

/** One call under /v1/docs/: the bearer token, a write timeout, the JSON answer. */
async function hubCall(api: Api, path: string, init: RequestInit): Promise<Answer> {
  const headers: Record<string, string> = { ...(init.headers as Record<string, string> | undefined) }
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const r = await fetch(`${api.base}/v1/docs/${path}`, { credentials: api.credentials, cache: 'no-cache', ...init, headers, signal: AbortSignal.timeout(DOC_WRITE_TIMEOUT_MS) })
  return { status: r.status, body: r.status === 204 ? null : await r.json().catch(() => null) }
}

/** PUT /v1/docs/<path> with If-Match = the opened blob (none for a new doc). */
async function putDoc(api: Api, p: Pending): Promise<Answer> {
  const ifMatch = ifMatchOf(p.base)
  if (api.mock) return (await import('~/utils/docs-mock.mjs')).mockRepoSave(p.path, p.text, ifMatch)
  const headers: Record<string, string> = { 'content-type': 'text/markdown; charset=utf-8' }
  if (ifMatch) headers['if-match'] = ifMatch
  return hubCall(api, p.path, { method: 'PUT', headers, body: p.text })
}

/** POST /v1/docs/author-notice: the consent to exactly the identity shown. */
async function postNotice(api: Api, who: RepoEditIdentity): Promise<Answer> {
  const body = { git_name: who.git_name, git_email: who.git_email }
  if (api.mock) return (await import('~/utils/docs-mock.mjs')).mockAuthorNotice(body)
  return hubCall(api, 'author-notice', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })
}

/** GET /v1/docs/edits?mine=1 or ?path=<doc> (T12). */
async function listEdits(api: Api, q: { mine?: boolean, path?: string }): Promise<Answer> {
  if (api.mock) return (await import('~/utils/docs-mock.mjs')).mockRepoEdits(q)
  const qs = q.mine ? 'mine=1' : 'path=' + encodeURIComponent(q.path ?? '')
  return hubCall(api, 'edits?' + qs, { method: 'GET' })
}

/** POST /v1/docs/edits/{id}/retry (T12). */
async function postRetry(api: Api, id: string): Promise<Answer> {
  if (api.mock) return (await import('~/utils/docs-mock.mjs')).mockRepoRetry(id)
  return hubCall(api, 'edits/' + encodeURIComponent(id) + '/retry', { method: 'POST' })
}

/** GET /v1/docs/edits/{id}/conflict (T12). */
async function getConflict(api: Api, id: string): Promise<Answer> {
  if (api.mock) return (await import('~/utils/docs-mock.mjs')).mockRepoConflict(id)
  return hubCall(api, 'edits/' + encodeURIComponent(id) + '/conflict', { method: 'GET' })
}

/** A call that throws (network, timeout) answers as status 0. */
const settle = (run: Promise<Answer>): Promise<Answer> => run.catch(() => ({ status: 0, body: null }))
const isOk = (a: Answer) => a.status >= 200 && a.status <= 299

/** The list with `row` in place of the row of the same edit. */
const swapRow = (l: RepoEditView[], row: RepoEditView) => l.map((e) => (e.edit_id === row.edit_id ? row : e))

type Step = (run: () => Promise<RepoEditSaved | null>) => Promise<RepoEditSaved | null>
type Shared = {
  notice: Ref<RepoEditIdentity | null>
  error: Ref<SaveError | null>
  step: Step
  save: (path: string, text: string, base: string) => Promise<RepoEditSaved | null>
  dismissNotice: () => void
}

/**
 * T12: the edits lists, retry, the conflict view and the identity review,
 * on the store's notice, error and busy step. `byPath` (the doc header's
 * chip) and `mine` ("My edits": the member's edits and their agents')
 * mirror GET /v1/docs/edits; retry() requeues a failed edit; openConflict()
 * reads a conflict and resolve() saves the resolution again with base =
 * master's head blob; reviewIdentity() shows the notice without a save,
 * for a requester whose agent got 428.
 */
function editLists(api: Api, sh: Shared) {
  const byPath = ref<Record<string, RepoEditView[]>>({})
  const mine = ref<RepoEditView[] | null>(null)
  const conflict = ref<RepoEditConflict | null>(null)
  /* the identity notice was confirmed with no save behind it (My edits) */
  const confirmed = ref(false)

  /** The path's edits for the chip; false when the hub did not answer. */
  async function loadPath(path: string): Promise<boolean> {
    const a = await settle(listEdits(api, { path }))
    if (!isOk(a)) return false
    byPath.value = { ...byPath.value, [path]: editsOf(a.body) }
    return true
  }

  /** "My edits"; false when the hub did not answer (the list keeps what it had). */
  async function loadMine(): Promise<boolean> {
    const a = await settle(listEdits(api, { mine: true }))
    if (!isOk(a)) return false
    mine.value = editsOf(a.body)
    return true
  }

  /** Retry a failed edit: the hub queues it again; the lists show the new status. */
  const retry = (id: string) => sh.step(async () => {
    const a = await settle(postRetry(api, id))
    if (!isOk(a)) {
      sh.error.value = editActionErrorOf(a.status, a.body)
      return null
    }
    const row = editsOf({ edits: [a.body] })[0]
    if (row && mine.value) mine.value = swapRow(mine.value, row)
    if (row && byPath.value[row.path]) byPath.value = { ...byPath.value, [row.path]: swapRow(byPath.value[row.path], row) }
    return null
  })

  /** Read the conflict of edit `id` (theirs / mine) into `conflict`. */
  async function openConflict(id: string): Promise<boolean> {
    conflict.value = null
    sh.error.value = null
    const a = await settle(getConflict(api, id))
    const c = isOk(a) ? conflictOf(a.body) : null
    if (!c) {
      sh.error.value = editActionErrorOf(a.status, a.body)
      return false
    }
    conflict.value = c
    return true
  }

  /** Save the resolved text of the open conflict with base = master's head (spec §8). */
  const resolve = async (text: string) => {
    const c = conflict.value
    if (!c) return null
    const saved = await sh.save(c.path, text, c.head_blob)
    if (saved) conflict.value = null
    return saved
  }

  /**
   * Show the notice for the identity a save would publish, without a save:
   * a consent POST with no identity answers 409 author_changed naming it.
   */
  const reviewIdentity = () => sh.step(async () => {
    confirmed.value = false
    const a = await settle(postNotice(api, { git_name: '-', git_email: '-', author_source: '' }))
    const who = a.status === 409 ? noticeIdentity(a.body) : null
    if (!who) {
      sh.error.value = saveErrorOf(a.status, a.body)
      return null
    }
    sh.dismissNotice()
    sh.notice.value = who
    return null
  })

  return { byPath, mine, conflict, confirmed, loadPath, loadMine, retry, openConflict, resolve, reviewIdentity }
}

/**
 * Editable Repo Docs (spec 075 repo-edit, T11): save a repo doc through the
 * hub with If-Match, and the one-time author notice of §4.2. A 428
 * author_notice_required parks the save and sets `notice` to the identity
 * the hub will publish; consent() records it and repeats the save,
 * dismissNotice() drops it. `edits` keeps the last saved edit per path for
 * the status chip (T12). Only the docs route loads this store.
 * T12 adds editLists (above) on the same state.
 */
export const useRepoEditStore = defineStore('repoEdit', () => {
  const api = useSpoolApi()
  const notice = ref<RepoEditIdentity | null>(null)
  const busy = ref(false)
  const error = ref<SaveError | null>(null)
  const edits = ref<Record<string, RepoEditSaved>>({})
  let pending: Pending | null = null

  /** One save attempt: the edit, or null with `notice` or `error` set. */
  async function attempt(p: Pending): Promise<RepoEditSaved | null> {
    const a = await settle(putDoc(api, p))
    const who = a.status === 428 ? noticeIdentity(a.body) : null
    if (who) {
      pending = p
      notice.value = who
      return null
    }
    if (!isOk(a)) {
      error.value = saveErrorOf(a.status, a.body)
      return null
    }
    const b = (a.body ?? {}) as Partial<RepoEditSaved>
    const saved = { edit_id: String(b.edit_id ?? ''), status: String(b.status ?? 'queued'), path: p.path }
    edits.value = { ...edits.value, [p.path]: saved }
    return saved
  }

  /** Runs one step with busy set and the last error cleared; a second click while busy is dropped. */
  async function step(run: () => Promise<RepoEditSaved | null>): Promise<RepoEditSaved | null> {
    if (busy.value) return null
    busy.value = true
    error.value = null
    try {
      return await run()
    } finally {
      busy.value = false
    }
  }

  /** Save `text` as `path`, opened at blob `base`. */
  const save = (path: string, text: string, base: string) => step(() => attempt({ path, text, base }))

  /**
   * "I understand, save": consent to the identity the notice showed, then
   * repeat the parked save. A changed identity (409 author_changed) shows
   * the notice again with the new one.
   */
  const consent = () => step(async () => {
    const who = notice.value
    const p = pending
    if (!who) return null
    const a = await settle(postNotice(api, who))
    if (a.status === 409 && noticeIdentity(a.body)) {
      notice.value = noticeIdentity(a.body)
      return null
    }
    if (!isOk(a)) {
      error.value = saveErrorOf(a.status, a.body)
      return null
    }
    dismissNotice()
    if (!p) {
      lists.confirmed.value = true
      return null
    }
    return attempt(p)
  })

  /** Cancel on the notice: nothing is saved. */
  function dismissNotice() {
    notice.value = null
    pending = null
  }

  const lists = editLists(api, { notice, error, step, save, dismissNotice })
  return { notice, busy, error, edits, save, consent, dismissNotice, ...lists }
})
