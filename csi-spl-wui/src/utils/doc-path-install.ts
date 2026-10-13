// SPL-1592: the list of docs the doc-path linker may link to. The hub's
// tree.json (GET /v1/docs/tree.json, as the docs page reads it); when that
// fails (signed out, no docs bucket) the build's public docs index. The mock
// tenant reads docs-mock. Nothing listed = no linker, every path stays text.
import { docPathLinker } from '~/utils/doc-paths.mjs'
import { setDocPathLinker, setDocPathLoader } from '~/utils/doc-path-hook.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { PUBLIC_DOCS_DIR, publicDocsList } from '~/utils/public-docs.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

type Api = { base: string, mock: boolean, token?: string, credentials?: RequestCredentials }
type Listed = { path?: unknown }

const pathsOf = (files: unknown): string[] =>
  (Array.isArray(files) ? files as Listed[] : []).map((f) => (f && typeof f.path === 'string' ? f.path : '')).filter(Boolean)

async function hubTree(api: Api): Promise<string[]> {
  if (api.mock) {
    const { mockDocs } = await import('~/utils/docs-mock.mjs')
    const raw = mockDocs('tree.json')
    return raw ? pathsOf((JSON.parse(raw) as { files?: unknown }).files) : []
  }
  const headers: Record<string, string> = {}
  if (api.token) headers.authorization = `Bearer ${api.token}`
  const r = await fetch(`${api.base}/v1/docs/tree.json`, { credentials: api.credentials, headers, signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
  if (!r.ok) return []
  return pathsOf(((await r.json()) as { files?: unknown }).files)
}

async function publicTree(): Promise<string[]> {
  const r = await fetch(PUBLIC_DOCS_DIR + 'index.json', { signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
  return r.ok ? publicDocsList(await r.json()).map((f: { path: string }) => f.path) : []
}

/* the list is asked on the first text that could hold a path (doc-path-hook.mjs) */
export function bootDocPaths(nuxtApp: { runWithContext: (fn: () => unknown) => unknown }) {
  setDocPathLoader(() => installDocPaths(nuxtApp.runWithContext(() => useSpoolApi()) as Api))
}

export async function installDocPaths(api: Api) {
  let paths = await hubTree(api).catch(() => [] as string[])
  if (!paths.length) paths = await publicTree().catch(() => [] as string[])
  if (paths.length) setDocPathLinker(docPathLinker(paths))
}
