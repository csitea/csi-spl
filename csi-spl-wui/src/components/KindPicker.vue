<!-- SPL-952: the menu that sets a message's kind, opened from its badge. The
     same panel behaviour as EmojiPicker: teleported, placed inside the
     viewport, Escape and a click outside close it, arrows move the focus.
     SPL-991: at <= 820 px it is a bottom sheet, as the message menu is. -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="kind-picker"
      :class="{ 'touch-sheet': sheet }"
      data-testid="kind-picker"
      role="menu"
      :aria-label="t('feed.kind_set.menu')"
      @keydown="onKey"
      @contextmenu.prevent
    >
      <button
        v-for="k in MSG_KINDS"
        :key="k"
        type="button"
        role="menuitemradio"
        class="kind-picker__item"
        :aria-checked="k === current ? 'true' : 'false'"
        :data-kind="k"
        @click.stop="choose(k)"
      >
        <KindBadge :kind="k" />
        <span>{{ t('feed.kind.' + k) }}</span>
      </button>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { MSG_KINDS } from '~/utils/msg-kind.mjs'
import { applyPopoverAtPoint, focusWithoutScroll } from '~/utils/place-popover.mjs'
import { usePhone } from '~/composables/useTouchUi'

const props = defineProps<{ open: boolean, x: number, y: number, current: string }>()
const emit = defineEmits<{ close: [], choose: [kind: string] }>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const sheet = usePhone()
/* SPL-994: on a phone the sheet is the top level while open - Back closes it first */
useMobileStack().overlay(() => props.open, () => emit('close'))

function items(): HTMLElement[] {
  return [...(root.value?.querySelectorAll<HTMLElement>('.kind-picker__item') ?? [])]
}

async function place() {
  await nextTick()
  if (sheet.value) return
  applyPopoverAtPoint(root.value, props.x, props.y)
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node) || root.value?.contains(target)) return
  if (target instanceof Element && target.closest('[data-testid="kind-badge-btn"], .touch-sheet-backdrop')) return
  emit('close')
}

async function onOpenChange(v: boolean) {
  if (v) {
    document.addEventListener('pointerdown', onDocPointer, true)
    await place()
    if (!props.open || sheet.value) return
    await nextTick()
    const list = items()
    focusWithoutScroll(list.find((el) => el.dataset.kind === props.current) || list[0])
  } else {
    document.removeEventListener('pointerdown', onDocPointer, true)
  }
}
/* the card mounts this picker only while it is open (CLE-35075), so the
   opening is usually the mount itself, not a change of `open` */
watch(() => props.open, onOpenChange)
onMounted(() => { if (props.open) void onOpenChange(true) })
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer, true))

function onKey(e: KeyboardEvent) {
  if (e.key === 'Escape' || e.key === 'Tab') {
    if (e.key === 'Escape') e.preventDefault()
    e.stopPropagation()
    emit('close')
    return
  }
  const list = items()
  const n = list.length
  if (!n) return
  const i = list.findIndex((el) => el === document.activeElement)
  let next = i < 0 ? 0 : i
  if (e.key === 'ArrowDown' || e.key === 'ArrowRight') next = (next + 1) % n
  else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') next = (next - 1 + n) % n
  else if (e.key === 'Home') next = 0
  else if (e.key === 'End') next = n - 1
  else return
  e.preventDefault()
  e.stopPropagation()
  focusWithoutScroll(list[next])
}

function choose(kind: string) {
  emit('choose', kind)
  emit('close')
}
</script>

<style scoped>
.kind-picker {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  max-height: calc(100dvh - 16px);
  overflow-y: auto;
  overscroll-behavior: contain;
  z-index: var(--z-overlay);
  min-width: 10rem;
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px;
  display: flex;
  flex-direction: column;
}
.kind-picker__item {
  appearance: none;
  display: flex;
  align-items: center;
  gap: 8px;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-text);
  font: inherit;
  font-size: 0.8125rem;
  text-align: start;
  padding: 4px 8px;
  cursor: pointer;
}
.kind-picker__item:hover,
.kind-picker__item:focus-visible,
.kind-picker__item[aria-checked='true'] {
  background: var(--color-surface-hover);
  outline: none;
}
</style>
