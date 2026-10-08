// Ids in a message link from the rows this tab already holds.
// The linker and the stores load in a later chunk: the first script stays
// under the size ceiling. Nothing here calls the hub.
// Spec 109 T006: the chunk (the flow, search, viewer and access stores) is
// asked once the app is ready, not during boot: it fetched and ran before the
// app mounted, and the first screen does not need it - a body on screen links
// when it arrives (idLinkEpoch, utils/id-link-gate.mjs).
export default defineNuxtPlugin((nuxtApp) => {
  let pathFor = (p: string) => p
  try {
    const localePath = useLocalePath()
    pathFor = (p: string) => localePath(p)
  } catch { /* an unprefixed path still opens on the default locale */ }

  const i18n = nuxtApp.$i18n as { t?: (key: string) => string } | undefined
  // A later navigation can abort this chunk. The preload helper then
  // resolves with no module, because the reload listener cancels that
  // error. Calling through the missing module throws a page error.
  // The next document runs this plugin again.
  onNuxtReady(() => {
    void import('~/utils/id-catalog-install').then((m) => {
      m?.installIdCatalog?.({ pathFor, i18n })
    }).catch(() => { /* the reload listener already handled a failed chunk */ })
  })
})
