import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { ifMatchOf, noticeIdentity, saveErrorOf, type RepoEditIdentity } from '~/utils/repo-edit.mjs'
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

/** A call that throws (network, timeout) answers as status 0. */
const settle = (run: Promise<Answer>): Promise<Answer> => run.catch(() => ({ status: 0, body: null }))
const isOk = (a: Answer) => a.status >= 200 && a.status <= 299

/**
 * Editable Repo Docs (spec 075 repo-edit, T11): save a repo doc through the
 * hub with If-Match, and the one-time author notice of §4.2. A 428
 * author_notice_required parks the save and sets `notice` to the identity
 * the hub will publish; consent() records it and repeats the save,
 * dismissNotice() drops it. `edits` keeps the last saved edit per path for
 * the status chip (T12). Only the docs route loads this store.
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
    if (!who || !p) return null
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
    return attempt(p)
  })

  /** Cancel on the notice: nothing is saved. */
  function dismissNotice() {
    notice.value = null
    pending = null
  }

  return { notice, busy, error, edits, save, consent, dismissNotice }
})
