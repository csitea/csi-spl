// The lazy half of plugins/issue-links.client.ts (HUM-10, t1 0f2ed820): the
// workspace's issue prefix comes from the hub's issue list (one row asked)
// once the session is in; a workspace with no issues, or a refused read,
// leaves keys as text. Sign-out clears the linker; the next sign-in asks again.
import { watch, type ShallowRef } from 'vue'
import type { IssueLinker } from '~/utils/issue-link-hook.mjs'
import { issueLinker } from '~/utils/issue-key-links.mjs'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'

/* the mock tenant's issue store is bound by the Issues page; a throwaway
   one answers the same prefix without binding it */
async function prefixRead(api: ReturnType<typeof useSpoolApi>): Promise<{ prefix?: unknown } | null> {
  if (api.mock) {
    const store = (await import('~/utils/issues.mjs')).createMockIssues({ me: 'HUM-1' }) as { list: (q: string) => { prefix?: unknown } }
    return store.list('limit=1')
  }
  return api.listIssues({ limit: 1 }) as Promise<{ prefix?: unknown } | null>
}

/** linker is the plugin's ref, which the render already reads. */
export function installIssueLinks(linker: ShallowRef<IssueLinker | null>) {
  let pathFor = (p: string) => p
  try {
    const localePath = useLocalePath()
    pathFor = (p: string) => localePath(p)
  } catch { /* an unprefixed path still opens on the default locale */ }
  const api = useSpoolApi()
  let asked = false
  const load = () => {
    if (asked) return
    asked = true
    void prefixRead(api)
      .then((data) => { linker.value = issueLinker(data?.prefix, pathFor) })
      .catch(() => { asked = false })
  }
  if (api.mock) { load(); return }
  const session = useSessionStore()
  watch(() => session.state, (state) => {
    if (String(state) === 'in') load()
    else if (String(state) === 'out') { linker.value = null; asked = false }
  }, { immediate: true })
}
