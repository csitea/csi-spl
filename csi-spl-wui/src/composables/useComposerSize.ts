// r13-03: the top-bar field's height - it grows with the text, the grip
// drags it, a blur parks it at one line - moved out of MessageComposer.vue.
//
// field-sizing is not enough inside the top-bar flex row: the used height
// stays one line. Measure the text and set the height. Only the field grows.
// The automatic size stops at 40% of the window; the grip can go to the
// bottom of the screen. The bar itself stays 58px (SPL-977).
import type { Ref } from 'vue'
import { omniboxFocusHeight, omniboxRememberHeight } from '~/utils/omnibox-size'
import { omniboxMaxHeight, resizeHeight, topButtonsBottom } from '~/utils/omnibox-dock.mjs'
import { useComposerWrap, type WrapOpts } from '~/composables/useComposerWrap'

interface SizeOpts extends Omit<WrapOpts, 'parked' | 'fit'> {
  kbInset: Ref<number>
  phoneShare: Ref<number | null>
}

function useBoxState() {
  return {
    /* A drag on the grip. Null until the reader sets one, then typing does not
       snap the box back. Kept across a collapse so the next focus can reopen it. */
    userHeight: ref<number | null>(null),
    /* Last open height when the reader did not drag. Null when it was one line. */
    openHeight: ref<number | null>(null),
    /* True after focus leaves, so a tall draft stays one line until the reader
       comes back. Ctrl+Enter does not park: the caret is still in the box. */
    parked: ref(false),
    /* Ctrl+Enter collapses while the caret stays. The next key sizes to the new
       text; the saved height waits for the next focus. */
    contentUntilFocus: ref(false),
    /* A fit queued by the send that clears the text must not reopen the box. */
    fit: { serial: 0 },
  }
}
type BoxState = ReturnType<typeof useBoxState>

function useFit(o: SizeOpts, st: BoxState) {
  const { props } = o
  function omniboxMax() {
    /* docked: 40% of what the keyboard leaves, so the page stays in view */
    if (o.docked.value) return Math.max(36, Math.floor((window.innerHeight - o.kbInset.value) * 0.4))
    /* topic c6994436: in the bottom dock the box pushes the feed up, not over;
       owner, t1 8de4c254: up to the middle pane's header row, the box's own
       rows around the field and the window under it taken off */
    const innerHeight = window.innerHeight - o.kbInset.value
    const el = o.inputEl.value
    const box = el?.closest('form')
    if (!o.props.bottom || !el || !box) return omniboxMaxHeight({ innerHeight, bottom: Boolean(o.props.bottom) })
    const r = box.getBoundingClientRect()
    const chrome = r.height - el.getBoundingClientRect().height + Math.max(0, innerHeight - r.bottom)
    return omniboxMaxHeight({ innerHeight, topBarH: topButtonsBottom(document, box), bottom: true, chrome })
  }
  function fitGlobalBox() {
    const el = o.inputEl.value
    if (!el || !props.global || st.parked.value) return
    if (!st.contentUntilFocus.value && st.userHeight.value != null) {
      const px = omniboxFocusHeight(st.userHeight.value, null, omniboxMax())
      if (px != null) {
        el.style.height = `${px}px`
        return
      }
    }
    /* owner, t1 d3bbe2c2: "I cannot see the last part of the msg WHERE AM I
       typing" / "something with the scroll resets it up" - the 'auto' measure
       drops the field's scroll to the top while a phone keyboard composes
       (measured: scrollTop 0, the caret 441 px under the box). Text that only
       grew needs no collapse; after one, the scroll goes back, and a caret at
       the end stays in view. */
    const cap = Math.min(omniboxMax(), Math.floor(window.innerHeight * 0.4))
    if (el.scrollHeight > el.clientHeight) {
      el.style.height = `${Math.min(el.scrollHeight, cap)}px`
    } else {
      const scrolled = el.scrollTop
      el.style.height = 'auto'
      el.style.height = `${Math.min(el.scrollHeight, cap)}px`
      el.scrollTop = scrolled
    }
    if (document.activeElement === el && el.selectionEnd === el.value.length) el.scrollTop = el.scrollHeight
  }
  return { omniboxMax, fitGlobalBox }
}

