<!-- Per-object menu on a left-pane row (not the icon tab rail).
     Three horizontal lines, which become an X while the menu is open.
     Click or Enter on the focused button toggles it. A click outside,
     Escape, or the X closes it. The panel is position:fixed and kept inside the viewport,
     so it cannot scroll the page.
     SPL-991: at <= 820 px the panel is a bottom sheet over a dimmed page,
     moved to <body> so no row's stacking context can sit on top of it.
     CLE-35062: the panel exists only while open (v-if, not v-show). Every row
     of every rail tab has one of these, and the closed panels - an item list
     with an icon per item - were 60 % of the whole page's DOM (3 172 of 5 304
     nodes on /lobby, 5 422 of 8 550 on /, prd e2e). focusItem() waits a tick
     before it places and focuses, so the panel is there by then. -->
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
      :aria-controls="open ? panelId : undefined"
      :aria-label="buttonLabel"
      :title="buttonLabel"
      @click.stop="emit('toggle')"
      @keydown="onTriggerKey"
    >
      <UiIcon :name="open ? 'x' : 'menu'" :size="16" />
    </button>
    <Teleport to="body" :disabled="!sheet">
      <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
      <div
        v-if="open"
        :id="panelId"
        ref="panel"
        class="sidebar-row-menu__panel"
        :class="{ 'touch-sheet': sheet }"
        data-testid="sidebar-row-menu-panel"
        :data-topic-state="topicState || undefined"
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
            >
              <UiIcon :name="item.icon" :size="16" />
              <span>{{ t(item.labelKey) }}</span>
            </button>
          </li>
        </ul>
      </div>
    </Teleport>
  </div>
</template>

<script setup lang="ts">
import { rowMenuItems } from '~/utils/sidebar-row-menu.mjs'
import { nextMenuIndex } from '~/utils/user-menu.mjs'
import { applyPopover, focusWithoutScroll, readViewport } from '~/utils/place-popover.mjs'
import { usePhone } from '~/composables/useTouchUi'

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
  pinned?: boolean
  channel?: boolean
  properties?: boolean
  deletable?: boolean
  /** SPL-1034: a Channels row that may go up / down one place */
  moveUp?: boolean
  moveDown?: boolean
  /** SPL-986: a topic row the hub said the viewer may archive / delete */
  topicArchive?: boolean
  topicDelete?: boolean
  /** SPL-986: '' | 'loading' | 'ready' | 'none' - the row's card lookup, for tests */
  topicState?: string
}>()

const emit = defineEmits<{
  toggle: []
  close: []
  open: []
  markRead: []
  block: []
  mute: []
  remove: []
  hide: []
  pin: []
  properties: []
  delete: []
  archive: []
  deleteTopic: []
  moveUp: []
  moveDown: []
}>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const trigger = ref<HTMLButtonElement | null>(null)
const panel = ref<HTMLElement | null>(null)
const focused = ref(-1)
const sheet = usePhone()
/* SPL-994: on a phone the sheet is the top level while open - Back closes it first */
useMobileStack().overlay(() => props.open, () => emit('close'))

const panelId = computed(() => 'sidebar-row-menu-' + props.menuId.replace(/[^A-Za-z0-9_-]/g, '-'))
const buttonLabel = computed(() => (props.open ? t('common.close') : t('sidebar.row_menu.label', { name: props.name })))
const items = computed(() => rowMenuItems(!!props.unread, {
  person: props.person,
  admin: props.admin,
  blocked: props.blocked,
  muted: props.muted,
  pinned: props.pinned,
  channel: props.channel,
  properties: props.properties,
  deletable: props.deletable,
  moveUp: props.moveUp,
  moveDown: props.moveDown,
  topicArchive: props.topicArchive,
  topicDelete: props.topicDelete,
}))

function itemEls(): HTMLElement[] {
  const host = panel.value || root.value
  return [...(host?.querySelectorAll<HTMLElement>('[role="menuitem"]') ?? [])]
}

function place() {
  const el = panel.value
  const btn = trigger.value
  if (!el || !btn || sheet.value) return
  const r = btn.getBoundingClientRect()
  applyPopover(el, {
    left: r.left,
    right: r.right,
    top: r.top,
    bottom: r.bottom,
    align: 'end',
    gap: 4,
  }, readViewport())
}

async function focusItem(i: number) {
  focused.value = i
  await nextTick()
  place()
  /* a finger follows no focus ring: the sheet does not move the focus */
  if (sheet.value) return
  focusWithoutScroll(itemEls()[i])
}

function onDocPointer(e: PointerEvent) {
  const target = e.target
  if (!(target instanceof Node)) return
  if (root.value?.contains(target) || panel.value?.contains(target)) return
  if (target instanceof Element && target.closest('.touch-sheet-backdrop')) return
  emit('close')
}

watch(() => props.open, (v) => {
  if (v) {
    document.addEventListener('pointerdown', onDocPointer, true)
    void focusItem(0)
  } else {
    document.removeEventListener('pointerdown', onDocPointer, true)
    focused.value = -1
  }
})
/* A topic row's Archive / Delete arrive after the hub answered (SPL-986):
   keep the grown panel inside the viewport. */
watch(() => items.value.length, async () => {
  if (!props.open) return
  await nextTick()
  place()
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
    focusWithoutScroll(trigger.value)
  }
}

function onMenuKey(e: KeyboardEvent) {
  const n = itemEls().length
  const next = nextMenuIndex(focused.value, e.key, n)
  if (next === -1) {
    if (e.key === 'Escape') e.preventDefault()
    emit('close')
    if (e.key === 'Escape') focusWithoutScroll(trigger.value)
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
  } else if (id === 'hide') {
    emit('hide')
  } else if (id === 'pin') {
    emit('pin')
  } else if (id === 'properties') {
    emit('properties')
  } else if (id === 'delete') {
    emit('delete')
  } else if (id === 'archive') {
    emit('archive')
  } else if (id === 'delete-topic') {
    emit('deleteTopic')
  } else if (id === 'move-up') {
    emit('moveUp')
  } else if (id === 'move-down') {
    emit('moveDown')
  } else {
    emit('open')
  }
  emit('close')
  focusWithoutScroll(trigger.value)
}
</script>

<style scoped>
.sidebar-row-menu {
  position: absolute;
  inset-inline-end: 6px;
  top: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  z-index: 1;
}
.sidebar-row-menu--open { z-index: 5; }
.sidebar-row-menu__btn[data-open="true"] {
  background: var(--color-surface-hover);
  border-color: var(--color-border);
}
.sidebar-row-menu__panel {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  min-width: 10rem;
  max-width: min(16rem, 70vw);
  max-height: calc(100dvh - 16px);
  overflow-y: auto;
  overscroll-behavior: contain;
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md, 12px);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px 0;
  z-index: var(--z-overlay, 1000);
}
.sidebar-row-menu__items { list-style: none; margin: 0; padding: 0; }
.sidebar-row-menu__item {
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
.sidebar-row-menu__item .ui-icon { flex: 0 0 auto; }
@media (max-width: 820px) {
  .sidebar-row-menu__btn { width: var(--tap); height: var(--tap); min-width: var(--tap); min-height: var(--tap); }
}
.sidebar-row-menu__item:hover,
.sidebar-row-menu__item:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
</style>
