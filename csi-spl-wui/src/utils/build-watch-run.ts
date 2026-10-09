// SPL-1006: the /build.json polling of plugins/build-watch.client.ts, loaded
// once the app is ready so it rides no first-screen chunk
// (ci_initial_gzip_kb, c-002 52909f53). The rules are utils/build-watch-rules.mjs.
import type { Ref } from 'vue'
import { CHECK_EVERY_MS, IDLE_POLL_MS, MIN_GAP_MS } from '~/utils/build-watch.mjs'
import { decide, isResume, pageBusy, readLiveCommit, retryDelay } from '~/utils/build-watch-rules.mjs'
import { readReloadGuard, reloadForBuild } from '~/composables/useBuildWatch'
import type { BuildWatchState } from '~/composables/useBuildWatch'

/** Ask /build.json on visibility, focus, bfcache restore, online and every 5 min. */
export function startBuildWatch(state: Ref<BuildWatchState>, running: string, hiddenSince: number) {
  let lastAt = 0
  let idleTimer: ReturnType<typeof setInterval> | null = null
  let idleSeen = 0
  let hiddenAt = hiddenSince
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
}
