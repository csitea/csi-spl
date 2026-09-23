import { ref } from 'vue'

export type SidePaneId = 'dm' | 'channels' | 'topics' | 'flow'

/** One shared request so the omnibox and the sidebar talk about the same pane. */
const requested = ref<{ id: SidePaneId, n: number, stay: boolean } | null>(null)
/** The tab the sidebar is showing. The omnibox reads it when a message is sent. */
const current = ref<SidePaneId>('dm')

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
  return { requested, request, reveal, current, setCurrent }
}
