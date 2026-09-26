<!-- Right-click menu on a message. Same panel as a channel row: icon plus
     the action name, Escape and a click outside close it, arrows move. -->
<template>
  <Teleport to="body">
    <div
      v-if="open"
      ref="root"
      class="msg-menu"
      data-testid="msg-menu"
      :style="{ left: left + 'px', top: top + 'px' }"
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

const props = defineProps<{
  open: boolean
  x: number
  y: number
  editable?: boolean
  mergePrev?: boolean
  mergeNext?: boolean
  /** a thread line: offer Open parent section (CLE-34996) */
  parent?: boolean
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
}>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const focused = ref(-1)
const left = ref(0)
const top = ref(0)
const items = computed(() => msgMenuItems({
  editable: props.editable,
  mergePrev: props.mergePrev,
  mergeNext: props.mergeNext,
  parent: props.parent,
}))

function itemEls(): HTMLElement[] {
  return [...(root.value?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
}

async function focusItem(i: number) {
  focused.value = i
  await nextTick()
  itemEls()[i]?.focus()
}

async function place() {
  await nextTick()
  const panel = root.value
  if (!panel) return
  const w = panel.offsetWidth
  const h = panel.offsetHeight
  let x = props.x
  let y = props.y
  if (x + w > window.innerWidth - 8) x = Math.max(8, window.innerWidth - w - 8)
  if (y + h > window.innerHeight - 8) y = Math.max(8, props.y - h)
  left.value = x
  top.value = y
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node) || root.value?.contains(target)) return
  emit('close')
}

function onOpen() {
  left.value = props.x
  top.value = props.y
  document.addEventListener('pointerdown', onDocPointer, true)
  void focusItem(0)
  void place()
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
  emit('close')
}
</script>

<style scoped>
.msg-menu {
  position: fixed;
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
