// SPL-1006: notice a new deploy in an open tab (see utils/build-watch.mjs).
// Asks /build.json when the tab becomes visible, on window focus, when the
// page is restored from the back/forward cache, and every 5 minutes while
// visible. Idle -> a silent reload; a draft or an open dialog -> the bar,
// and a reload by itself once the page is idle again.
// HUM-10 fb8d109f: a RESUME (hidden >= RESUME_AFTER_MS, the phone put away)
// skips the 20 s gap, counts an empty focused field as idle, and retries a
// read that failed while the radio was still waking; so does `online`.
import { CHECK_EVERY_MS, IDLE_POLL_MS, MIN_GAP_MS, decide, isResume, pageBusy, readLiveCommit, retryDelay } from '~/utils/build-watch.mjs'
import { readReloadGuard, reloadForBuild, useBuildWatch } from '~/composables/useBuildWatch'

declare global {
  interface Window { __BUILD__?: { commit: string, run: string, built_at: string } }
}

export default defineNuxtPlugin(() => {
  const pub = useRuntimeConfig().public
  const state = useBuildWatch()
  const running = state.value.running
  window.__BUILD__ = { commit: running, run: String(pub.buildRun || ''), built_at: String(pub.buildAt || '') }
  // lde and unstamped builds have nothing to compare against
  if (!running) return

  let lastAt = 0
  let idleTimer: ReturnType<typeof setInterval> | null = null
  let idleSeen = 0
  let hiddenAt = document.visibilityState === 'hidden' ? Date.now() : 0
  let failed = 0
  let retryTimer: ReturnType<typeof setTimeout> | null = null

  function stopIdle() {
    if (idleTimer) clearInterval(idleTimer)
    idleTimer = null
    idleSeen = 0
  }

  function act(resumed: boolean) {
    const live = state.value.live
    const guard = readReloadGuard()
    const d = decide({ running, live, busy: pageBusy(document, { resumed }), guard })
    if (d === 'reload') return reloadForBuild(live)
    state.value.prompt = d === 'prompt'
    // the guard forbids a second reload by ourselves: then only a tap does
    if (d === 'prompt' && guard !== live && !idleTimer) {
      idleTimer = setInterval(() => {
        // idle on two reads in a row: a composer that cleared on send has
        // its row pending (data-pending) by the second read, never lost
        idleSeen = pageBusy() ? 0 : idleSeen + 1
        if (idleSeen >= 2) { stopIdle(); reloadForBuild(state.value.live) }
      }, IDLE_POLL_MS)
    }
    if (d === 'none') stopIdle()
  }

  async function check(resumed = false) {
    if (document.visibilityState === 'hidden') return
    const now = Date.now()
    if (!resumed && now - lastAt < MIN_GAP_MS) return
    lastAt = now
    if (retryTimer) { clearTimeout(retryTimer); retryTimer = null }
    const { commit } = await readLiveCommit()
    if (!commit) {
      // a resume whose read failed asks again shortly (the radio waking)
      const wait = resumed ? retryDelay(++failed) : -1
      if (wait >= 0) retryTimer = setTimeout(() => { retryTimer = null; void check(true) }, wait)
      return
    }
    failed = 0
    state.value.live = commit
    act(resumed)
  }

  function resume() {
    const resumed = isResume(hiddenAt)
    hiddenAt = 0
    failed = 0
    void check(resumed)
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') { hiddenAt = hiddenAt || Date.now(); return }
    resume()
  })
  window.addEventListener('focus', () => { void check() })
  window.addEventListener('pageshow', (ev) => { if ((ev as PageTransitionEvent).persisted) void check(true) })
  window.addEventListener('online', () => { lastAt = 0; void check() })
  setInterval(() => { void check() }, CHECK_EVERY_MS)
})
