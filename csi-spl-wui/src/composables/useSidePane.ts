import { computed, ref } from 'vue'

export type SidePaneId = 'dm' | 'channels' | 'topics' | 'flow'

/** One shared request so the omnibox and the sidebar talk about the same pane. */
const requested = ref<{ id: SidePaneId, n: number, stay: boolean } | null>(null)
/** The tab the sidebar is showing. The omnibox reads it when a message is sent. */
const current = ref<SidePaneId>('dm')
/** CLE-77882: open-in-place navigations in flight; while > 0 the route does not switch the tab. */
const listHolds = ref(0)

export function useSidePane() {
  function request(id: SidePaneId) {
    requested.value = { id, n: (requested.value?.n || 0) + 1, stay: false }
  }
  /** Show this list without leaving the page. The replies link uses it. */
  function reveal(id: SidePaneId) {
    requested.value = { id, n: (requested.value?.n || 0) + 1, stay: true }
  }
  function setCurrent(id: SidePaneId) {
    current.value = id
  }
  /** Keep the list the left panel shows while a message opens in place. Call the result to release. */
  function holdList() {
    listHolds.value += 1
    let held = true
    return () => {
      if (!held) return
      held = false
      listHolds.value -= 1
    }
  }
  const listHeld = computed(() => listHolds.value > 0)
  return { requested, request, reveal, current, setCurrent, holdList, listHeld }
}
