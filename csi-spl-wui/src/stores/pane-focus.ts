import { defineStore } from 'pinia'
import { paneOfTarget, RIGHT } from '~/utils/pane-focus.mjs'

/** The pane the reader selected last (utils/pane-focus.mjs). */
export const usePaneFocus = defineStore('pane-focus', () => {
  const last = ref<'' | 'middle' | 'right'>('')

  function set(pane: '' | 'middle' | 'right') {
    if (pane) last.value = pane
  }

  /** pointerdown / focusin anywhere in the shell */
  function noteEvent(ev: Event) {
    set(paneOfTarget(ev.target))
  }

  /** a topic was opened on the right: the reader is there now */
  function openedTopic() {
    set(RIGHT)
  }

  return { last, set, noteEvent, openedTopic }
})
