/*
 * The docs page's reader (r18-06): who reads, and where a doc's text comes
 * from. Signed in, the hub (GET /v1/docs/<path>); signed out, the
 * build-time copy of the public docs, else /login. Call it once at setup:
 * who reads and the public index are settled once per page.
 */
import type { RouteLocationNormalizedLoaded } from 'vue-router'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import { PUBLIC_DOCS_DIR, publicDocsList } from '~/utils/public-docs.mjs'
import { useSessionStore } from '~/stores/session'
import { safeRedirect } from '~/utils/auth-client.mjs'
import { signedOutLoginHref } from '~/utils/signed-out-redirect.mjs'
import { wasSignedIn } from '~/utils/session-recover.mjs'
import { DOC_READ_TIMEOUT_MS } from '~/utils/fetch-timeouts.mjs'

export type TreeFile = { path: string, title: string }

type ReaderOpts = {
  api: ReturnType<typeof useSpoolApi>
  current: RouteLocationNormalizedLoaded
  localePath: (path: string) => string
}

export function useDocsReader({ api, current, localePath }: ReaderOpts) {
  /* GET /v1/docs/<path> through the hub: the body, null for a 404, 'off'
     when the hub has no docs bucket. The mock tenant answers from docs-mock.
     Throws for any other non-2xx, a network failure or a timeout ('failed'). */
  async function hubDoc(path: string, meta?: { base: string }): Promise<string | null | 'off'> {
    if (api.mock) {
      const { mockDocs, mockDocBase } = await import('~/utils/docs-mock')
      if (meta) meta.base = mockDocBase(path)
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
    if (meta) meta.base = r.headers.get('X-Spool-Doc-Base') ?? ''
    return r.text()
  }

  /* Owner HUM-10 (e3ce4c34): who reads. 'out' is a settled signed-out
     session (the mock's default too, specs/054); every other state reads
     through the hub, as before. Settled once per page. */
  const session = useSessionStore()
  const reader = ref<'unknown' | 'in' | 'out'>('unknown')
  let who: Promise<'in' | 'out'> | null = null
  function whoReads() {
    if (!who) {
      who = (async () => {
        /* a failed probe leaves the state as it is: not 'out' reads via the hub, as before */
        if (session.state === 'loading') await session.probe().catch(() => {})
        reader.value = session.state === 'out' ? 'out' : 'in'
        return reader.value
      })()
    }
    return who
  }

  /* the build-time copy's index of the public docs ([] when there is none) */
  let publicIndex: Promise<TreeFile[]> | null = null
  function publicDocs() {
    if (!publicIndex) {
      publicIndex = fetch(PUBLIC_DOCS_DIR + 'index.json', { cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
        .then((r) => (r.ok ? r.json() : null))
        .then((b) => publicDocsList(b))
        .catch(() => [])
    }
    return publicIndex
  }

  /* a public doc out of the copy: only a path its index lists, else null */
  async function publicDoc(path: string): Promise<string | null> {
    if (!(await publicDocs()).some((f) => f.path === path)) return null
    const r = await fetch(PUBLIC_DOCS_DIR + path, { cache: 'no-cache', signal: AbortSignal.timeout(DOC_READ_TIMEOUT_MS) })
    if (!r.ok) throw new Error('docs ' + r.status)
    return r.text()
  }

  /* a signed-out visitor on a doc that is not public: /login, back here after.
     While hydrating, a real navigation (middleware/signed-out-redirect). */
  const nuxtApp = useNuxtApp()
  function toLogin() {
    const redirect = safeRedirect(current.fullPath)
    const ended = wasSignedIn()
    if (nuxtApp.isHydrating) {
      return navigateTo(signedOutLoginHref(localePath('/login'), redirect, ended), { external: true, replace: true })
    }
    return navigateTo({ path: localePath('/login'), query: ended ? { redirect, ended: '1' } : { redirect } }, { replace: true })
  }

  return { reader, whoReads, hubDoc, publicDocs, publicDoc, toLogin }
}
