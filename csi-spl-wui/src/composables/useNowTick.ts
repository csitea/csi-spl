import { onUnmounted, ref, toValue, watch, type MaybeRefOrGetter } from 'vue'
import { createNowTick } from '~/utils/now-tick.mjs'

/**
 * A 1 Hz clock, running only while `enabled` is true (an open topic pane)
 * and the tab is visible.
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
  /* CLE-35075: paused while the tab is hidden (utils/now-tick.mjs) */
  const clock = createNowTick({
    set: (ms: number) => { now.value = ms },
    doc: import.meta.client ? document : null,
  })

  watch(
    () => toValue(enabled),
    (on) => { clock.enable(on) },
    { immediate: true },
  )
  onUnmounted(() => clock.dispose())
  return now
}
