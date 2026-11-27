// r13-03: is the top-bar draft more than one line? Moved out of
// MessageComposer.vue; useComposerSize calls it.
//
// Owner, t1 26282b6e: more than one line lifts the glyph and the chip onto
// a row above the text. The answer is the one-line content box (the indent
// below), so it does not flip again when that indent is removed. A blur
// parks the bar at one line; the row comes back with the caret.
import type { Ref } from 'vue'
import { omniboxIsMultiline, omniboxOneLinePad } from '~/utils/omnibox-size'
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

/** The field's font as the old hidden span took it: a canvas font and its spacings in px. */
export interface MeterFont { font: string, letter: number, word: number }

export function meterFont(cs: CSSStyleDeclaration): MeterFont {
  return {
    font: `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`,
    letter: parseFloat(cs.letterSpacing) || 0,
    word: parseFloat(cs.wordSpacing) || 0,
  }
}

/* the span (white-space: pre) added the letter spacing after every
   character and the word spacing at every space; the canvas adds neither */
export function meterWidth(ctx: CanvasRenderingContext2D, f: MeterFont, value: string): number {
  /* the canvas keeps the font in its own form ("normal 400" dropped): keep
     that form, so the next key does not parse the same font again */
  if (ctx.font !== f.font) { ctx.font = f.font; f.font = ctx.font }
  let w = ctx.measureText(value).width
  if (f.letter) w += f.letter * Array.from(value).length
  if (f.word) w += f.word * (value.match(/[ \u00a0]/g)?.length ?? 0)
  return w
}

/* p19-02 (SPL-6654): the draft's one-line width from a canvas measureText.
   The hidden span it replaces was styled and read with getBoundingClientRect
   on every key: one forced layout per key (plan perf-round-19 row 02). The
   font is read once per focus and again on a re-judge (chip, glyph, dock,
   viewport width, the field's class, the font-size setting: where the
   field's font can change). */
function useDraftMeter(props: ComposerProps) {
  let ctx: CanvasRenderingContext2D | null = null
  let font: MeterFont | null = null
  const forget = () => { font = null }
  function draftWidth(el: HTMLTextAreaElement, value: string): number {
    if (typeof document === 'undefined') return 0
    ctx ??= document.createElement('canvas').getContext('2d')
    if (!ctx) return 0
    font ??= meterFont(getComputedStyle(el))
    return meterWidth(ctx, font, value)
  }
  /* capture: before the field's own focus handler judges the wrap */
  onMounted(() => {
    if (props.global) window.addEventListener('focus', forget, true)
  })
  onBeforeUnmount(() => {
    window.removeEventListener('focus', forget, true)
    ctx = null
  })
  return { draftWidth, forget }
}

/* a font change with no focus, chip or viewport change: `.in-code` (a code
   fence typed in the focused field: monospace, smaller) and the font-size
   setting (html data-font-size; the phone dock has no chip to re-judge on).
   Attribute observers: no layout read until one of them changes. */
function onFontChange(props: ComposerProps, inputEl: Ref<HTMLTextAreaElement | null>, rejudge: () => void) {
  let fieldObs: MutationObserver | null = null
  let rootObs: MutationObserver | null = null
  const observable = () => props.global && typeof MutationObserver === 'function'
  watch(inputEl, (el) => {
    fieldObs?.disconnect()
    fieldObs = null
    if (!el || !observable()) return
    fieldObs = new MutationObserver(rejudge)
    fieldObs.observe(el, { attributes: true, attributeFilter: ['class'] })
  }, { immediate: true })
  onMounted(() => {
    if (!observable()) return
    rootObs = new MutationObserver(rejudge)
    rootObs.observe(document.documentElement, { attributes: true, attributeFilter: ['data-font-size'] })
  })
  onBeforeUnmount(() => {
    fieldObs?.disconnect()
    rootObs?.disconnect()
  })
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
  const meter = useDraftMeter(props)
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
    const next = omniboxIsMultiline({ text: value, textWidth: meter.draftWidth(el, value), contentWidth: oneLineContentWidth(el) })
    if (next === multiline.value) return false
    keepCaret(o.inputEl, el, value)
    multiline.value = next
    return true
  }
  const rejudge = () => {
    meter.forget()
    if (props.global && syncMultiline()) void nextTick(() => o.fit())
  }
  watch(chipW, rejudge)
  watch([o.modeGlyph, o.chip, o.docked], rejudge)
  onViewportWidth(props, rejudge)
  onFontChange(props, o.inputEl, rejudge)
  return { chipW, multilineLayout, syncMultiline }
}
