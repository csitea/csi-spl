// The rows an id can name. Loaded after the first script, so the flow store
// and the linker stay out of it. The stores are read when a body renders.
// An id no store holds is asked from the hub once, after the paint, for the
// whole body (id-lookup.mjs, POST /v1/view/ids); the answers join the rows.
import { indexCatalog, resolveId, setIdCatalogProvider } from '~/utils/id-links.mjs'
import { idLinksReady, registerIdLookup } from '~/utils/id-link-gate.mjs'
import { createIdLookup } from '~/utils/id-lookup.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { useChannelStore } from '~/stores/channel'
import { useFlowStore } from '~/stores/flow'
import { useLiveFeed } from '~/stores/live'
import { useSearchStore } from '~/stores/search'
import { useViewerStore } from '~/stores/viewer'
import { useLive } from '~/composables/useLive'

/* lookupIds is a lazy client method (spool-client-lazy.mjs, view-v1 §4.6) */
type IdLookupApi = { lookupIds(ids: string[], self?: string): Promise<unknown> }

function read<T>(fn: () => T, fallback: T): T {
  try { return fn() } catch { return fallback }
}

type IdLabels = {
  topic: string
  'channel-message': string
  'direct-message': string
  archived: string
}

export function installIdCatalog(opts: {
  pathFor: (p: string) => string
  i18n: { t?: (key: string) => string } | undefined
}) {
  const pathFor = opts.pathFor
  const i18n = opts.i18n
  let cache: { refs: unknown[], index: ReturnType<typeof indexCatalog> } | null = null
  let self = ''
  const lookup = createIdLookup({
    fetchIds: (ids) => (useSpoolApi() as unknown as IdLookupApi).lookupIds(ids, self),
    resolves: (token, index) => Boolean(resolveId(token, index as ReturnType<typeof indexCatalog>)),
    onHits: () => idLinksReady(),
  })
  registerIdLookup((src: string, index: unknown) => lookup.note(src, index))

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
    self = String((access && access.humanId) || who || '')
    const labels = read((): IdLabels | null => {
      const tr = i18n && i18n.t
      if (typeof tr !== 'function') return null
      return {
        topic: tr('topic.title'),
        'channel-message': tr('id_link.channel_message'),
        'direct-message': tr('search.in_dm'),
        archived: tr('archive.badge'),
      }
    }, null)
    const refs: unknown[] = [
      channel, topics, viewed, main, pane, flowEntries, flowMine, found, self,
      labels && labels.topic, labels && labels['channel-message'],
      labels && labels['direct-message'], labels && labels.archived, lookup.version,
    ]
    if (cache && cache.refs.length === refs.length && cache.refs.every((r, i) => r === refs[i])) return cache.index
    const hits: unknown[] = []
    if (found && found.groups) for (const g of found.groups) if (g.items) hits.push(...g.items)
    const asked = lookup.rows(self)
    const index = indexCatalog({
      topics: [...topics, ...asked.topics],
      messages: [...channel, ...viewed, ...main, ...pane, ...flowEntries, ...flowMine, ...hits, ...asked.messages],
      self,
      pathFor,
      labels: labels || undefined,
    })
    cache = { refs, index }
    return index
  })
  idLinksReady()
}
