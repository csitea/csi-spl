// Topic c6994436: the person's layout choices, Settings -> Behaviour ->
// "Message order" and "Omnibox position". Each is a session claim kept on the
// hub (humans.message_order / composer_position), so a change there reaches
// every open pane at once and every device on its next sign-in. Signed out or
// never picked = today's layout (newest first, Omnibox at the top).
//
// Feeds read `newestLast`; the top bar / composer read `composerPosition`.
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import {
  applyViewPref, parseComposerPosition, parseMessageOrder,
  type ComposerPosition, type MessageOrder, type ViewPrefKey,
} from '~/utils/view-prefs.mjs'

export function useViewPrefs() {
  const session = useSessionStore()
  const auth = useAuthClient()
  const messageOrder = computed<MessageOrder>(() => parseMessageOrder(session.claims?.message_order))
  const composerPosition = computed<ComposerPosition>(() => parseComposerPosition(session.claims?.composer_position))
  const newestLast = computed(() => messageOrder.value === 'newest-last')

  /** Store one choice (optimistic). Resolves the save's outcome. */
  async function save(key: ViewPrefKey, want: string) {
    if (session.state !== 'in') return { ok: false, value: '' }
    return applyViewPref(key, want, {
      current: session.claims?.[key],
      apply: (v: string) => session.setViewPref(key, v),
      save: (v: string) => auth.saveViewPref(key, v),
    })
  }

  return { messageOrder, composerPosition, newestLast, save }
}
