<!-- Owner, t1 (2026-10-02 21:28Z): "Add handle to the omnibox on mobile to
     be able to drag to the top of the screen and to the right". The grip on
     the phone dock's free edge. Only the grip starts a drag (touch-action
     none here, nowhere else), so a swipe on the page still scrolls it. The
     box follows the finger and snaps on release (utils/omnibox-dock.mjs
     snapPhonePosition). A tap, Enter or Space opens the menu instead: Move to
     top / right / bottom, for anyone who cannot drag. -->
<template>
  <div class="omni-grip" :data-pos="pos">
    <button
      ref="btnEl"
      type="button"
      class="omni-grip__btn"
      data-testid="omnibox-grip"
      :aria-label="t('composer.move_handle')"
      :title="t('composer.move_handle')"
      aria-haspopup="menu"
      :aria-expanded="menuOpen ? 'true' : 'false'"
      @mousedown.prevent
      @pointerdown="onDown"
      @click="onClick"
    ><span class="omni-grip__bar" aria-hidden="true" /></button>
    <div
      v-if="menuOpen"
      ref="menuEl"
      role="menu"
      class="omni-grip__menu"
      data-testid="omnibox-grip-menu"
      :aria-label="t('composer.move_menu')"
      @keydown="onMenuKey"
    >
      <button
        v-for="p in PHONE_POSITIONS"
        :key="p"
        type="button"
        role="menuitemradio"
        class="omni-grip__item"
        :data-pos="p"
        :aria-checked="pos === p ? 'true' : 'false'"
        @mousedown.prevent
        @click="pick(p)"
      >{{ t(`composer.move_${p}`) }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { PHONE_POSITIONS, isPhoneDrag, snapPhonePosition } from '~/utils/omnibox-dock.mjs'
import { onOutsideTap } from '~/utils/outside-tap.mjs'
import { useOmniboxPhonePos } from '~/composables/useOmniboxPhonePos'

type PhonePosition = 'bottom' | 'top' | 'right'

/** The docked form that moves with the finger. */
const props = defineProps<{ box: HTMLElement | null }>()

const { t } = useI18n({ useScope: 'global' })
const { pos, set } = useOmniboxPhonePos()
const btnEl = ref<HTMLButtonElement | null>(null)
const menuEl = ref<HTMLElement | null>(null)
const menuOpen = ref(false)

let start: { x: number, y: number, id: number } | null = null
let dragging = false
/* the click a finished drag fires must not open the menu */
let swallowClick = false

function clearDrag() {
  const box = props.box
  if (box) {
    box.style.transform = ''
    delete box.dataset.dragging
  }
  start = null
  dragging = false
}

function onMove(e: PointerEvent) {
  if (!start || e.pointerId !== start.id) return
  const dx = e.clientX - start.x
  const dy = e.clientY - start.y
  if (!dragging && !isPhoneDrag({ dx, dy })) return
  dragging = true
  menuOpen.value = false
  const box = props.box
  if (box) {
    box.dataset.dragging = 'true'
    box.style.transform = `translate(${Math.round(dx)}px, ${Math.round(dy)}px)`
  }
}

function onUp(e: PointerEvent) {
  if (!start || e.pointerId !== start.id) return
  const moved = dragging
  detach()
  clearDrag()
  if (!moved) return
  swallowClick = true
  set(snapPhonePosition({ x: e.clientX, y: e.clientY, width: window.innerWidth, height: window.innerHeight }))
}

function onCancel() {
  detach()
  clearDrag()
}

function detach() {
  const b = btnEl.value
  if (!b) return
  b.removeEventListener('pointermove', onMove)
  b.removeEventListener('pointerup', onUp)
  b.removeEventListener('pointercancel', onCancel)
}

function onDown(e: PointerEvent) {
  if (e.button !== 0 || !btnEl.value) return
  start = { x: e.clientX, y: e.clientY, id: e.pointerId }
  dragging = false
  swallowClick = false
  try { btnEl.value.setPointerCapture(e.pointerId) } catch { /* a synthetic event has no capture */ }
  btnEl.value.addEventListener('pointermove', onMove)
  btnEl.value.addEventListener('pointerup', onUp)
  btnEl.value.addEventListener('pointercancel', onCancel)
}

function onClick(e: MouseEvent) {
  if (swallowClick) {
    swallowClick = false
    return
  }
  menuOpen.value = !menuOpen.value
  /* from the keyboard (detail 0) the caret goes to the current place */
  if (menuOpen.value && e.detail === 0) void nextTick(() => focusItem(PHONE_POSITIONS.indexOf(pos.value)))
}

function items(): HTMLButtonElement[] {
  return [...(menuEl.value?.querySelectorAll<HTMLButtonElement>('.omni-grip__item') || [])]
}

function focusItem(i: number) {
  const all = items()
  if (!all.length) return
  all[(i + all.length) % all.length]?.focus()
}

function onMenuKey(e: KeyboardEvent) {
  const all = items()
  const at = all.indexOf(document.activeElement as HTMLButtonElement)
  if (e.key === 'Escape') {
    e.preventDefault()
    e.stopPropagation()
    menuOpen.value = false
    btnEl.value?.focus()
  } else if (e.key === 'ArrowDown') {
    e.preventDefault()
    focusItem(at + 1)
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    focusItem(at - 1)
  }
}

function pick(p: PhonePosition) {
  set(p)
  menuOpen.value = false
}

let offOutside: (() => void) | null = null
watch(menuOpen, (open) => {
  offOutside?.()
  offOutside = open ? onOutsideTap(document, () => [menuEl.value, btnEl.value], () => { menuOpen.value = false }) : null
})
onBeforeUnmount(() => {
  offOutside?.()
  detach()
  clearDrag()
})
</script>

<style scoped>
/* A 48 x 24 target straddling the box's free edge (the top edge at the
   bottom and in the corner, the bottom edge at the top); the drawn pill is
   the bottom-sheet grabber everyone knows */
.omni-grip {
  position: absolute;
  inset-inline: 0;
  top: -14px;
  height: 24px;
  display: flex;
  justify-content: center;
  pointer-events: none;
  z-index: 2;
}
.omni-grip[data-pos=top] { top: auto; bottom: -14px; }
.omni-grip__btn {
  pointer-events: auto;
  display: inline-grid;
  place-items: center;
  width: 48px;
  height: 24px;
  padding: 0;
  border: 0;
  background: transparent;
  cursor: grab;
  /* the grip, and only the grip, takes the finger from the page */
  touch-action: none;
}
.omni-grip__btn:active { cursor: grabbing; }
.omni-grip__bar {
  display: block;
  width: 36px;
  height: 5px;
  border-radius: var(--radius-pill);
  background: var(--color-muted);
  box-shadow: 0 0 0 1px var(--color-sidebar);
}
.omni-grip__menu {
  pointer-events: auto;
  position: absolute;
  bottom: calc(100% + 4px);
  display: flex;
  flex-direction: column;
  min-width: 12rem;
  padding: 4px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 8px);
  background: var(--color-surface);
  box-shadow: var(--focus-3d);
}
.omni-grip[data-pos=top] .omni-grip__menu { bottom: auto; top: calc(100% + 4px); }
.omni-grip__item {
  min-height: var(--tap, 44px);
  padding: 0 12px;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-fg);
  text-align: start;
  font: inherit;
  cursor: pointer;
}
.omni-grip__item[aria-checked=true] { font-weight: 600; color: var(--color-accent); }
.omni-grip__item:hover { background: color-mix(in srgb, var(--color-fg) 8%, transparent); }
</style>
