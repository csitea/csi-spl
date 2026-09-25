// Spool service worker — makes the WUI an installable PWA, and nothing else.
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
