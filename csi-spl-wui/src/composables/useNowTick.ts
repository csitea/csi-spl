import { onUnmounted, ref, toValue, watch, type MaybeRefOrGetter } from 'vue'

/**
 * A 1 Hz clock, running only while `enabled` is true (an open topic pane).
 * `now` is Date.now() at each tick; the first tick is immediate on enable so
 * "seconds ago from opening this topic" is defined before the first interval.
 */
/* MaybeRefOrGetter, not MaybeRef. All three call sites pass a
 * GETTER - `() => topic.open`, `() => Boolean(pane.taskId)`,
 * `() => Boolean(taskId.value)` - which typecheck refused (TS2345) and which
 * `unref` cannot read: unref(fn) hands back the function, and a function is
 * always truthy, so the watch source was a CONSTANT true. The 1 Hz interval
 * therefore started on mount and never stopped when the pane closed, which is
 * the opposite of what the doc comment above promises. `toValue` calls a
 * getter and unwraps a ref, so both shapes work and the clock stops again. */
export function useNowTick(enabled: MaybeRefOrGetter<boolean>) {
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
    () => toValue(enabled),
    (on) => { on ? start() : stop() },
    { immediate: true },
  )
  onUnmounted(stop)
  return now
}
