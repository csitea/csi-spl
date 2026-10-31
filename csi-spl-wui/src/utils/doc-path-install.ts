// SPL-1592: the list of docs the doc-path linker may link to. The hub's
// tree.json (GET /v1/docs/tree.json, as the docs page reads it); when that
// fails (no docs bucket) the build's public docs index. SPL-4515: a settled
// signed-out reader reads only the public index, never the member tree (its
// 401 was a console error on every signed-out /docs). The mock tenant reads
// docs-mock. Nothing listed = no linker, every path stays text.
import { docPathLinker } from '~/utils/doc-paths.mjs'
import { setDocPathLinker, setDocPathLoader } from '~/utils/doc-path-hook.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { PUBLIC_DOCS_DIR, publicDocsList } from '~/utils/public-docs.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

type Api = { base: string, mock: boolean, token?: string, credentials?: RequestCredentials }
type Listed = { path?: unknown }

const pathsOf = (files: unknown): string[] =>
  (Array.isArray(files) ? files as Listed[] : []).map((f) => (f && typeof f.path === 'string' ? f.path : '')).filter(Boolean)

async function hubTree(api: Api): Promise<string[]> {
  if (api.mock) {
    const { mockDocs } = await import('~/utils/docs-mock')
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

/* 'out' is a settled signed-out session, as useDocsReader reads it; a failed probe is not 'out' */
async function signedOut(session: ReturnType<typeof useSessionStore>): Promise<boolean> {
  if (session.state === 'loading') await session.probe().catch(() => { /* a failed probe leaves the state: not 'out', the tree is read */ })
  return session.state === 'out'
}

/* the list is asked on the first text that could hold a path (doc-path-hook.mjs) */
export function bootDocPaths(nuxtApp: { runWithContext: (fn: () => unknown) => unknown }) {
  setDocPathLoader(() => {
    const [api, session] = nuxtApp.runWithContext(() => [useSpoolApi(), useSessionStore()]) as [Api, ReturnType<typeof useSessionStore>]
    return installDocPaths(api, () => signedOut(session))
  })
}

export async function installDocPaths(api: Api, isSignedOut: () => Promise<boolean> = async () => false) {
  const out = !api.mock && await isSignedOut().catch(() => false)
  let paths = out ? [] : await hubTree(api).catch(() => [] as string[])
  if (!paths.length) paths = await publicTree().catch(() => [] as string[])
  if (paths.length) setDocPathLinker(docPathLinker(paths))
}
