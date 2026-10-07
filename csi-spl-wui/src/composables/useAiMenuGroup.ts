/*
 * t1 b6c742f0 (HUM-10 14dc0232: "add those same actions to every msg card in
 * every view"; 643c30a8: "every card which has right click menu"): the AI
 * actions group of one open card menu - the card's MessageMenu, the search /
 * Flow row menu (SearchRowMenu), a topic row's menu (SidebarRowAi) and the
 * issue / epic menu (pages/issues.vue) alike. `aiMsg` is the card's subject
 * (utils/msg-ai-actions.mjs aiSubject). The entries follow withAiItems; on a
 * phone the one "AI actions" entry turns the same sheet into the actions.
 * Only lazy menus and pages import this, so it rides in their chunks.
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
  /** true when the close that follows a pick must be skipped; a real close
      starts the next open on the whole menu again (a menu that stays mounted) */
  function keep() {
    if (!keepOpen) {
      only.value = false
      return false
    }
    keepOpen = false
    return true
  }
  return { sheet, items, more, keep }
}
