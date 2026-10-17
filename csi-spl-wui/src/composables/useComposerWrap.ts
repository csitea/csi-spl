// r13-03: is the top-bar draft more than one line? Moved out of
// MessageComposer.vue; useComposerSize calls it.
//
// Owner, t1 26282b6e: more than one line lifts the glyph and the chip onto
// a row above the text. The answer is the one-line content box (the indent
// below), so it does not flip again when that indent is removed. A blur
// parks the bar at one line; the row comes back with the caret.
import type { Ref } from 'vue'
import { omniboxIsMultiline, omniboxOneLinePad } from '~/utils/omnibox-size.mjs'
import type { ComposerProps } from '~/composables/composerProps'

export interface WrapOpts {
  inputEl: Ref<HTMLTextAreaElement | null>
  text: Ref<string>
  props: ComposerProps
  docked: Ref<boolean>
  modeGlyph: Ref<string | null>
  chip: Ref<boolean>
  chipEl: Ref<HTMLElement | null>
  parked: Ref<boolean>
  /** re-fit the field once the layout flipped (useComposerSize) */
  fit: () => void
}

/* the text starts after the chip: its ONE-LINE width, live. The lifted row
   caps the chip narrower (40% vs the dock's full width), and the wrap is
   judged against the one-line box, so that row's width is not taken: it fed
   back into the judgement and flipped a short draft between the layouts
   (measured on the 390 dock, DejaVu: chip 127 px one-line, 66 px lifted). */
function useChipWidth(chipEl: Ref<HTMLElement | null>, lifted: () => boolean) {
  const chipW = ref(0)
  let chipObserver: ResizeObserver | null = null
  watch(chipEl, (el) => {
    chipObserver?.disconnect()
    chipObserver = null
    if (!el) return
    chipW.value = el.offsetWidth
    if (typeof ResizeObserver === 'undefined') return
    chipObserver = new ResizeObserver(() => { if (!lifted()) chipW.value = el.offsetWidth })
    chipObserver.observe(el)
  })
  onBeforeUnmount(() => chipObserver?.disconnect())
  return chipW
}

/** The draft's one-line width, measured in a hidden span with the field's font. */
function useDraftMeter() {
  let measureEl: HTMLSpanElement | null = null
  function draftWidth(el: HTMLTextAreaElement, value: string): number {
    if (typeof document === 'undefined') return 0
    if (!measureEl) {
      measureEl = document.createElement('span')
      measureEl.setAttribute('aria-hidden', 'true')
      measureEl.style.cssText = 'position:fixed;inset-inline-start:0;top:0;visibility:hidden;white-space:pre;pointer-events:none;'
      document.body.appendChild(measureEl)
    }
    const cs = getComputedStyle(el)
    measureEl.style.fontStyle = cs.fontStyle
    measureEl.style.fontWeight = cs.fontWeight
    measureEl.style.fontSize = cs.fontSize
    measureEl.style.fontFamily = cs.fontFamily
    measureEl.style.letterSpacing = cs.letterSpacing
    measureEl.style.wordSpacing = cs.wordSpacing
    measureEl.textContent = value
    return measureEl.getBoundingClientRect().width
  }
  onBeforeUnmount(() => {
    measureEl?.remove()
    measureEl = null
  })
  return draftWidth
}

/* SPL-1851: a text set by code (setText: a poll's "Chat about this") is
   not in the field yet, so this caret belongs to the old text; restoring
   it put the caret at 0, before the marker, and the reader typed there */
function keepCaret(inputEl: Ref<HTMLTextAreaElement | null>, el: HTMLTextAreaElement, value: string) {
  const start = el.selectionStart
  const endSel = el.selectionEnd
  const dir = el.selectionDirection
  const focused = document.activeElement === el
  const ownCaret = el.value === value
  void nextTick(() => {
    const box = inputEl.value
    if (!box) return
    if (focused && document.activeElement !== box) box.focus({ preventScroll: true })
    if (ownCaret && (box.selectionStart !== start || box.selectionEnd !== endSel)) {
      try { box.setSelectionRange(start, endSel, dir || 'none') } catch { /* the box was replaced */ }
    }
  })
}

/* t1 26282b6e: a new viewport width re-judges the wrap on the next frame; the
   text, focus, chip, glyph and dock watchers cover the rest. Not a
   ResizeObserver on the field: the top bar's tenant drop box sets its width
   inside its own ResizeObserver callback (TenantDropBox.vue, E14), which
   resizes this field in the same frame, and an observed field then raises
   "ResizeObserver loop completed with undelivered notifications". */
function onViewportWidth(props: ComposerProps, rejudge: () => void) {
  let widthFrame = 0
  function onResize() {
    if (widthFrame) return
    widthFrame = requestAnimationFrame(() => {
      widthFrame = 0
      rejudge()
    })
  }
  onMounted(() => {
    if (props.global) window.addEventListener('resize', onResize, { passive: true })
  })
  onBeforeUnmount(() => {
    window.removeEventListener('resize', onResize)
    if (widthFrame) cancelAnimationFrame(widthFrame)
  })
}

export function useComposerWrap(o: WrapOpts) {
  const { props } = o
  const multiline = ref(false)
  const multilineLayout = computed(() =>
    Boolean(props.global) && multiline.value && !o.parked.value && (Boolean(o.modeGlyph.value) || o.chip.value))
  const chipW = useChipWidth(o.chipEl, () => multilineLayout.value)
  const draftWidth = useDraftMeter()
  function oneLineContentWidth(el: HTMLTextAreaElement): number {
    const end = parseFloat(getComputedStyle(el).paddingInlineEnd) || 0
    const pad = omniboxOneLinePad({ glyph: Boolean(o.modeGlyph.value), chip: o.chip.value, chipWidth: chipW.value, phone: o.docked.value })
    return Math.max(0, el.clientWidth - end - pad)
  }
  function syncMultiline(): boolean {
    const el = o.inputEl.value
    if (!el || !props.global || typeof document === 'undefined') {
      if (multiline.value) { multiline.value = false; return true }
      return false
    }
    const value = o.text.value
    const next = omniboxIsMultiline({ text: value, textWidth: draftWidth(el, value), contentWidth: oneLineContentWidth(el) })
    if (next === multiline.value) return false
    keepCaret(o.inputEl, el, value)
    multiline.value = next
    return true
  }
  const rejudge = () => { if (props.global && syncMultiline()) void nextTick(() => o.fit()) }
  watch(chipW, rejudge)
  watch([o.modeGlyph, o.chip, o.docked], rejudge)
  onViewportWidth(props, rejudge)
  return { chipW, multilineLayout, syncMultiline }
}
