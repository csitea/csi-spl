<!-- Per-object menu on a left-pane row (not the icon tab rail).
     Three horizontal lines, which become an X while the menu is open.
     Click or Enter on the focused button toggles it. A click outside,
     Escape, or the X closes it. -->
<template>
  <div
    ref="root"
    class="sidebar-row-menu"
    :class="{ 'sidebar-row-menu--open': open }"
  >
    <button
      ref="trigger"
      type="button"
      class="icon-btn sidebar-row-menu__btn"
      data-testid="sidebar-row-menu"
      :data-menu-id="menuId"
      :data-open="open ? 'true' : 'false'"
      aria-haspopup="menu"
      :aria-expanded="open ? 'true' : 'false'"
      :aria-controls="panelId"
      :aria-label="buttonLabel"
      :title="buttonLabel"
      @click.stop="emit('toggle')"
      @keydown="onTriggerKey"
    >
      <UiIcon :name="open ? 'x' : 'menu'" :size="16" />
    </button>
    <div
      v-show="open"
      :id="panelId"
      class="sidebar-row-menu__panel"
      data-testid="sidebar-row-menu-panel"
      @keydown="onMenuKey"
    >
      <ul role="menu" class="sidebar-row-menu__items" :aria-label="buttonLabel">
        <li v-for="item in items" :key="item.id" role="none">
          <button
            type="button"
            role="menuitem"
            tabindex="-1"
            class="sidebar-row-menu__item"
            :data-testid="'sidebar-row-menu-' + item.id"
            @click.stop="choose(item.id)"
          >{{ t(item.labelKey) }}</button>
        </li>
      </ul>
    </div>
  </div>
</template>

<script setup lang="ts">
import { rowMenuItems } from '~/utils/sidebar-row-menu.mjs'
import { nextMenuIndex } from '~/utils/user-menu.mjs'

const props = defineProps<{
  menuId: string
  name: string
  href: string
  unread?: boolean
  open: boolean
  person?: boolean
  admin?: boolean
  blocked?: boolean
  muted?: boolean
}>()

const emit = defineEmits<{
  toggle: []
  close: []
  open: []
  markRead: []
  block: []
  mute: []
  remove: []
}>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)
const focused = ref(-1)

const panelId = computed(() => 'sidebar-row-menu-' + props.menuId.replace(/[^A-Za-z0-9_-]/g, '-'))
const buttonLabel = computed(() => (props.open ? t('common.close') : t('sidebar.row_menu.label', { name: props.name })))
const items = computed(() => rowMenuItems(!!props.unread, {
  person: props.person,
  admin: props.admin,
  blocked: props.blocked,
  muted: props.muted,
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
  const panel = root.value?.querySelector<HTMLElement>('.sidebar-row-menu__panel')
  const btn = trigger.value
  if (!panel || !btn) return
  const r = btn.getBoundingClientRect()
  const h = panel.offsetHeight
  const up = r.bottom + 8 + h > window.innerHeight && r.top > h + 8
  panel.classList.toggle('sidebar-row-menu__panel--up', up)
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node) || root.value?.contains(target)) return
  emit('close')
}

watch(() => props.open, (v) => {
  if (v) {
    document.addEventListener('pointerdown', onDocPointer, true)
    void focusItem(0)
    void place()
  } else {
    document.removeEventListener('pointerdown', onDocPointer, true)
    focused.value = -1
  }
})
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer, true))

function onTriggerKey(e: KeyboardEvent) {
  if (e.key === 'ArrowDown') {
    e.preventDefault()
    if (!props.open) emit('toggle')
    else void focusItem(0)
  } else if (e.key === 'ArrowUp') {
    e.preventDefault()
    if (!props.open) emit('toggle')
    else void focusItem(itemEls().length - 1)
  } else if (e.key === 'Escape' && props.open) {
    e.preventDefault()
    emit('close')
    trigger.value?.focus()
  }
}

function onMenuKey(e: KeyboardEvent) {
  const n = itemEls().length
  const next = nextMenuIndex(focused.value, e.key, n)
  if (next === -1) {
    if (e.key === 'Escape') e.preventDefault()
    emit('close')
    if (e.key === 'Escape') trigger.value?.focus()
    return
  }
  if (next !== focused.value) {
    e.preventDefault()
    void focusItem(next)
  }
}

async function copyLink() {
  const url = new URL(props.href, window.location.origin).href
  try {
    await navigator.clipboard.writeText(url)
  } catch {
    const ta = document.createElement('textarea')
    ta.value = url
    ta.setAttribute('readonly', '')
    ta.style.position = 'fixed'
    ta.style.inset = '0'
    ta.style.width = '1px'
    ta.style.height = '1px'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.select()
    document.execCommand('copy')
    ta.remove()
  }
}

function choose(id: string) {
  if (id === 'copy') {
    void copyLink()
  } else if (id === 'read') {
    emit('markRead')
  } else if (id === 'block') {
    emit('block')
  } else if (id === 'mute') {
    emit('mute')
  } else if (id === 'remove') {
    emit('remove')
  } else {
    emit('open')
  }
  emit('close')
  trigger.value?.focus()
}
</script>

<style scoped>
.sidebar-row-menu {
  position: absolute;
  inset-inline-end: 6px;
  top: 50%;
  transform: translateY(-50%);
  z-index: 1;
}
.sidebar-row-menu--open { z-index: 5; }
.sidebar-row-menu__btn[data-open="true"] {
  background: var(--color-surface-hover);
  border-color: var(--color-border);
}
.sidebar-row-menu__panel {
  position: absolute;
  inset-inline-end: 0;
  top: calc(100% + 4px);
  min-width: 10rem;
  max-width: min(16rem, 70vw);
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md, 12px);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px 0;
  z-index: var(--z-overlay, 1000);
}
.sidebar-row-menu__panel--up {
  top: auto;
  bottom: calc(100% + 4px);
}
.sidebar-row-menu__items { list-style: none; margin: 0; padding: 0; }
.sidebar-row-menu__item {
  appearance: none;
  display: block;
  width: 100%;
  text-align: start;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  font: inherit;
  font-size: 14px;
  padding: 8px 12px;
  cursor: pointer;
  min-height: 32px;
}
.sidebar-row-menu__item:hover,
.sidebar-row-menu__item:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
</style>
