// Link the web app manifest, then register the PWA service worker
// (public/sw.js) in a built bundle only. `nuxt dev` runs Vite's HMR worker
// from blob: and must never get a long-lived worker in the way; a failed
// register is logged, never thrown.
//
// Both wait for onNuxtReady (the first page painted, then an idle moment)
// (CLE-77933): a <link rel="manifest"> in the document made Chrome fetch the
// manifest and its 192 px icon while the first screen's chunks were still
// loading - 2 requests / 36.7 KB before the left rail on prd's cold first
// load (do_spl_wui_perf_first_load_net). Install needs neither earlier.
import { IDLE_POLL_MS, normCommit } from '~/utils/build-watch.mjs'
import { readReloadGuard, reloadForBuild, useBuildWatch } from '~/composables/useBuildWatch'
import { capturePwaInstall } from '~/utils/pwa-install.mjs'

const MANIFEST_HREF = '/manifest.webmanifest'
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

export default defineNuxtPlugin(() => {
  // HUM-10: keep Chrome's one install event for Settings' Install button; it
  // fires once the manifest below is linked, before Settings is opened.
  capturePwaInstall(window)
  onNuxtReady(() => {
    if (!document.querySelector('link[rel="manifest"]')) {
      const link = document.createElement('link')
      link.rel = 'manifest'
      link.href = MANIFEST_HREF
      document.head.appendChild(link)
    }
    if (import.meta.dev) return
    if (!('serviceWorker' in navigator)) return
    navigator.serviceWorker
      .register('/sw.js', { scope: '/', updateViaCache: 'none' })
      .catch((err) => console.warn('[pwa] service worker not registered:', err))
  })
  if (import.meta.dev) return
  if (!('serviceWorker' in navigator)) return
  // W9: a tab the worker's shell answered with build A while the network
  // now serves B moves to B by build-watch's own rules (SPL-1006): idle ->
  // reload (a reload always goes to the network, never to the shell), a
  // draft or dialog -> the "new version" bar, and the per-tab reload guard
  // still holds. The worker pushes SHELL_STALE when it learns of B; a push
  // that lands before this plugin listens is lost, so the tab also asks
  // (SHELL_ASK) once it listens. Both run the same idempotent check, and only
  // once the app is ready: a location.reload() during boot is cancelled by
  // the boot's own navigations (measured: 3 of 20 swaps kept A with the
  // reload guard set, so build-watch then only showed its bar).
  const ownBuild = String(useRuntimeConfig().app.buildId || '')
  const watch = useBuildWatch()
  let acted = ''
  let ready = false
  let early: { type?: string, build?: string, commit?: string } | null = null
  onNuxtReady(() => {
    ready = true
    if (early) onShellBuild(early)
  })
  function onShellBuild(d: { type?: string, build?: string, commit?: string } | null) {
    if (!d || d.type !== SHELL_STALE || !d.build || d.build === ownBuild || d.build === acted) return
    if (!ready) {
      early = d
      return
    }
    const live = normCommit(d.commit)
    if (!live) return
    acted = d.build
    watch.value.live = live
    /* the rules load here, after ready, not in the first download (ci_initial_gzip_kb) */
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
      .catch(() => {})
  })
})
