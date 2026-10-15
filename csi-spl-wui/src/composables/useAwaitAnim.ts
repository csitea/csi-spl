import { useSessionStore } from '~/stores/session'
import { DEFAULT_AWAIT_ANIM, readAwaitAnim, writeAwaitAnim } from '~/utils/await-reply.mjs'

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

  return { pick, setPick }
}
