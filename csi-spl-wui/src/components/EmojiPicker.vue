<!-- The glyph grid for adding an emoji to a message. Same panel for an
     opening message and a reply. Escape and a click outside close it.
     SPL-991: at <= 820 px it is a bottom sheet with 44 px glyphs.
     SPL-1002: one grid, every glyph once and in a fixed place (the old
     Recent row showed the glyphs a second time), and every row full. -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="emoji-picker"
      :class="{ 'touch-sheet': sheet }"
      data-testid="emoji-picker"
      role="dialog"
      :aria-label="t('feed.emoji.picker')"
      @keydown="onKey"
      @contextmenu.prevent
    >
      <div class="emoji-picker__grid" data-testid="emoji-grid">
        <button
          v-for="emoji in choices"
          :key="emoji"
          type="button"
          class="emoji-picker__glyph"
          :data-emoji="emoji"
          :title="nameOf(emoji)"
          :aria-label="nameOf(emoji)"
          @click.stop="choose(emoji)"
          @touchstart.passive="onHoldStart(emoji)"
          @touchend="onHoldEnd"
          @touchmove.passive="onHoldCancel"
          @touchcancel.passive="onHoldCancel"
        >{{ emoji }}</button>
      </div>
      <!-- da0c0e98: on touch there is no hover, so a long-press names the glyph
           (title/aria-label serve the mouse and the screen reader). -->
      <div v-if="held" class="emoji-picker__name" data-testid="emoji-name" aria-hidden="true">{{ held }}</div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { EMOJI_CHOICES, emojiName } from '~/utils/emoji.mjs'
import { applyPopoverAtPoint, focusWithoutScroll } from '~/utils/place-popover.mjs'
import { usePhone } from '~/composables/useTouchUi'

const props = defineProps<{ open: boolean, x: number, y: number }>()
const emit = defineEmits<{ close: [], choose: [emoji: string] }>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const choices = EMOJI_CHOICES
const sheet = usePhone()

/** The short, plain name of a glyph, for the tooltip and the screen reader. */
function nameOf(emoji: string): string {
  return emojiName(emoji, t)
}

/* Long-press to read a glyph's name on touch (no hover there). The press
   names it; the ensuing click still adds the reaction, so reading a name and
   picking it are the same gesture held a little longer. */
const held = ref('')
let holdTimer: ReturnType<typeof setTimeout> | null = null
function clearHold() {
  if (holdTimer) { clearTimeout(holdTimer); holdTimer = null }
}
function onHoldStart(emoji: string) {
  clearHold()
  holdTimer = setTimeout(() => { held.value = nameOf(emoji) }, 350)
}
function onHoldEnd() {
  clearHold()
  /* keep the name up a breath after the finger lifts, then clear it */
  if (held.value) setTimeout(() => { held.value = '' }, 900)
}
function onHoldCancel() {
  clearHold()
  held.value = ''
}
/* SPL-994: on a phone the sheet is the top level while open - Back closes it first */
useMobileStack().overlay(() => props.open, () => emit('close'))

function glyphs(): HTMLElement[] {
  return [...(root.value?.querySelectorAll<HTMLElement>('.emoji-picker__glyph') ?? [])]
}

async function place() {
  await nextTick()
  if (sheet.value) return
  applyPopoverAtPoint(root.value, props.x, props.y)
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node) || root.value?.contains(target)) return
  if (target instanceof Element && target.closest('[data-testid="msg-emoji-btn"], .touch-sheet-backdrop')) return
  emit('close')
}

async function onOpenChange(v: boolean) {
  if (v) {
    document.addEventListener('pointerdown', onDocPointer, true)
    await place()
    if (!props.open || sheet.value) return
    await nextTick()
    focusWithoutScroll(glyphs()[0])
  } else {
    document.removeEventListener('pointerdown', onDocPointer, true)
  }
}
/* the card mounts this picker only while it is open (CLE-35075), so the
   opening is usually the mount itself, not a change of `open` */
watch(() => props.open, onOpenChange)
onMounted(() => { if (props.open) void onOpenChange(true) })
onBeforeUnmount(() => { document.removeEventListener('pointerdown', onDocPointer, true); clearHold() })

function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape') {
    e.preventDefault()
    e.stopPropagation()
    emit('close')
    return
  }
  const items = glyphs()
  const n = items.length
  if (!n) return
  const i = items.findIndex((el) => el === document.activeElement)
  const grid = root.value?.querySelector('.emoji-picker__grid')
  const cols = grid ? getComputedStyle(grid).gridTemplateColumns.split(' ').filter(Boolean).length || 8 : 8
  let next = i < 0 ? 0 : i
  if (e.key === 'ArrowRight') next = (next + 1) % n
  else if (e.key === 'ArrowLeft') next = (next - 1 + n) % n
  else if (e.key === 'ArrowDown') next = Math.min(n - 1, next + cols)
  else if (e.key === 'ArrowUp') next = Math.max(0, next - cols)
  else if (e.key === 'Home') next = 0
  else if (e.key === 'End') next = n - 1
  else return
  e.preventDefault()
  focusWithoutScroll(items[next])
}

function choose(emoji: string) {
  emit('choose', emoji)
  emit('close')
}
</script>

<style scoped>
.emoji-picker {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  z-index: var(--z-overlay);
  width: min(18.5rem, calc(100vw - 16px));
  max-height: min(22rem, calc(100vh - 16px));
  overflow: auto;
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 6px;
}
.emoji-picker__grid {
  display: grid;
  grid-template-columns: repeat(8, minmax(0, 1fr));
  gap: 2px;
}
.emoji-picker__glyph {
  appearance: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 100%;
  aspect-ratio: 1;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  font: inherit;
  font-size: 1.25rem;
  line-height: 1;
  cursor: pointer;
  padding: 0;
}
/* SPL-1002: 6, 12 or 16 columns, each a divisor of the 48 glyphs, so the
   last row is full; every column stays >= the 44 px tap target */
.touch-sheet .emoji-picker__grid { grid-template-columns: repeat(6, minmax(var(--tap), 1fr)); }
@media (min-width: 600px) { .touch-sheet .emoji-picker__grid { grid-template-columns: repeat(12, minmax(var(--tap), 1fr)); } }
@media (min-width: 760px) { .touch-sheet .emoji-picker__grid { grid-template-columns: repeat(16, minmax(var(--tap), 1fr)); } }
.touch-sheet .emoji-picker__glyph { min-height: var(--tap); font-size: 1.5rem; }
.emoji-picker__glyph:hover,
.emoji-picker__glyph:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
/* da0c0e98: the long-press name on touch. A sticky footer strip inside the
   sheet, so it never spills past the picker or covers the finger's glyph. */
.emoji-picker__name {
  position: sticky;
  bottom: 0;
  margin-top: 4px;
  padding: 6px 8px;
  text-align: center;
  font-size: .9rem;
  font-weight: 600;
  color: var(--color-text);
  background: var(--color-bg-2, var(--color-surface));
  border-top: 1px solid var(--color-border-strong, var(--color-border));
}
</style>
