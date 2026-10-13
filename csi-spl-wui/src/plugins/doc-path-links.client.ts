// SPL-1592: a repo doc path written as text in a message, an issue field or
// a doc links to /docs/<path> (utils/doc-paths.mjs). Everything loads after
// the app is ready and behind import(): the initial chunk carries only this.
export default defineNuxtPlugin((nuxtApp) => {
  onNuxtReady(() => {
    void import('~/utils/doc-path-install').then((m) => m?.bootDocPaths?.(nuxtApp)).catch(() => { /* paths stay text */ })
  })
})
