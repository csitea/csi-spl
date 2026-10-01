// Spool service worker — makes the WUI an installable PWA and shows its
// alerts on Android (bug A, below), and nothing else.
//
// It caches NOTHING and has no fetch handler: every request goes to the
// network exactly as it did before this file existed. A worker that serves
// a cached shell would hide a fresh deploy behind the old bundle (a deploy
// "lands" on trunk and the browser keeps the previous build), so the shell
// stays network-only. /_nuxt/** is already immutable in the HTTP cache.
//
// activate deletes every Cache Storage entry this origin holds, so any later
// version that did cache can be undone by shipping this file again: the
// worker is its own kill switch. Served with max-age=0 (firebase.json `**`)
// and registered with updateViaCache 'none', so a new copy is picked up on
// the next navigation.
self.addEventListener('install', () => {
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const keys = await caches.keys()
    await Promise.all(keys.map((k) => caches.delete(k)))
    await self.clients.claim()
  })())
})

// Bug A (t1 5002067f): on Android a new-message alert can only be shown
// through this worker (showAlert in utils/notify.mjs).
//
// CLE-77890 (owner, t1 bd6d7291: tapping an alert "does not jump to the
// actual UI of the announcement, but just keeps me there where I was"): the
// alert's `data` names its message ({ msgId, url: /m/<msg_id> }, see
// notificationTarget). A tap brings an open Spool tab forward and hands it the
// target (NOTIFY_OPEN); the tab answers on the port and opens the message in
// place. A tab that does not answer (a bundle from before this change) is
// navigated to the url; with no tab open, one is opened there.
const NOTIFY_OPEN = 'spool:notification-open'
const ACK_MS = 1500

/** A same-origin path from the alert's data, '/' for anything else. */
function targetUrl(data) {
  const url = String((data && data.url) || '/')
  return url.startsWith('/') && !url.startsWith('//') ? url : '/'
}

/** Post the target to one tab; true once it answers, false after ACK_MS. */
function handOver(client, msg) {
  return new Promise((resolve) => {
    let done = false
    const ch = new MessageChannel()
    const finish = (ok) => {
      if (done) return
      done = true
      ch.port1.close()
      resolve(ok)
    }
    ch.port1.onmessage = () => finish(true)
    setTimeout(() => finish(false), ACK_MS)
    try {
      client.postMessage(msg, [ch.port2])
    } catch {
      finish(false)
    }
  })
}

async function openFromNotification(data) {
  const url = targetUrl(data)
  const msg = { type: NOTIFY_OPEN, msgId: String((data && data.msgId) || ''), url }
  const tabs = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
  /* the tab the reader last looked at first */
  const tab = tabs.find((c) => c.focused) || tabs.find((c) => c.visibilityState === 'visible') || tabs[0]
  if (tab) {
    let win = tab
    try {
      if ('focus' in tab) win = (await tab.focus()) || tab
    } catch { /* focus needs the click's activation; the hand-over still runs */ }
    if (url === '/') return win
    if (await handOver(win, msg)) return win
    if ('navigate' in win) {
      try {
        return await win.navigate(url)
      } catch { /* an uncontrolled tab cannot be navigated from here */ }
    }
  }
  if (self.clients.openWindow) return self.clients.openWindow(url)
  return undefined
}

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  event.waitUntil(openFromNotification(event.notification.data))
})
