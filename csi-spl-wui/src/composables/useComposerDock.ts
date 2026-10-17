// r13-03: the composer's phone dock (SPL-991), moved out of MessageComposer.vue.
//
// The composer is the one TopBar mounts; on a phone it leaves the bar and
// pins itself to the bottom edge, `--kb-inset` above it (useKeyboardInset:
// the visualViewport keyboard height, iOS Safari and Android Chrome), full
// width, 44 px wide Back / Attach / Send (40 px tall, SPL-2093). Its height
// goes to `--composer-dock-h` on <html> (0 when not docked), so the panes pad
// their last card clear of it (M1) and TopBar lifts its send error over it
// (M2). SPL-1005: every level, the section chooser included.
import type { Ref } from 'vue'
import { useKeyboardInset, usePhone } from '~/composables/useTouchUi'
import { useStatusStripHeight } from '~/composables/useStatusStrip'
import { useMobileStack } from '~/composables/useMobileStack'
import { useOmniboxPhonePos } from '~/composables/useOmniboxPhonePos'
import { onOutsideTap } from '~/utils/outside-tap.mjs'
import type { ComposerProps } from '~/composables/composerProps'

interface DockOpts {
  props: ComposerProps
  formEl: Ref<HTMLFormElement | null>
  inputEl: Ref<HTMLTextAreaElement | null>
}

/* CLE-77888: the dock sits on the phone's bottom status strip, so the
   height it reports is the two together (the strip is 0 while it is gone) */
function useDockHeight(phonePos: Readonly<Ref<string>>) {
  const stripH = useStatusStripHeight()
  let dockPx = 0
  function setDockHeight(px: number) {
    dockPx = px
    if (typeof document === 'undefined') return
    /* at the top the box no longer covers the bottom: the panes pad only the
       strip there, and start under the box (--composer-dock-top-h, main.css) */
    const top = px > 0 && phonePos.value === 'top'
    const total = px > 0 ? px + stripH.value : 0
    const root = document.documentElement.style
    root.setProperty('--composer-dock-h', `${Math.max(0, Math.round(top ? stripH.value : total))}px`)
    root.setProperty('--composer-dock-top-h', `${top ? Math.round(px) : 0}px`)
  }
  watch(stripH, () => setDockHeight(dockPx))
  watch(phonePos, () => setDockHeight(dockPx))
  return setDockHeight
}

/* e3e9ca61 (owner, on a phone): "whenever I click somewhere else, the snack
   bar and the omnibar should disappear". Attach keeps the focus in the box
   (@mousedown.prevent), so after the picker the box is still open at 40% of
   the screen with the keyboard up. A tap outside the dock now blurs it, which
   collapses it (onOmniboxBlur) and drops the keyboard. Desktop: unchanged. */
function useDockOutsideBlur(docked: Ref<boolean>, { formEl, inputEl }: DockOpts) {
  let offDockOutside: (() => void) | null = null
  function onDockOutside() {
    const el = inputEl.value
    if (el && document.activeElement === el) el.blur()
  }
  watch(docked, (on) => {
    offDockOutside?.()
    offDockOutside = on && typeof document !== 'undefined' ? onOutsideTap(document, () => [formEl.value], onDockOutside) : null
  }, { immediate: true, flush: 'post' })
  onBeforeUnmount(() => { offDockOutside?.() })
}

export function useComposerDock(opts: DockOpts) {
  const { props } = opts
  const phone = usePhone()
  const kbInset = useKeyboardInset()
  const stack = useMobileStack()
  /* SPL-1005 (owner, topic 9b58a27b): the floating GO is gone, so the dock is
     the phone's only omnibox - it shows on EVERY level, the section chooser
     and pages with no send target included (there `/search` still works and
     plain text says it cannot be sent) */
  const docked = computed(() => Boolean(props.global) && props.dock && phone.value)
  /* owner, t1 2026-10-02: the dock's place on the phone (its grip moves it) */
  const { pos: phonePos, size: phoneSize } = useOmniboxPhonePos()
  /* owner, t1 21:53Z: its size there (the grip's size handle or the menu) */
  const phoneShare = computed(() => phoneSize.value[phonePos.value] ?? null)
  const setDockHeight = useDockHeight(phonePos)
  let dockObserver: ResizeObserver | null = null
  function watchDock(on: boolean) {
    dockObserver?.disconnect()
    dockObserver = null
    const el = opts.formEl.value
    if (!on || !el) {
      setDockHeight(0)
      return
    }
    setDockHeight(el.getBoundingClientRect().height)
    if (typeof ResizeObserver !== 'undefined') {
      dockObserver = new ResizeObserver(() => setDockHeight(el.getBoundingClientRect().height))
      dockObserver.observe(el)
    }
  }
  watch(docked, (on) => { void nextTick(() => watchDock(on)) })
  onMounted(() => watchDock(docked.value))
  onBeforeUnmount(() => {
    dockObserver?.disconnect()
    if (props.global) setDockHeight(0)
  })
  useDockOutsideBlur(docked, opts)
  return { docked, phonePos, phoneShare, kbInset, stack }
}
