// r21-05: the omnibox grip's size handle, moved out of OmniboxGrip.vue.
//
// The place and the size come from useOmniboxPhonePos (one shared ref for the
// tab), so the grip's drag code and this handle read the same state. sizeEl
// stays declared in the grip: the template binds it and the outside-tap list
// reads it. The box is a getter so a changed prop is read on the next press.
import type { Ref } from 'vue'
import { HEIGHT_MAX, isPhoneDrag, resizePhoneSize } from '~/utils/omnibox-dock.mjs'
import { useOmniboxPhonePos } from '~/composables/useOmniboxPhonePos'

interface GripSizeOpts {
  box: () => HTMLElement | null
  sizeEl: Ref<HTMLButtonElement | null>
  menuOpen: Ref<boolean>
}

export function useOmniboxGripSize(o: GripSizeOpts) {
  const { sizeEl, menuOpen } = o
  const { pos, size, setSize } = useOmniboxPhonePos()

  /* the size handle: the field's height (bottom, top) or the box's width (right) */
  let sizing: { x: number, y: number, id: number, start: number, room: number, max: number, moved: boolean } | null = null
  let swallowSizeClick = false

  /** What a share is of: the px under the top bar above the keyboard, or the screen width. */
  function sizeRoom(): number {
    if (pos.value === 'right') return window.innerWidth
    const kb = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--kb-inset')) || 0
    const bar = document.querySelector('[data-test=top-bar]')?.getBoundingClientRect().bottom ?? 0
    return window.innerHeight - kb - bar
  }

  /** The largest height share: up to the top button section where the dock
      measured it (owner, t1 8de4c254: --dock-field-max), else half. */
  function sizeMax(room: number): number {
    const px = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--dock-field-max'))
    return pos.value === 'bottom' && px > 0 && room > 0 ? px / room : HEIGHT_MAX
  }

  function onSizeMove(e: PointerEvent) {
    if (!sizing || e.pointerId !== sizing.id) return
    const dx = e.clientX - sizing.x
    const dy = e.clientY - sizing.y
    if (!sizing.moved && !isPhoneDrag({ dx, dy })) return
    sizing.moved = true
    menuOpen.value = false
    setSize(resizePhoneSize({ pos: pos.value, start: sizing.start, dx, dy, room: sizing.room, max: sizing.max }), false)
  }

  function onSizeUp(e: PointerEvent) {
    if (!sizing || e.pointerId !== sizing.id) return
    const moved = sizing.moved
    detachSize()
    if (!moved) return
    swallowSizeClick = true
    /* the last live value, now kept */
    setSize(size.value[pos.value] ?? null)
  }

  /* one controller per resize: abort() removes the resize's three listeners */
  let sizeListeners: AbortController | null = null

  function detachSize() {
    sizing = null
    sizeListeners?.abort()
    sizeListeners = null
  }

  function onSizeDown(e: PointerEvent) {
    const box = o.box()
    if (e.button !== 0 || !sizeEl.value || !box) return
    const field = box.querySelector('textarea')
    const start = pos.value === 'right' ? box.getBoundingClientRect().width : (field?.getBoundingClientRect().height ?? 44)
    const room = sizeRoom()
    sizing = { x: e.clientX, y: e.clientY, id: e.pointerId, start, room, max: sizeMax(room), moved: false }
    swallowSizeClick = false
    try { sizeEl.value.setPointerCapture(e.pointerId) } catch { /* a synthetic event has no capture */ }
    sizeListeners?.abort()
    sizeListeners = new AbortController()
    const { signal } = sizeListeners
    sizeEl.value.addEventListener('pointermove', onSizeMove, { signal })
    sizeEl.value.addEventListener('pointerup', onSizeUp, { signal })
    sizeEl.value.addEventListener('pointercancel', detachSize, { signal })
  }

  function onSizeClick() {
    if (swallowSizeClick) {
      swallowSizeClick = false
      return
    }
    menuOpen.value = !menuOpen.value
  }

  return { onSizeDown, onSizeClick, detachSize }
}
