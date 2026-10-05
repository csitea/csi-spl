import { getCurrentInstance, onBeforeUnmount, onMounted, shallowRef } from 'vue'
import { useSessionStore } from '~/stores/session'
import { DRAFTS_KEY, draftPlaceOf, pruneDrafts, type DraftPlaces, type DraftTarget } from '~/utils/drafts.mjs'
import { storageGet } from '~/utils/prefs.mjs'

/**
 * 080 FR-005 (T004): which places hold a composer draft, for the pencil mark
 * on sidebar rows and topic cards.
 *
 *   const drafts = useDrafts()
 *   drafts.has('ch:' + c.channel_id)   // also 'dm:<peer>', 't:<task_id>'
 *
 * One shared reader for every caller (a feed mounts one card per message).
 * The composer writes `spool.drafts` itself (utils/drafts.mjs, 300 ms after a
 * key), and a same-tab localStorage write fires no event, so the reader
 * compares the raw value once a second while the tab is visible and a mark is
 * mounted, and re-reads on another tab's `storage` event and on return to the
 * tab. Read only: pruning on load stays the composer's.
 */
const POLL_MS = 1000

const all = shallowRef<Record<string, DraftPlaces>>({})
let raw: string | null | undefined
let users = 0
let timer: ReturnType<typeof setInterval> | null = null

function refresh() {
  const next = storageGet(DRAFTS_KEY, null) as string | null
  if (next === raw) return
  raw = next
  let parsed: unknown = {}
  try {
    parsed = next ? JSON.parse(next) : {}
  } catch {
    parsed = {}
  }
  all.value = pruneDrafts(parsed)
}

function start() {
  if (!timer && users > 0) timer = setInterval(refresh, POLL_MS)
}
function stop() {
  if (timer) clearInterval(timer)
  timer = null
}
function onStorage(e: StorageEvent) {
  if (e.key == null || e.key === DRAFTS_KEY) refresh()
}
function onVisibility() {
  if (document.visibilityState === 'hidden') return stop()
  refresh()
  start()
}

function attach() {
  if (users++ > 0) return
  refresh()
  window.addEventListener('storage', onStorage)
  document.addEventListener('visibilitychange', onVisibility)
  if (document.visibilityState !== 'hidden') start()
}
function detach() {
  if (--users > 0) return
  users = 0
  stop()
  window.removeEventListener('storage', onStorage)
  document.removeEventListener('visibilitychange', onVisibility)
}

export function useDrafts() {
  const session = useSessionStore()
  if (import.meta.client && getCurrentInstance()) {
    onMounted(attach)
    onBeforeUnmount(detach)
  }

  /** True when the signed-in member keeps a draft for this place. */
  function has(place: unknown) {
    const hum = String(session.claims?.hum || '')
    const p = draftPlaceOf(place as DraftTarget)
    return Boolean(hum && p && all.value[hum]?.[p])
  }

  return { has }
}
