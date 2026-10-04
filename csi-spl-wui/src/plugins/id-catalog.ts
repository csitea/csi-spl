// Ids in a message link from the rows this tab already holds.
// The linker and the stores load in a later chunk: the first script stays
// under the size ceiling. Nothing here calls the hub.
export default defineNuxtPlugin((nuxtApp) => {
  let pathFor = (p: string) => p
  try {
    const localePath = useLocalePath()
    pathFor = (p: string) => localePath(p)
  } catch { /* an unprefixed path still opens on the default locale */ }

  const i18n = nuxtApp.$i18n as { t?: (key: string) => string } | undefined
  void import('~/utils/id-catalog-install').then((m) => {
    m.installIdCatalog({ pathFor, i18n })
  })
})
