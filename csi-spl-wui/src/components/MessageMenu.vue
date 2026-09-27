<!-- Right-click menu on a message. Same panel as a channel row: icon plus
     the action name, Escape and a click outside close it, arrows move.
     SPL-991: at <= 820 px it is a bottom sheet (long-press or the ⋯ button),
     over a dimmed page a tap on which closes it. -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="msg-menu"
      :class="{ 'touch-sheet': sheet }"
      data-testid="msg-menu"
      @keydown="onMenuKey"
      @contextmenu.prevent
    >
      <ul role="menu" class="msg-menu__items" :aria-label="t('feed.msg_menu.label')">
        <li v-for="item in items" :key="item.id" role="none">
          <button
            type="button"
            role="menuitem"
            tabindex="-1"
            class="msg-menu__item"
            :data-testid="'msg-menu-' + item.id"
            @click.stop="choose(item.id)"
          >
            <UiIcon :name="item.icon" :size="16" />
            <span>{{ t(item.labelKey) }}</span>
          </button>
        </li>
      </ul>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { msgMenuItems } from '~/utils/msg-menu.mjs'
import { nextMenuIndex } from '~/utils/user-menu.mjs'
import { applyPopoverAtPoint, focusWithoutScroll } from '~/utils/place-popover.mjs'
import { usePhone } from '~/composables/useTouchUi'

const props = defineProps<{
  open: boolean
  x: number
  y: number
  editable?: boolean
  mergePrev?: boolean
  mergeNext?: boolean
  /** a thread line: offer Open parent section (CLE-34996) */
  parent?: boolean
  /** SPL-983: a topic card the viewer may archive / delete */
  topic?: boolean
  /** SPL-991: the viewer may re-type this message (the sheet's Kind item) */
  kind?: boolean
}>()

const emit = defineEmits<{
  close: []
  escape: []
  open: []
  parent: []
  edit: []
  copy: []
  'merge-prev': []
  'merge-next': []
  delete: []
  archive: []
  'delete-topic': []
  reply: []
  react: []
  'copy-text': []
  kind: []
}>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const focused = ref(-1)
/* SPL-991: a phone gets the sheet; the desktop popover is untouched */
const sheet = usePhone()
const items = computed(() => msgMenuItems({
  touch: sheet.value,
  kind: props.kind,
  editable: props.editable,
  mergePrev: props.mergePrev,
  mergeNext: props.mergeNext,
  parent: props.parent,
  topic: props.topic,
}))

function itemEls(): HTMLElement[] {
  return [...(root.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
}

async function focusItem(i: number) {
  focused.value = i
  await nextTick()
  focusWithoutScroll(itemEls()[i])
}

async function place() {
  await nextTick()
  if (sheet.value) return
  applyPopoverAtPoint(root.value, props.x, props.y)
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node) || root.value?.contains(target)) return
  /* the backdrop closes on its click, so the tap reaches nothing under it */
  if (target instanceof Element && target.closest('.touch-sheet-backdrop')) return
  emit('close')
}

async function onOpen() {
  document.addEventListener('pointerdown', onDocPointer, true)
  await place()
  if (!props.open) return
  /* a finger has no focus ring to follow: the sheet does not steal focus
     (that would also drop the on-screen keyboard mid-sentence) */
  if (sheet.value) return
  await focusItem(0)
}

watch(() => props.open, (v) => {
  if (v) {
    onOpen()
  } else {
    document.removeEventListener('pointerdown', onDocPointer, true)
    focused.value = -1
  }
})
/* MessageCard mounts this lazily, already open: the items exist only now */
onMounted(() => {
  if (props.open) onOpen()
})
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer, true))

function onMenuKey(e: KeyboardEvent) {
  const n = itemEls().length
  const next = nextMenuIndex(focused.value, e.key, n)
  if (next === -1) {
    e.preventDefault()
    emit('close')
    if (e.key === 'Escape') emit('escape')
    return
  }
  if (next !== focused.value) {
    e.preventDefault()
    void focusItem(next)
  }
}

function choose(id: string) {
  if (id === 'open') emit('open')
  else if (id === 'parent') emit('parent')
  else if (id === 'edit') emit('edit')
  else if (id === 'copy') emit('copy')
  else if (id === 'merge-prev') emit('merge-prev')
  else if (id === 'merge-next') emit('merge-next')
  else if (id === 'delete') emit('delete')
  else if (id === 'archive') emit('archive')
  else if (id === 'delete-topic') emit('delete-topic')
  else if (id === 'reply') emit('reply')
  else if (id === 'react') emit('react')
  else if (id === 'copy-text') emit('copy-text')
  else if (id === 'kind') emit('kind')
  emit('close')
}
</script>

<style scoped>
.msg-menu {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  max-height: calc(100dvh - 16px);
  overflow-y: auto;
  overscroll-behavior: contain;
  z-index: var(--z-overlay);
  min-width: 10rem;
  max-width: min(16rem, 70vw);
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px 0;
}
.msg-menu__items { list-style: none; margin: 0; padding: 0; }
.msg-menu__item {
  appearance: none;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  gap: 8px;
  width: 100%;
  text-align: start;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  padding: 8px 12px;
  cursor: pointer;
  min-height: 36px;
}
.msg-menu__item .ui-icon { flex: 0 0 auto; }
.msg-menu__item:hover,
.msg-menu__item:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
</style>
