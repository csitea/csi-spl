import { defineStore } from 'pinia'
import { eventChoosesPane, isKeyNav, onScrollbar, paneOfTarget, RIGHT } from '~/utils/pane-focus.mjs'

/** The pane the reader selected last (utils/pane-focus.mjs). */
export const usePaneFocus = defineStore('pane-focus', () => {
  const last = ref<'' | 'middle' | 'right'>('')
  /* SPL-996: when the reader last pressed a navigation key (a focusin after
     one is theirs; a focusin the app made is not a choice) */
  let keyNavAt = 0

  function set(pane: '' | 'middle' | 'right') {
    if (pane) last.value = pane
  }

  /** keydown anywhere in the document (layouts/default.vue) */
  function noteKey(ev: KeyboardEvent) {
    if (isKeyNav(ev)) keyNavAt = Date.now()
  }

  /** pointerdown / focusin anywhere in the shell */
  function noteEvent(ev: Event) {
    const pe = ev as PointerEvent
    const chooses = eventChoosesPane({
      type: ev.type,
      onScrollbar: ev.type === 'pointerdown' && onScrollbar({ target: ev.target, offsetX: pe.offsetX, offsetY: pe.offsetY }),
      keyNavAt,
      now: Date.now(),
    })
    if (chooses) set(paneOfTarget(ev.target))
  }

  /** a topic was opened on the right: the reader is there now */
  function openedTopic() {
    set(RIGHT)
  }

  return { last, set, noteKey, noteEvent, openedTopic }
})
