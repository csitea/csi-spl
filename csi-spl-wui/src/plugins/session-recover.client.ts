// HUM-10 fb8d109f: a page whose session probe failed asks again, so a
// reload into a new build (or a reopened phone app) keeps the session
// instead of showing an empty shell (see utils/session-recover.mjs).
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { markSignedIn, recoverDelay, reprobeOnReturn, unsettled } from '~/utils/session-recover.mjs'

export default defineNuxtPlugin(() => {
  if (useSpoolApi().mock) return
  const session = useSessionStore()
  let attempt = 0
  let timer: ReturnType<typeof setTimeout> | null = null
  let hiddenAt = document.visibilityState === 'hidden' ? Date.now() : 0

  function stop() {
    if (timer) clearTimeout(timer)
    timer = null
  }

  function probeNow() {
    stop()
    void session.probe().finally(schedule)
  }

  // 'unknown' asks again on a backoff; a hidden tab waits for its return
  function schedule() {
    stop()
    if (session.state !== 'unknown' || document.visibilityState === 'hidden') return
    timer = setTimeout(() => { timer = null; attempt++; probeNow() }, recoverDelay(attempt))
  }

  watch(() => session.state, (st) => {
    if (st === 'in') markSignedIn(true)
    if (!unsettled(st)) { attempt = 0; stop() }
    if (st === 'unknown' && !timer) schedule()
  }, { immediate: true })

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') { hiddenAt = hiddenAt || Date.now(); stop(); return }
    const hiddenMs = hiddenAt ? Date.now() - hiddenAt : 0
    hiddenAt = 0
    if (reprobeOnReturn({ state: session.state, hiddenMs })) probeNow()
  })
  window.addEventListener('online', () => {
    if (session.state === 'unknown') { attempt = 0; probeNow() }
  })
})
