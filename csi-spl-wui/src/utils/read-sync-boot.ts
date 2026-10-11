/**
 * CLE-77930: the one hub read-mark sync of this tab (utils/read-sync.mjs),
 * started by the feed pages - a lazy chunk, never the initial one (027).
 * When the hub knows a later read than this tab (another device or tab):
 * thread cards, DM badges and channel badges are recomputed, and a feed's
 * frozen "New messages" boundary moves up to what the member already saw.
 */
import { createReadSync, laterThan } from '~/utils/read-sync.mjs'
import { createSeedGate, seedWaitsForPull } from '~/utils/dm-seed.mjs'
import { loadCursors } from '~/utils/read-cursor.mjs'
import { useNotificationStore } from '~/stores/notification'
import { useChannelStore } from '~/stores/channel'
import { useSessionStore } from '~/stores/session'
import { watch } from 'vue'

type Api = { mock: boolean, base: string, token: string, credentials: RequestCredentials }
type Mark = { ts?: string, id?: string, cursor?: string, count?: number }

let sync: ReturnType<typeof createReadSync> | null = null
let waiting = false
const dmSeed = createSeedGate()

/** Starts once per tab, when a member session is signed in (a door-less read is a 401). */
export function startReadSync(api: Api) {
  void import('~/utils/hours-recorder-boot').then((m) => m.startHoursRecorder(api)) /* spec 107 T012: tab minutes, a lazy chunk of its own */
  if (sync || api.mock || !import.meta.client) return
  const session = useSessionStore()
  if (String(session.state) === 'in') {
    /* a page's waiting watch may not have fired yet (the DM seed below asks first): it finds `sync` set */
    sync = createReadSync(api, { onMoved })
    return
  }
  if (waiting) return
  waiting = true
  const off = watch(() => session.state, (st) => {
    if (String(st) !== 'in') return
    off()
    waiting = false
    startReadSync(api)
  })
}

/**
 * spec 109 FR-004: the tab's first DM seed (plugins/spool-live.client.ts).
 * Where this sync's first pull would move the dm: cursors (a feed page, or a
 * browser with no dm: cursor yet: utils/dm-seed.mjs seedWaitsForPull) it
 * starts the sync and goes out once, after that pull, with the moved cursors;
 * elsewhere it goes out at once, as before.
 */
export function seedDms(api: Api, path: string, seed: () => unknown) {
  if (!seedWaitsForPull(path, loadCursors())) return seed()
  startReadSync(api)
  return dmSeed.after(sync ? sync.ready : null, seed)
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
       applies the new rows (its dmSeed watch), as for the first paint.
       A seed still held for this pull reads them itself (spec 109 FR-004). */
    void dmSeed.moved(() => channel.loadDmActivity(self))
  }
  // Best effort: a failed reload keeps the cached channel counts until the next load or live frame.
  if (moved.some((k) => k.startsWith('ch:'))) void channel.loadChannels().catch(() => {})
}
