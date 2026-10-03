<!-- Owner, t1 (2026-10-02 21:28Z): "Add handle to the omnibox on mobile to
     be able to drag to the top of the screen and to the right". The grip on
     the phone dock's free edge. Only the grip starts a drag (touch-action
     none here, nowhere else), so a swipe on the page still scrolls it. The
     box follows the finger and snaps on release (utils/omnibox-dock.mjs
     snapPhonePosition). A tap, Enter or Space opens the menu instead: Move to
     top / right / bottom, for anyone who cannot drag.
     Owner, t1 21:53Z: "it should be possible to resize it". A second handle
     on the free edge's END (the left edge in the corner) drags the size:
     the field's height at the bottom and the top, the box's width in the
     corner (utils/omnibox-dock.mjs resizePhoneSize); a tap on it opens the
     same menu, which also carries Small / Medium / Large. -->
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
      <div role="separator" class="omni-grip__sep" />
      <button
        v-for="z in SIZE_PRESETS"
        :key="z"
        type="button"
        role="menuitemradio"
        class="omni-grip__item"
        :data-size="z"
        :aria-checked="currentPreset === z ? 'true' : 'false'"
        @mousedown.prevent
        @click="pickSize(z)"
      >{{ t(`composer.size_${z}`) }}</button>
    </div>
  </div>
  <button
    ref="sizeEl"
    type="button"
    class="omni-size"
    :data-pos="pos"
    data-testid="omnibox-size"
    tabindex="-1"
    :aria-label="t('composer.size_handle')"
    :title="t('composer.size_handle')"
    @mousedown.prevent
    @pointerdown="onSizeDown"
    @click="onSizeClick"
  >
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M8 1.5 4.5 5h7L8 1.5Zm0 13L4.5 11h7L8 14.5Z" fill="currentColor" /></svg>
  </button>
</template>

<script setup lang="ts">
import { PHONE_POSITIONS, SIZE_PRESETS, isPhoneDrag, presetSize, resizePhoneSize, sizePreset, snapPhonePosition } from '~/utils/omnibox-dock.mjs'
import { onOutsideTap } from '~/utils/outside-tap.mjs'
import { useOmniboxPhonePos } from '~/composables/useOmniboxPhonePos'

type PhonePosition = 'bottom' | 'top' | 'right'
type SizePreset = 'small' | 'medium' | 'large'

/** The docked form that moves with the finger. */
const props = defineProps<{ box: HTMLElement | null }>()

const { t } = useI18n({ useScope: 'global' })
const { pos, size, set, setSize } = useOmniboxPhonePos()
const btnEl = ref<HTMLButtonElement | null>(null)
const sizeEl = ref<HTMLButtonElement | null>(null)
const currentPreset = computed(() => sizePreset(pos.value, size.value[pos.value]))
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

function pickSize(z: SizePreset) {
  setSize(presetSize(pos.value, z))
  menuOpen.value = false
}

/* the size handle: the field's height (bottom, top) or the box's width (right) */
let sizing: { x: number, y: number, id: number, start: number, room: number, moved: boolean } | null = null
let swallowSizeClick = false

/** What a share is of: the px under the top bar above the keyboard, or the screen width. */
function sizeRoom(): number {
  if (pos.value === 'right') return window.innerWidth
  const kb = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--kb-inset')) || 0
  const bar = document.querySelector('[data-test=top-bar]')?.getBoundingClientRect().bottom ?? 0
  return window.innerHeight - kb - bar
}

function onSizeMove(e: PointerEvent) {
  if (!sizing || e.pointerId !== sizing.id) return
  const dx = e.clientX - sizing.x
  const dy = e.clientY - sizing.y
  if (!sizing.moved && !isPhoneDrag({ dx, dy })) return
  sizing.moved = true
  menuOpen.value = false
  setSize(resizePhoneSize({ pos: pos.value, start: sizing.start, dx, dy, room: sizing.room }), false)
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

function detachSize() {
  sizing = null
  const b = sizeEl.value
  if (!b) return
  b.removeEventListener('pointermove', onSizeMove)
  b.removeEventListener('pointerup', onSizeUp)
  b.removeEventListener('pointercancel', detachSize)
}

function onSizeDown(e: PointerEvent) {
  const box = props.box
  if (e.button !== 0 || !sizeEl.value || !box) return
  const field = box.querySelector('textarea')
  const start = pos.value === 'right' ? box.getBoundingClientRect().width : (field?.getBoundingClientRect().height ?? 44)
  sizing = { x: e.clientX, y: e.clientY, id: e.pointerId, start, room: sizeRoom(), moved: false }
  swallowSizeClick = false
  try { sizeEl.value.setPointerCapture(e.pointerId) } catch { /* a synthetic event has no capture */ }
  sizeEl.value.addEventListener('pointermove', onSizeMove)
  sizeEl.value.addEventListener('pointerup', onSizeUp)
  sizeEl.value.addEventListener('pointercancel', detachSize)
}

function onSizeClick() {
  if (swallowSizeClick) {
    swallowSizeClick = false
    return
  }
  menuOpen.value = !menuOpen.value
}

let offOutside: (() => void) | null = null
watch(menuOpen, (open) => {
  offOutside?.()
  offOutside = open ? onOutsideTap(document, () => [menuEl.value, btnEl.value, sizeEl.value], () => { menuOpen.value = false }) : null
})
onBeforeUnmount(() => {
  offOutside?.()
  detach()
  detachSize()
  clearDrag()
})
</script>

<style scoped>
/* A 48 x 24 target straddling the box's free edge (the top edge at the
   bottom and in the corner, the bottom edge at the top), 16 px outside and
   8 px inside, so it ends in the dock's 6 px padding + the field's border
   (the dock keeps its <= 8 px edge, composer-mode-cue.test.mjs 390 6); the
   drawn pill is the bottom-sheet grabber everyone knows */
.omni-grip {
  position: absolute;
  inset-inline: 0;
  top: -16px;
  height: 24px;
  display: flex;
  justify-content: center;
  pointer-events: none;
  z-index: 2;
}
.omni-grip[data-pos=top] { top: auto; bottom: -16px; }
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
.omni-grip__sep { height: 1px; margin: 4px 0; background: var(--color-border); }
/* The size handle: a 44 x 24 target at the free edge's physical right end
   (the thumb's side; the grip keeps the middle), on the LEFT edge in the
   corner where the width is what changes - there it turns sideways */
.omni-size {
  position: absolute;
  z-index: 2;
  top: -16px;
  right: 8px;
  display: inline-grid;
  place-items: center;
  width: 44px;
  height: 24px;
  padding: 0;
  border: 0;
  background: transparent;
  color: var(--color-muted);
  cursor: ns-resize;
  /* like the grip: this handle, and only it, takes the finger */
  touch-action: none;
}
.omni-size svg { filter: drop-shadow(0 0 1px var(--color-sidebar)); }
.omni-size[data-pos=top] { top: auto; bottom: -16px; }
/* owner, t1 03128097 (2026-10-03): "The two small arrows to resize this (the
   size of the Omni boxes' bottom bar) ... should be put on the left side on
   mobile": at the bottom the handle is the free edge's LEFT end. The top
   and the corner keep theirs; the grip is phone-only, so a desktop has none. */
.omni-size[data-pos=bottom] { right: auto; left: 8px; }
.omni-size[data-pos=right] {
  top: 50%;
  right: auto;
  left: -16px;
  width: 24px;
  height: 44px;
  margin-top: -22px;
  cursor: ew-resize;
}
.omni-size[data-pos=right] svg { transform: rotate(90deg); }
</style>
