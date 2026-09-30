<!-- SPL-1226: the issue context menu. A right-click (or long-press on touch)
     opens it AT the pointer, clamped inside the viewport; Escape and a click
     outside close it, arrows move. At <= 820 px it is a bottom sheet over a
     dimmed page (the same shape as MessageMenu). The parent passes the items
     and handles `choose`; this component is generic (rows and the epics
     sidebar both use it). -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="issue-menu"
      :class="{ 'touch-sheet': sheet }"
      data-testid="issue-menu"
      data-test="issues-ctxmenu"
      @keydown="onMenuKey"
      @contextmenu.prevent
    >
      <ul role="menu" class="issue-menu__items" :aria-label="t('issues_menu.label')">
        <li v-for="item in items" :key="item.id" role="none">
          <button
            type="button"
            role="menuitem"
            tabindex="-1"
            class="issue-menu__item"
            :class="{ 'issue-menu__item--danger': item.danger }"
            :data-testid="'issue-menu-' + item.id"
            :data-test="'issues-ctxmenu-' + item.id"
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
import { nextMenuIndex } from '~/utils/user-menu.mjs'
import { applyPopoverAtPoint, focusWithoutScroll } from '~/utils/place-popover.mjs'
import { usePhone } from '~/composables/useTouchUi'
import type { UiIconName } from '@/utils/uiIcons'

export type IssueMenuItem = { id: string, icon: UiIconName, labelKey: string, danger?: boolean }

const props = defineProps<{
  open: boolean
  x: number
  y: number
  items: IssueMenuItem[]
}>()

const emit = defineEmits<{
  close: []
  choose: [id: string]
}>()

const { t } = useI18n({ useScope: 'global' })
const root = ref<HTMLElement | null>(null)
const focused = ref(-1)
/* a phone gets the sheet; the desktop popover is placed at the pointer */
const sheet = usePhone()
/* on a phone the sheet is the top level while open - Back closes it first */
useMobileStack().overlay(() => props.open, () => emit('close'))

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
  const targetEl = e.target
  if (!(targetEl instanceof Node) || root.value?.contains(targetEl)) return
  if (targetEl instanceof Element && targetEl.closest('.touch-sheet-backdrop')) return
  emit('close')
}

async function onOpen() {
  document.addEventListener('pointerdown', onDocPointer, true)
  await place()
  if (!props.open) return
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
/* the point can move to another row while open: re-place without a re-focus */
watch(() => [props.x, props.y], () => { if (props.open) void place() })
onMounted(() => { if (props.open) onOpen() })
onBeforeUnmount(() => document.removeEventListener('pointerdown', onDocPointer, true))

function onMenuKey(e: KeyboardEvent) {
  const n = itemEls().length
  const next = nextMenuIndex(focused.value, e.key, n)
  if (next === -1) {
    e.preventDefault()
    emit('close')
    return
  }
  if (next !== focused.value) {
    e.preventDefault()
    void focusItem(next)
  }
}

function choose(id: string) {
  emit('choose', id)
  emit('close')
}
</script>

<style scoped>
.issue-menu {
  position: fixed;
  top: 0;
  left: 0;
  visibility: hidden;
  max-height: calc(100dvh - 16px);
  overflow-y: auto;
  overscroll-behavior: contain;
  z-index: var(--z-overlay);
  min-width: 11rem;
  max-width: min(16rem, 70vw);
  background: var(--color-bg-2, var(--color-surface));
  border: 1px solid var(--color-border-strong, var(--color-border));
  border-radius: var(--radius-md);
  box-shadow: 0 12px 32px rgb(0 0 0 / .35);
  padding: 4px 0;
}
.issue-menu__items { list-style: none; margin: 0; padding: 0; }
.issue-menu__item {
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
.issue-menu__item .ui-icon { flex: 0 0 auto; }
.issue-menu__item:hover,
.issue-menu__item:focus-visible {
  background: var(--color-surface-hover);
  outline: none;
}
.issue-menu__item--danger { color: var(--color-danger); }
/* the sheet variant reuses the shared touch-sheet rules from MessageMenu's
   layer; a phone row is a 44 px touch target */
.touch-sheet .issue-menu__item { min-height: var(--tap, 44px); }
</style>
