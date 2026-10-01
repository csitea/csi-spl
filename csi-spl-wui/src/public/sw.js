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

/**
 * Where a tap goes: the alert's own deep link (a same-origin path), else the
 * feed its tag names (ch:<name> / dm:<peer>, the tag every alert has carried
 * since bug A) - an alert raised by a page still on an older bundle has no
 * data, and its tap must still leave "where I was" (owner, bd6d7291 msg
 * 5f40daa7) - else '/'.
 */
function targetUrl(data, tag) {
  const url = String((data && data.url) || '')
  if (url.startsWith('/') && !url.startsWith('//')) return url
  const t = String(tag || '')
  const ch = t.startsWith('ch:') ? t.slice(3) : ''
  if (ch) return '/channel/' + encodeURIComponent(ch)
  const dm = t.startsWith('dm:') ? t.slice(3) : ''
  if (dm) return '/dm/' + encodeURIComponent(dm)
  return '/'
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

async function openFromNotification(data, tag) {
  const url = targetUrl(data, tag)
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
  event.waitUntil(openFromNotification(event.notification.data, event.notification.tag))
})
