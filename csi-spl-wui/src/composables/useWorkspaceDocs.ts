import { useSpoolApi } from '~/composables/useSpoolApi'
import { wsTreeFiles } from '~/utils/ws-docs.mjs'
import { docFetchTimeoutMs } from '~/utils/fetch-timeouts.mjs'

type TreeFile = { path: string, title: string }
type MockBucket = { get(p: string): string | null, put(p: string, b: string): boolean, del(p: string): boolean }

/* one tree for the page's life: the explorer section and the editor both
   read it, and a save, a new doc or a delete reloads it */
const files = ref<TreeFile[]>([])
const treeState = ref<'loading' | 'ready' | 'off' | 'failed'>('loading')
let mockBucket: Promise<MockBucket> | null = null
let treeSeq = 0

/**
 * Workspace docs through the hub (spec 075 Phase 2, T010): GET / PUT / DELETE
 * /v1/workspace/docs/<path> and GET .../tree.json. The tree answering 404
 * (routes off, an older hub) or 403 is 'off', and the section shows nothing.
 * The mock tenant reads and writes an in-memory bucket (ws-docs-mock).
 */
export function useWorkspaceDocs() {
  const api = useSpoolApi()
  const bucket = () => (mockBucket ??= import('~/utils/ws-docs-mock.mjs')
    .then((m) => m.createMockWsDocs() as MockBucket)
    .catch((e) => {
      mockBucket = null /* a chunk that failed to load (a deploy in between) is asked again next time */
      throw e
    }))

  /**
   * One hub call under /v1/workspace/docs/: adds the bearer token and a
   * timeout (a read short, a PUT / DELETE long; a caller's own signal wins).
   * Rejects on a network failure or timeout; the caller owns status handling
   * (404 missing, 403 / 501 off).
   */
  async function call(path: string, init: RequestInit = {}): Promise<Response> {
    const headers: Record<string, string> = { ...(init.headers as Record<string, string> | undefined) }
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const signal = init.signal ?? AbortSignal.timeout(docFetchTimeoutMs(init.method))
    return fetch(`${api.base}/v1/workspace/docs/${path}`, { credentials: api.credentials, cache: 'no-cache', ...init, headers, signal })
  }

  /** The doc's markdown, null for a 404. */
  async function read(path: string): Promise<string | null> {
    if (api.mock) return (await bucket()).get(path)
    const r = await call(path)
    if (r.status === 404) return null
    if (!r.ok) throw new Error('workspace docs ' + r.status)
    return r.text()
  }

  /** Save (create or overwrite): last write wins, the hub keeps the old version in .history/. */
  async function write(path: string, body: string): Promise<void> {
    if (api.mock) { (await bucket()).put(path, body); return }
    const r = await call(path, { method: 'PUT', headers: { 'content-type': 'text/markdown; charset=utf-8' }, body })
    if (!r.ok) throw Object.assign(new Error('workspace docs ' + r.status), { status: r.status })
  }

  async function remove(path: string): Promise<void> {
    if (api.mock) { (await bucket()).del(path); return }
    const r = await call(path, { method: 'DELETE' })
    if (!r.ok && r.status !== 404) throw Object.assign(new Error('workspace docs ' + r.status), { status: r.status })
  }

  async function loadTree(): Promise<void> {
    const mine = ++treeSeq
    try {
      let raw: string | null
      if (api.mock) raw = (await bucket()).get('tree.json')
      else {
        const r = await call('tree.json')
        if (r.status === 404 || r.status === 403 || r.status === 501) {
          if (mine === treeSeq) treeState.value = 'off'
          return
        }
        if (!r.ok) throw new Error('workspace docs ' + r.status)
        raw = await r.text()
      }
      if (mine !== treeSeq) return
      files.value = wsTreeFiles(raw ? JSON.parse(raw) : null)
      treeState.value = 'ready'
    } catch {
      if (mine === treeSeq) treeState.value = 'failed'
    }
  }

  return { files, treeState, loadTree, read, write, remove }
}