function useCollapse(o: SizeOpts, st: BoxState, fit: ReturnType<typeof useFit>, syncMultiline: () => boolean) {
  const { props } = o
  function collapseGlobalBox(park: boolean) {
    const el = o.inputEl.value
    if (!el || !props.global) return
    st.openHeight.value = omniboxRememberHeight({
      userHeight: st.userHeight.value,
      openHeight: st.openHeight.value,
      measured: Math.round(el.getBoundingClientRect().height),
      keep: st.parked.value || st.contentUntilFocus.value,
    })
    st.parked.value = park
    if (!park) {
      st.contentUntilFocus.value = true
      const serial = ++st.fit.serial
      void nextTick(() => {
        if (st.fit.serial === serial) st.fit.serial++
      })
    }
    el.style.height = '36px'
  }
  function onOmniboxFocus() {
    if (!props.global) return
    st.parked.value = false
    st.contentUntilFocus.value = false
    const changed = syncMultiline()
    const px = omniboxFocusHeight(st.userHeight.value, st.openHeight.value, fit.omniboxMax())
    const el = o.inputEl.value
    if (px != null && el && !changed) {
      el.style.height = `${px}px`
      return
    }
    void nextTick(fit.fitGlobalBox)
  }
  function onOmniboxBlur(ev: FocusEvent) {
    if (!props.global) return
    const next = ev.relatedTarget
    if (next instanceof Element && next.closest('[data-test="omnibox-resize"]')) return
    collapseGlobalBox(true)
  }
  return { collapseGlobalBox, onOmniboxFocus, onOmniboxBlur }
}

/* Attach and Send swallow their mousedown (@mousedown.prevent): the focus
   stays in the box, so the blur does not snap a tall draft to one line
   the moment the reader reaches for Attach (measured 126px -> 36px on the
   mock, 2026-09-25). The click itself fired either way in Chromium. */
function useResizeGrip(o: SizeOpts, st: BoxState, omniboxMax: () => number) {
  return function startResize(ev: PointerEvent) {
    const el = o.inputEl.value
    const handle = ev.currentTarget
    if (!el || !(handle instanceof HTMLElement)) return
    ev.preventDefault()
    handle.setPointerCapture(ev.pointerId)
    const startY = ev.clientY
    const startH = el.getBoundingClientRect().height
    const move = (e: PointerEvent) => {
      const next = resizeHeight({ startH, startY, y: e.clientY, bottom: Boolean(o.props.bottom) && !o.docked.value, max: omniboxMax() })
      st.userHeight.value = next
      el.style.height = `${next}px`
    }
    const end = () => {
      handle.removeEventListener('pointermove', move)
      handle.removeEventListener('pointerup', end)
      handle.removeEventListener('pointercancel', end)
    }
    handle.addEventListener('pointermove', move)
    handle.addEventListener('pointerup', end)
    handle.addEventListener('pointercancel', end)
  }
}

export function useComposerSize(o: SizeOpts) {
  const st = useBoxState()
  const fit = useFit(o, st)
  const wrap = useComposerWrap({ ...o, parked: st.parked, fit: fit.fitGlobalBox })
  const collapse = useCollapse(o, st, fit, wrap.syncMultiline)
  watch(o.text, () => {
    if (!o.props.global) return
    /* same flush as the new text, so the prefix row and the indent change
       together and the caret is not rebuilt */
    const changed = wrap.syncMultiline()
    const serial = st.fit.serial
    void nextTick(() => {
      if (serial !== st.fit.serial) return
      if (changed) wrap.syncMultiline()
      fit.fitGlobalBox()
    })
  })
  onMounted(() => {
    wrap.syncMultiline()
    fit.fitGlobalBox()
  })
  /* owner, t1 21:53Z: a new phone size (or a place with another size). The
     field's own height was measured under the old floor; measure it again
     under the new one, so a smaller size really shrinks it */
  watch(o.phoneShare, () => {
    void nextTick(() => {
      const el = o.inputEl.value
      if (!el || !o.docked.value) return
      if (st.parked.value) el.style.height = '36px'
      else fit.fitGlobalBox()
    })
  })
  return { ...collapse, ...wrap, startResize: useResizeGrip(o, st, fit.omniboxMax) }
}
