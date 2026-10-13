// Issue keys in a message link to the issue (HUM-10, t1 0f2ed820). The
// prefix read, the matcher and the session watch are one lazy chunk
// (utils/issue-links-install.ts), asked once the app is ready: the first
// script carries only this and the ref. The provider reads the ref from the
// first render on, so a body rendered before the chunk arrives re-renders.
import { setIssueLinkProvider, type IssueLinker } from '~/utils/issue-link-hook.mjs'

export default defineNuxtPlugin((nuxtApp) => {
  const linker = shallowRef<IssueLinker | null>(null)
  setIssueLinkProvider(() => linker.value)
  onNuxtReady(() => {
    void import('~/utils/issue-links-install').then((m) => {
      nuxtApp.runWithContext(() => m?.installIssueLinks?.(linker))
    }).catch(() => { /* keys stay text */ })
  })
})
