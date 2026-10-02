<!-- 022 §10: the right menu of a search result row. The same
     panel as the message menu (icon + name, arrows move, Escape and a click
     outside close it); a bottom sheet at <= 820 px. The items come from
     utils/search-results.mjs searchRowMenuItems. -->
<template>
  <Teleport to="body">
    <SheetBackdrop v-if="open && sheet" @close="emit('close')" />
    <div
      v-if="open"
      ref="root"
      class="msg-menu search-row-menu"
      :class="{ 'touch-sheet': sheet }"
      data-testid="search-row-menu"
      @keydown="onMenuKey"
      @contextmenu.prevent
    >
      <ul role="menu" class="msg-menu__items" :aria-label="t('search.menu.label')">
        <li v-for="item in items" :key="item.id" role="none">
          <button
            type="button"
            role="menuitem"
            tabindex="-1"
            class="msg-menu__item"
            :data-testid="'search-row-menu-' + item.id"
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
import { usePointMenu } from '~/composables/usePointMenu'

type Item = { id: string, icon: import('~/utils/uiIcons').UiIconName, labelKey: string }
const props = defineProps<{
  open: boolean
  x: number
  y: number
  items: Item[]
}>()

const emit = defineEmits<{
  close: []
  escape: []
  choose: [id: string]
}>()

const { t } = useI18n({ useScope: 'global' })
const { root, sheet, onMenuKey } = usePointMenu({
  open: () => props.open, x: () => props.x, y: () => props.y,
  close: () => emit('close'), escape: () => emit('escape'),
})
const items = computed(() => props.items)

/* choose first: the host reads its open row before close clears it */
function choose(id: string) {
  emit('choose', id)
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
