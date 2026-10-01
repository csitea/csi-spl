import { useNotificationStore } from '~/stores/notification'
import { NOTIFY_OPEN, PENDING_OPEN_KEY, pendingOpen } from '~/utils/notify.mjs'

/**
 * CLE-77890 (owner, t1 bd6d7291): a tapped Android alert opens its message.
 * The service worker (public/sw.js) brings this tab forward and posts
 * NOTIFY_OPEN with the alert's target; the answer on the port tells it the tab
 * took it (no answer: it navigates the tab itself), then the app routes to the
 * message's deep link /m/<msg_id>, which opens it in place, marked.
 */
export default defineNuxtPlugin(() => {
  if (!('serviceWorker' in navigator)) return
  const notes = useNotificationStore()
  /* a tap the tab's own new-version reload (build-watch, on becoming
     visible) cut short: open it now */
  try {
    const left = pendingOpen(sessionStorage.getItem(PENDING_OPEN_KEY), Date.now())
    sessionStorage.removeItem(PENDING_OPEN_KEY)
    /* after the first navigation: a push during it becomes part of it and is lost */
    if (left) void useRouter().isReady().then(() => setTimeout(() => notes.openTarget(left), 0))
  } catch { /* no sessionStorage */ }
  navigator.serviceWorker.addEventListener('message', (e: MessageEvent) => {
    const d = e.data as { type?: string, url?: string } | null
    if (!d || d.type !== NOTIFY_OPEN) return
    if (e.ports && e.ports[0]) e.ports[0].postMessage('ok')
    notes.openTarget(d)
  })
})
