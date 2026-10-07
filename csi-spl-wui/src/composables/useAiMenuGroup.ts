/*
 * t1 b6c742f0 (HUM-10 14dc0232: "add those same actions to every msg card in
 * every view"): the AI actions group of one open message menu - the card's
 * MessageMenu and the search / Flow row menu (SearchRowMenu) alike. The
 * entries follow utils/msg-ai-actions.mjs withAiItems; on a phone the one
 * "AI actions" entry turns the same sheet into the seven actions.
 * Only those lazy menus import this, so it rides in their chunks.
 */
import { withAiItems } from '~/utils/msg-ai-actions.mjs'
import { usePhone } from '~/composables/useTouchUi'

export function useAiMenuGroup(aiMsg: () => unknown) {
  const sheet = usePhone()
  const only = ref(false)
  /* the pick of "AI actions" is not a close: UiPointMenu emits close after every pick */
  let keepOpen = false
  /** the menu's own entries plus the group */
  function items<T extends { id: string }>(base: T[]) {
    return withAiItems(base, aiMsg(), { sheet: sheet.value, only: only.value })
  }
  /** true when `id` is the phone's "AI actions" entry: the sheet stays and shows the seven */
  function more(id: string) {
    if (id !== 'ai-more') return false
    only.value = true
    keepOpen = true
    return true
  }
  /** true when the close that follows a pick must be skipped */
  function keep() {
    if (!keepOpen) return false
    keepOpen = false
    return true
  }
  return { sheet, items, more, keep }
}
