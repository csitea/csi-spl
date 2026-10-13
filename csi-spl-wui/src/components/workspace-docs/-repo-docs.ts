/* Spec 137 T023 (§4.1, owner HUM-10 t1 bed3ed0a msg 0e9d17b5: "combine the 2
   sections .. one spool-hub file system"): the repository's docs read inside
   the Qto explorer, beside the workspace's own. Until the docs move into the
   database (T020..T024) they are read where /docs reads them: the hub's
   GET /v1/docs/<path> and its tree.json; the mock tenant answers from
   docs-mock. The `-` prefix keeps Nuxt from registering this file as a
   component. */
import { useSpoolApi } from '~/composables/useSpoolApi'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

/** one doc of tree.json */
export type RepoFile = { path: string, title: string }

/** the repo docs' two reads; call it in a component's setup */
export function useRepoDocs() {
  const api = useSpoolApi()

  /** a doc's markdown, null for a 404, 'off' when the hub has no docs bucket; throws otherwise */
  async function read(path: string): Promise<string | null | 'off'> {
    if (api.mock) {
      const { mockDocs } = await import('~/utils/docs-mock.mjs')
      return mockDocs(path)
    }
    const headers: Record<string, string> = {}
    if (api.token) headers.authorization = `Bearer ${api.token}`
    const r = await fetch(`${api.base}/v1/docs/${path}`, { credentials: api.credentials, headers, cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
    if (r.status === 404) {
      const body = await r.json().catch(() => null) as { error?: string } | null
      return body?.error === 'docs_off' ? 'off' : null
    }
    if (!r.ok) throw new Error('docs ' + r.status)
    return r.text()
  }

  /** every doc tree.json lists, or 'off' */
  async function files(): Promise<RepoFile[] | 'off'> {
    const raw = await read('tree.json')
    if (raw === 'off') return 'off'
    const body = raw ? JSON.parse(raw) as { files?: unknown } : null
    return Array.isArray(body?.files) ? body.files as RepoFile[] : []
  }

  return { read, files }
}
