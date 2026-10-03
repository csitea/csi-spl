/**
 * CLE-77930: the one hub read-mark sync of this tab (utils/read-sync.mjs),
 * started by the feed pages - a lazy chunk, never the initial one (027).
 * When the hub knows a later read than this tab (another device or tab):
 * thread cards, DM badges and channel badges are recomputed, and a feed's
 * frozen "New messages" boundary moves up to what the member already saw.
 */
import { createReadSync, laterThan } from '~/utils/read-sync.mjs'
import { loadCursors } from '~/utils/read-cursor.mjs'
import { useNotificationStore } from '~/stores/notification'
import { useChannelStore } from '~/stores/channel'
import { useSessionStore } from '~/stores/session'
import { watch } from 'vue'

type Api = { mock: boolean, base: string, token: string, credentials: RequestCredentials }
type Mark = { ts?: string, id?: string, cursor?: string, count?: number }

let sync: ReturnType<typeof createReadSync> | null = null
let waiting = false

/** Starts once per tab, when a member session is signed in (a door-less read is a 401). */
export function startReadSync(api: Api) {
  if (sync || waiting || api.mock || !import.meta.client) return
  const session = useSessionStore()
  if (String(session.state) === 'in') {
    sync = createReadSync(api, { onMoved })
    return
  }
  waiting = true
  const off = watch(() => session.state, (st) => {
    if (String(st) !== 'in') return
    off()
    waiting = false
    startReadSync(api)
  })
}

/**
 * A read just moved here (a topic opened): send it now, not on the next
 * tick, so the hub's flow frame drops the counts while the reader looks.
 * The mock has no hub: its Flow counts are read again from the cursors.
 */
export function pushReads(api: Api) {
  startReadSync(api)
  if (sync) void sync.push()
  if (api.mock) void import('~/stores/flow').then((m) => m.useFlowStore().readCounts())
}

function onMoved(moved: string[], marks: Record<string, Mark>) {
  const notes = useNotificationStore()
  const frozen = { ...notes.boundary }
  let raised = false
  for (const [k, m] of Object.entries(marks || {})) {
    const b = frozen[k]
    if (b && laterThan(m, b)) {
      frozen[k] = { ts: String(m.ts), id: String(m.id || '') }
      raised = true
    }
  }
  if (raised) notes.boundary = frozen
  if (!moved.length) return
  const cursors = loadCursors() as Record<string, { count?: number }>
  if (moved.some((k) => k.startsWith('t:'))) {
    const read = { ...notes.topicRead }
    for (const k of moved) {
      const c = cursors[k]
      if (k.startsWith('t:') && c && Number.isFinite(c.count)) read[k.slice(2)] = Number(c.count)
    }
    notes.topicRead = read
  }
  const channel = useChannelStore()
  if (moved.some((k) => k.startsWith('dm:'))) {
    const session = useSessionStore()
    const self = String((session.claims && (session.claims as { hum?: string }).hum) || '')
    /* DB payload cut 1: the seed's dm counts were made by the hub against the
       dm_read= cursors it was sent, so moved dm: cursors need a fresh seed -
       re-applying the cached rows would keep the old counts. notify.client.ts
       applies the new rows (its dmSeed watch), as for the first paint. */
    void channel.loadDmActivity(self)
  }
  if (moved.some((k) => k.startsWith('ch:'))) void channel.loadChannels().catch(() => {})
}
