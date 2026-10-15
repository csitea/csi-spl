import { useSessionStore } from '~/stores/session'
import { AWAIT_ANIM_IDS, AWAIT_ROTATE_ORDER, DEFAULT_AWAIT_ANIM, createRotateClock, readAwaitAnim, writeAwaitAnim } from '~/utils/await-reply.mjs'

/**
 * SPL-2027: the person's own "thinking" animation (Settings -> Appearance),
 * kept in this browser per signed-in person (utils/await-reply.mjs). Only the
 * lazy AwaitReply mark and the setting use it, so it stays off the first
 * screen. One shared state: a pick in Settings redraws every open mark.
 */
export function useAwaitAnim() {
  const session = useSessionStore()
  const pick = useState<string>('spool-await-anim', () => DEFAULT_AWAIT_ANIM)
  const read = () => { if (import.meta.client) pick.value = readAwaitAnim(session.claims) }
  onMounted(read)
  watch(() => `${session.claims?.t || ''}:${session.claims?.hum || ''}`, read)

  function setPick(id: string) {
    pick.value = import.meta.client ? writeAwaitAnim(session.claims, id) : id
  }

  return { pick, ids: AWAIT_ANIM_IDS as readonly string[], setPick }
}

/* SPL-2043: one clock and one drawing for every rotating mark in this tab */
let clock: ReturnType<typeof createRotateClock> | null = null
const rotateNow = ref<string>(AWAIT_ROTATE_ORDER[0])

/**
 * SPL-2043: the drawing `rotate` shows now, while `active` (spinning, motion
 * welcome) holds; the first drawing, still, otherwise. Every caller shares the
 * one clock; it stops when the last active mark goes (unmount included).
 */
export function useAwaitRotate(active: Ref<boolean>) {
  let stop: (() => void) | null = null
  const off = () => { stop?.(); stop = null }
  const on = () => {
    if (stop || !import.meta.client) return
    clock ??= createRotateClock()
    stop = clock.subscribe((id: string) => { rotateNow.value = id })
  }
  watch(active, (a) => (a ? on() : off()), { immediate: true })
  onScopeDispose(off)
  return computed(() => (active.value ? rotateNow.value : AWAIT_ROTATE_ORDER[0]))
}
