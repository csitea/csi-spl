// SPL-1034 (specs/045 §3.8): the person's own order of the Channels list,
// kept per tenant on the hub. Seeded from GET /v1/view/me `channel_order`
// (the lde mock: its own stored copy); every change stores the WHOLE list
// through PUT /v1/me/channel-order, optimistic and debounced, so a few quick
// moves are one call. A failed save keeps the new order on screen and goes to
// the error snackbar with the hub's token.
import { noteError } from '~/composables/errorJournal.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { useSessionStore } from '~/stores/session'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { normalizeChannelOrder } from '~/utils/channel-order.mjs'

/* the editing half loads on first use, or once the page is idle (027 §6) */
let edits: Promise<typeof import('~/utils/channel-order-edit.mjs')> | null = null
const loadEdits = () => (edits ??= import('~/utils/channel-order-edit.mjs').catch((e) => {
  edits = null /* a chunk that failed to load (a deploy in between) is asked again next time */
  throw e
}))

export const CHANNEL_ORDER_SAVE_MS = 300

export function useChannelOrder() {
  const api = useSpoolApi()
  const access = useAccessStore()
  const session = useSessionStore()
  const i18n = useNuxtApp().$i18n
  const order = ref<string[]>([])
  let timer: ReturnType<typeof setTimeout> | null = null
  let inflight = 0

  /* a local change wins until it is stored: a /view/me answer landing in
     between must not draw the old order back */
  function seed(list: string[] | null | undefined) {
    if (timer || inflight) return
    order.value = Array.isArray(list) ? list.slice() : []
  }
  onMounted(() => { setTimeout(() => { loadEdits().catch(() => {}) }, 3000) })
  if (api.mock) seed(api.mockChannelOrder())
  else watch(() => access.me?.channelOrder, (v) => { if (access.me) seed(v) }, { immediate: true })

  async function flush() {
    timer = null
    /* a door-off guest has no membership to keep it on: this tab only */
    if (!api.mock && session.state !== 'in') return
    const sent = order.value.slice()
    inflight++
    try {
      const res = await withSessionRetry(api, () => api.setChannelOrder(sent))
      const stored = Array.isArray(res?.channel_order) ? normalizeChannelOrder(res.channel_order) : null
      if (access.me) access.me = { ...access.me, channelOrder: stored }
    } catch (e) {
      const err = (e || {}) as { token?: string, status?: number }
      const token = err.token || (err.status ? String(err.status) : 'network')
      noteError({ source: 'channel-order', name: 'ChannelOrder', message: i18n.t('sidebar.channel_order_failed', { token }), code: token, error: e })
    } finally {
      inflight--
    }
  }

  /** The person reordered the list: `displayed` is the whole order on screen. */
  async function set(displayed: string[]) {
    const m = await loadEdits().catch(() => null)
    if (!m) return
    const { mergeChannelOrder, sameChannelOrder } = m
    const next = mergeChannelOrder(displayed, order.value)
    if (sameChannelOrder(next, order.value)) return
    order.value = next
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => { void flush() }, CHANNEL_ORDER_SAVE_MS)
  }

  /** Move up (-1) / Move down (+1) from the row menu: swap with the neighbour. */
  async function step(displayed: string[], id: string, by: -1 | 1) {
    const m = await loadEdits().catch(() => null)
    const next = m ? m.stepChannelOrder(displayed, id, by) : null
    if (next) await set(next)
  }

  return { order, set, step }
}
