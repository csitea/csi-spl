import { onUnmounted, ref, unref, watch, type MaybeRef } from 'vue'

/**
 * A 1 Hz clock, running only while `enabled` is true (an open thread pane).
 * `now` is Date.now() at each tick; the first tick is immediate on enable so
 * "seconds ago from opening this thread" is defined before the first interval.
 */
export function useNowTick(enabled: MaybeRef<boolean>) {
  const now = ref(Date.now())
  let id: ReturnType<typeof setInterval> | null = null

  function stop() {
    if (id != null) {
      clearInterval(id)
      id = null
    }
  }

  function start() {
    now.value = Date.now()
    if (id != null) return
    id = setInterval(() => { now.value = Date.now() }, 1000)
  }

  watch(
    () => unref(enabled),
    (on) => { on ? start() : stop() },
    { immediate: true },
  )
  onUnmounted(stop)
  return now
}
