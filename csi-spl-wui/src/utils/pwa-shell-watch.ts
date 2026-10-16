// W9 + CLE-77890, the service worker's half of pwa.client.ts that waits for
// onNuxtReady: it loads then, not in the first download (ci_initial_gzip_kb,
// SPL-2115). Read as a member of import(): a bare name from a utils/ module
// makes Nuxt's auto-import add a static import of it.
import { IDLE_POLL_MS, normCommit } from '~/utils/build-watch.mjs'
import { readReloadGuard, reloadForBuild } from '~/composables/useBuildWatch'
import type { useBuildWatch } from '~/composables/useBuildWatch'

// W9: public/sw.js answered this tab from its app shell while the network
// (read in the background) already names another build - see sw.js.
const SHELL_STALE = 'spool:shell-stale'
const SHELL_ASK = 'spool:shell-ask'

/** build-watch's decision for the build the worker's shell reported (W9). */
function actOnShellBuild(
  { decide, pageBusy }: typeof import('~/utils/build-watch-rules.mjs'),
  watch: ReturnType<typeof useBuildWatch>,
  live: string,
) {
  const guard = readReloadGuard()
  const act = decide({ running: watch.value.running, live, busy: pageBusy(), guard })
  if (act === 'reload') return reloadForBuild(live)
  watch.value.prompt = act === 'prompt'
  // as build-watch: a busy page reloads by itself once idle on two reads
  // in a row, unless this tab already reloaded for that build (bar only)
  if (act !== 'prompt' || guard === live) return
  let idleSeen = 0
  const idleTimer = setInterval(() => {
    idleSeen = pageBusy() ? 0 : idleSeen + 1
    if (idleSeen < 2) return
    clearInterval(idleTimer)
    reloadForBuild(live)
  }, IDLE_POLL_MS)
}

/**
 * W9: a tab the worker's shell answered with build A while the network now
 * serves B moves to B by build-watch's own rules (SPL-1006): idle -> reload
 * (a reload always goes to the network, never to the shell), a draft or
 * dialog -> the "new version" bar, and the per-tab reload guard still holds.
 * The worker pushes SHELL_STALE when it learns of B; a push that lands before
 * this listens is lost, so the tab also asks (SHELL_ASK) once it listens.
 * Both run the same idempotent check. Called once the app is ready: a
 * location.reload() during boot is cancelled by the boot's own navigations
 * (measured: 3 of 20 swaps kept A with the reload guard set, so build-watch
 * then only showed its bar).
 */
export function watchShellBuild(ownBuild: string, watch: ReturnType<typeof useBuildWatch>) {
  let acted = ''
  function onShellBuild(d: { type?: string, build?: string, commit?: string } | null) {
    if (!d || d.type !== SHELL_STALE || !d.build || d.build === ownBuild || d.build === acted) return
    const live = normCommit(d.commit)
    if (!live) return
    acted = d.build
    watch.value.live = live
    void import('~/utils/build-watch-rules.mjs').then((rules) => actOnShellBuild(rules, watch, live))
  }
  navigator.serviceWorker.addEventListener('message', (e: MessageEvent) => onShellBuild(e.data))
  const sw = navigator.serviceWorker.controller
  if (sw) {
    const ch = new MessageChannel()
    ch.port1.onmessage = (e: MessageEvent) => { ch.port1.close(); onShellBuild(e.data) }
    sw.postMessage({ type: SHELL_ASK }, [ch.port2])
  }
  // CLE-77890: a phone keeps one tab alive for days and a single-page app
  // never navigates, so the browser would not look for a new worker. Ask
  // whenever the tab comes back (at most once a minute); the new one
  // activates at once (skipWaiting + clients.claim).
  let checkedAt = 0
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || Date.now() - checkedAt < 60000) return
    checkedAt = Date.now()
    void navigator.serviceWorker.getRegistration()
      .then((reg) => reg && reg.update())
      // no registration yet, or the browser refused the check: the next visible tab asks again
      .catch(() => {})
  })
}
