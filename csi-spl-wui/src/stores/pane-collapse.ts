// Spec 050: the shared collapsed state of the 3 vertical panels (channels,
// topic, threads). A Pinia store, not a composable return, because the toggles
// live inside three sibling components (ChannelSidebar, the middle main in
// layouts/default, the thread pane) and the layout also reads it to size the
// panes — they all need the SAME reactive state, not one instance threaded
// through props. Persistence is localStorage today (key `spool.pane-collapsed`);
// CLE-35099's SPL-1182 lifts the same {channels,topic,threads} shape to the
// account under `pane_collapsed`. See utils/pane-collapse.mjs.
import { defineStore } from 'pinia'
import { ref } from 'vue'
import {
  PANES,
  loadCollapsed,
  saveCollapsed,
  normalizeCollapsed,
} from '~/utils/pane-collapse.mjs'

export type PaneName = 'channels' | 'topic' | 'threads'
type CollapsedMap = Record<PaneName, boolean>

export const usePaneCollapse = defineStore('pane-collapse', () => {
  const collapsed = ref<CollapsedMap>({ channels: false, topic: false, threads: false })
  let loaded = false

  function storage(): Storage | null {
    return typeof window !== 'undefined' ? window.localStorage : null
  }

  /** Hydrate from localStorage once, on the client (the shell is ClientOnly). */
  function load() {
    if (loaded || typeof window === 'undefined') return
    collapsed.value = normalizeCollapsed(loadCollapsed(storage())) as CollapsedMap
    loaded = true
  }

  function set(pane: PaneName, val: boolean) {
    if (!PANES.includes(pane)) return
    collapsed.value = { ...collapsed.value, [pane]: !!val }
    saveCollapsed(storage(), collapsed.value)
  }

  function toggle(pane: PaneName) {
    set(pane, !collapsed.value[pane])
  }

  return { collapsed, load, set, toggle }
})
