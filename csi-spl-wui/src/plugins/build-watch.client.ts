// SPL-1006: notice a new deploy in an open tab (see utils/build-watch.mjs).
// Asks /build.json when the tab becomes visible, on window focus, when the
// page is restored from the back/forward cache, and every 5 minutes while
// visible. Idle -> a silent reload; a draft or an open dialog -> the bar,
// and a reload by itself once the page is idle again.
// HUM-10 fb8d109f: a RESUME (hidden >= RESUME_AFTER_MS, the phone put away)
// skips the 20 s gap, counts an empty focused field as idle, and retries a
// read that failed while the radio was still waking; so does `online`.
// The polling itself (utils/build-watch-run.ts) loads once the app is ready:
// it is off the initial download (ci_initial_gzip_kb), and the first check
// waits for an event or the 5-minute tick anyway.
import { useBuildWatch } from '~/composables/useBuildWatch'

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
  // a tab hidden before the module loads still counts as a resume when it returns
  let hiddenAt = document.visibilityState === 'hidden' ? Date.now() : 0
  const onHide = () => { if (document.visibilityState === 'hidden') hiddenAt = hiddenAt || Date.now() }
  document.addEventListener('visibilitychange', onHide)
  onNuxtReady(() => void import('~/utils/build-watch-run').then(({ startBuildWatch }) => {
    document.removeEventListener('visibilitychange', onHide)
    startBuildWatch(state, running, hiddenAt)
  }))
})
