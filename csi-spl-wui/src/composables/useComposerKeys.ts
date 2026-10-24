// r20-01: the composer field's keys, moved out of MessageComposer.vue.
//
// onKeydown is the field's one keydown handler. In this order: the
// open-channel ask, the syntax panel's Esc, the operator list, the top bar's
// keys (022, onGlobalKey), Esc out of a code fence, the omnibox's Esc, the
// @ and `in:` pickers, then Enter, which sends when the reader's Enter mode
// (SPL-976, useSubmitKey) says so.
import type { Ref } from 'vue'
import { exitFence, fenceStateAt } from '~/utils/code-blocks.mjs'
import { perfKeydown } from '~/utils/perf-mark.mjs'
import type { ComposerProps } from '~/composables/composerProps'

type KeysEmit = {
  (e: 'search', q: string): void
  (e: 'results'): void
  (e: 'dismiss'): void
}

export interface ComposerKeysOpts {
  props: ComposerProps
  emit: KeysEmit
  text: Ref<string>
  inputEl: Ref<HTMLTextAreaElement | null>
  inCode: Ref<boolean>
  searchMode: Readonly<Ref<boolean>>
  syntaxOpen: Ref<boolean>
  pickerOpen: Readonly<Ref<boolean>>
  inPickerOpen: Readonly<Ref<boolean>>
  mp: { onKeydown: (ev: KeyboardEvent) => boolean }
  openAsk: { onKey: (ev: KeyboardEvent) => boolean }
  onOperatorKey: (ev: KeyboardEvent) => boolean
  onInKey: (ev: KeyboardEvent) => boolean
  caret: () => number
  keyAction: (ev: KeyboardEvent, opts?: { inCode?: boolean }) => string
  onSend: () => unknown
  collapseGlobalBox: (park: boolean) => void
}

export function useComposerKeys(o: ComposerKeysOpts) {
  const { props, emit, text, inputEl, inCode, searchMode, syntaxOpen, pickerOpen, inPickerOpen, caret } = o

  function onKeydown(ev: KeyboardEvent) {
    /* spec 066 M6: keydown -> the next paint (one in ten; a no-op with RUM off) */
    perfKeydown(ev.timeStamp)
    if (ev.isComposing) return
    /* the choice is up: Enter opens, Esc keeps the text */
    if (o.openAsk.onKey(ev)) return
    if (syntaxOpen.value && ev.key === 'Escape') {
      ev.preventDefault()
      syntaxOpen.value = false
      return
    }
    if (o.onOperatorKey(ev)) return
    if (props.global && onGlobalKey(ev)) return
    if (inCode.value && ev.key === 'Escape' && !pickerOpen.value && !inPickerOpen.value) {
      // Slack's exit: close the block at the caret, keep typing below it
      ev.preventDefault()
      const next = exitFence(text.value, caret())
      text.value = next.text
      inCode.value = false
      nextTick(() => inputEl.value?.setSelectionRange(next.cursor, next.cursor))
      return
    }
    if (props.omnibox && ev.key === 'Escape' && !pickerOpen.value && !inPickerOpen.value) {
      emit('search', '')
      return
    }
    if (o.mp.onKeydown(ev) || o.onInKey(ev)) return
    if (ev.key === 'Enter') {
      const state = fenceStateAt(text.value, caret())
      inCode.value = state.inCode
      if (o.keyAction(ev, { inCode: state.inCode }) === 'submit') {
        ev.preventDefault()
        o.onSend()
        o.collapseGlobalBox(false)
      }
    }
  }

  /** 022 top-bar keys; true = handled. */
  function onGlobalKey(ev: KeyboardEvent): boolean {
    if (searchMode.value) {
      if (ev.key === 'Enter' && !ev.shiftKey && (ev.ctrlKey || ev.metaKey)) {
        ev.preventDefault()
        o.onSend()
        o.collapseGlobalBox(false)
        return true
      }
      if (ev.key === 'Enter' && !ev.shiftKey) {
        ev.preventDefault()
        o.onSend()
        o.collapseGlobalBox(false)
        return true
      }
      if (ev.key === 'ArrowDown' && caret() === text.value.length) {
        ev.preventDefault()
        emit('results')
        return true
      }
    }
    if (ev.key === 'Escape' && !inCode.value && !pickerOpen.value && !inPickerOpen.value) {
      ev.preventDefault()
      if (text.value) text.value = ''
      else emit('dismiss')
      return true
    }
    return false
  }

  return { onKeydown }
}
