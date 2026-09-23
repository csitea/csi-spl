import { ref } from 'vue'

export type SidePaneId = 'dm' | 'channels' | 'topics' | 'flow'

/** One shared request so the omnibox and the sidebar talk about the same pane. */
const requested = ref<{ id: SidePaneId, n: number } | null>(null)

export function useSidePane() {
  function request(id: SidePaneId) {
    requested.value = { id, n: (requested.value?.n || 0) + 1 }
  }
  return { requested, request }
}
