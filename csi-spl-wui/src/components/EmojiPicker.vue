<!-- The glyph grid for adding an emoji to a message. Same panel for an
     opening message and a reply. Escape and a click outside close it. -->
<template>
  <Teleport to="body">
    <div
      v-if="open"
      ref="root"
      class="emoji-picker"
      data-testid="emoji-picker"
      role="dialog"
      :aria-label="t('feed.emoji.picker')"
      @keydown="onKey"
      @contextmenu.prevent
    >
      <p v-if="recent.length" class="emoji-picker__label">{{ t('feed.emoji.recent') }}</p>
      <div v-if="recent.length" class="emoji-picker__grid" data-testid="emoji-recent">
        <button
          v-for="emoji in recent"
          :key="'r-' + emoji"
          type="button"
          class="emoji-picker__glyph"
          :data-emoji="emoji"
          :aria-label="emoji"
          @click.stop="choose(emoji)"
        >{{ emoji }}</button>
      </div>
      <div class="emoji-picker__grid" data-testid="emoji-grid">
        <button
          v-for="emoji in choices"
          :key="emoji"
          type="button"
          class="emoji-picker__glyph"
          :data-emoji="emoji"
          :aria-label="emoji"
          @click.stop="choose(emoji)"
        >{{ emoji }}</button>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { EMOJI_CHOICES, readRecent, rememberEmoji } from '~/utils/emoji.mjs'
import { applyPopoverAtPoint, focusWithoutScroll } from '~/utils/place-popover.mjs'

const props = defineProps<{ open: boolean, x: number, y: number }>()
const emit = defineEmits<{ close: [], choose: [emoji: string] }>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const recent = ref<string[]>([])
const choices = EMOJI_CHOICES

function glyphs(): HTMLElement[] {
  return [...(root.value?.querySelectorAll<HTMLElement>('.emoji-picker__glyph') ?? [])]
}

async function place() {
  await nextTick()
  applyPopoverAtPoint(root.value, props.x, props.y)
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node) || root.value?.contains(target)) return
  if (target instanceof Element && target.closest('[data-testid="msg-emoji-btn"]')) return
  emit('close')
}

watch(() => props.open, async (v) => {
  if (v) {
    recent.value = readRecent()
    document.addEventListener('pointerdown', onDocPointer, true)
    await place()
    if (!props.open) return
    await nextTick()
    focusWithoutScroll(glyphs()[0])
  } else {
    document.removeEventListener('pointerdown', onDocPointer, true)
  }
})
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer, true))

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
  const cols = 8
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
  recent.value = rememberEmoji(emoji)
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
.emoji-picker__label {
  margin: 2px 6px 0;
  color: var(--color-muted);
  font-size: 0.75rem;
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
.emoji-picker__glyph:hover,
.emoji-picker__glyph:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
</style>
