// Ids in a message link from the rows this tab already holds (id-links.mjs).
// The stores are read when a body renders. Nothing here calls the hub.
import { indexCatalog, setIdCatalogProvider } from '~/utils/id-links.mjs'
import { useAccessStore } from '~/stores/access'
import { useChannelStore } from '~/stores/channel'
import { useFlowStore } from '~/stores/flow'
import { useLiveFeed } from '~/stores/live'
import { useSearchStore } from '~/stores/search'
import { useViewerStore } from '~/stores/viewer'
import { useLive } from '~/composables/useLive'

function read<T>(fn: () => T, fallback: T): T {
  try { return fn() } catch { return fallback }
}

export default defineNuxtPlugin(() => {
  let pathFor = (p: string) => p
  try {
    const localePath = useLocalePath()
    pathFor = (p) => localePath(p)
  } catch { /* an unprefixed path still opens on the default locale */ }

  let cache: { refs: unknown[], index: ReturnType<typeof indexCatalog> } | null = null

  setIdCatalogProvider(() => {
    const channel = read(() => useChannelStore().messages, [] as unknown[])
    const viewer = read(() => useViewerStore(), null)
    const topics = viewer ? viewer.topics : []
    const viewed = viewer ? viewer.messages : []
    const main = read(() => useLiveFeed('main').messages, [] as unknown[])
    const pane = read(() => useLiveFeed('pane').messages, [] as unknown[])
    const flow = read(() => useFlowStore(), null)
    const flowEntries = flow ? flow.entries : []
    const flowMine = flow ? flow.mine : []
    const found = read(() => useSearchStore().result, null)
    const access = read(() => useAccessStore().me, null)
    const who = read(() => useLive().identity.value, '')
    const self = String((access && access.humanId) || who || '')
    const refs: unknown[] = [channel, topics, viewed, main, pane, flowEntries, flowMine, found, self]
    if (cache && cache.refs.length === refs.length && cache.refs.every((r, i) => r === refs[i])) return cache.index
    const hits: unknown[] = []
    if (found && found.groups) for (const g of found.groups) if (g.items) hits.push(...g.items)
    const index = indexCatalog({
      topics,
      messages: [...channel, ...viewed, ...main, ...pane, ...flowEntries, ...flowMine, ...hits],
      self,
      pathFor,
    })
    cache = { refs, index }
    return index
  })
})
