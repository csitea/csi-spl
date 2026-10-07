import { defineStore } from 'pinia'
import { ref } from 'vue'
import { VIM_PANELS, vimItemKey, type VimPanel } from '~/utils/vim-panels.mjs'

/* Spec 103 T004 (t1 7d9e1681): where vim navigation stands - the panel it is
   in (0 = icon rail, 1 = left list, 2 = centre list, 3 = topic pane), the row
   it last selected in each panel (spec 4.1 step 1: an entered panel lands on
   its remembered row) and the panels it came through, for `back`.
   Loaded only by the lazy listener (composables/useVimNavigation.ts, T005):
   nothing eager imports this file, so the initial chunk does not grow. */

export type { VimPanel }

/** How many panel moves `back` remembers. */
export const VIM_HISTORY_MAX = 32

const isPanel = (p: unknown): p is VimPanel => (VIM_PANELS as readonly unknown[]).includes(p)

const noKeys = (): Record<VimPanel, string> => ({ 0: '', 1: '', 2: '', 3: '' })

export const useVimNav = defineStore('vim-nav', () => {
  const activePanel = ref<VimPanel>(0)
  const selectedKeyPerPanel = ref<Record<VimPanel, string>>(noKeys())
  const history = ref<VimPanel[]>([])

  /** Move to `panel`; the panel left behind goes on the history. Not a panel, or the same one: no change. */
  function setPanel(panel: number): boolean {
    if (!isPanel(panel) || panel === activePanel.value) return false
    history.value.push(activePanel.value)
    if (history.value.length > VIM_HISTORY_MAX) history.value.shift()
    activePanel.value = panel
    return true
  }

  /** Remember a row of `panel`: an element (its vimItemKey) or the key itself. '' forgets. */
  function select(panel: number, item: unknown) {
    if (!isPanel(panel)) return
    selectedKeyPerPanel.value[panel] = typeof item === 'string' ? item : vimItemKey(item)
  }

  /** The row `panel` remembers ('' when none): panelEntry's `remembered`. */
  function remembered(panel: number): string {
    return isPanel(panel) ? selectedKeyPerPanel.value[panel] : ''
  }

  /** Esc: back to the nearest panel we came from on the left (h / l moves the
      other way are dropped), else one panel left; never past 0. Returns the panel now active. */
  function back(): VimPanel {
    let to = Math.max(activePanel.value - 1, 0) as VimPanel
    while (history.value.length) {
      const from = history.value.pop() as VimPanel
      if (from < activePanel.value) {
        to = from
        break
      }
    }
    activePanel.value = to
    return to
  }

  /** A route change: the per-panel memory holds only while on the same route (spec 4.1). */
  function resetRoute() {
    selectedKeyPerPanel.value = noKeys()
    history.value = []
  }

  return { activePanel, selectedKeyPerPanel, history, setPanel, select, remembered, back, resetRoute }
})
