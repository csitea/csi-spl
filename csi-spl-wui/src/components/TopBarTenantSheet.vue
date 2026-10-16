<!-- SPL-995 (<= 820 px): the phone top bar's tenant sheet, opened by
     TopBarTenant's drop box: a bottom sheet over a scrim listing the
     tenants; picking another one switches (useTenantSwitch, specs/026 §6).
     SPL-2268 (owner t1 b21bbf73, "does not accept typical keyboard sequence
     inputs"): the sheet is a keyboard combobox. A search box heads it:
     typing filters the rows by a case-insensitive "contains", Up/Down and
     Home/End move the highlight, Enter switches to the highlighted row (or
     the only one left), Esc closes and gives the focus back to the box. With
     a mouse or a keyboard the search box takes the focus on open; on a
     touch screen (pointer: coarse) the current row does (no on-screen
     keyboard popping up), and a letter typed on a row moves to the search
     box. A lazy chunk: the first screen's bundle carries the box only
     (ci_home_gzip_kb, perf-budgets.json). -->
<template>
  <div class="tb-tenant__scrim" data-testid="top-bar-tenant-scrim" aria-hidden="true" @click="emit('close', true)" />
  <div
    class="tb-tenant__sheet"
    data-testid="top-bar-tenant-sheet"
    role="dialog"
    aria-modal="true"
    :aria-label="t('sidebar.tenant')"
    @keydown.esc.prevent="emit('close', true)"
    @keydown="onRowKey"
  >
    <span class="tb-tenant__grip" aria-hidden="true" />
    <p class="tb-tenant__hint">{{ ts.hint.value }}</p>
    <input
      ref="searchEl"
      class="tb-tenant__search"
      data-testid="top-bar-tenant-search"
      type="text"
      role="combobox"
      autocomplete="off"
      spellcheck="false"
      aria-autocomplete="list"
      aria-expanded="true"
      :aria-controls="LIST_ID"
      :aria-activedescendant="activeId"
      :value="query"
      :placeholder="t('sidebar.tenant')"
      :aria-label="t('sidebar.tenant')"
      @input="onSearchInput"
      @keydown="onSearchKey"
    >
    <ul :id="LIST_ID" class="tb-tenant__list" role="listbox" :aria-label="t('sidebar.tenant')">
      <li v-for="(o, i) in shownRows" :key="o.id" role="none">
        <button
          :id="LIST_ID + '-' + i"
          type="button"
          role="option"
          class="tb-tenant__row"
          :class="{ 'is-active': i === activeIndex }"
          data-testid="top-bar-tenant-option"
          :data-tenant="o.id"
          :aria-selected="o.id === ts.box.value.selected ? 'true' : 'false'"
          :disabled="ts.switching.value"
          @click="emit('pick', o.id)"
        >
          <span class="tb-tenant__row-name">{{ o.label || o.id }}</span>
          <UiIcon v-if="o.id === ts.box.value.selected" name="check" :size="18" />
        </button>
      </li>
    </ul>
    <p v-if="ts.failed.value" class="tb-tenant__error" role="alert" data-testid="top-bar-tenant-error">{{ t('sidebar.tenant_switch_failed') }}</p>
  </div>
</template>

<script setup lang="ts">
import type { useTenantSwitch } from '~/composables/useTenantSwitch'
import { focusWithoutScroll } from '~/utils/place-popover.mjs'
import { tenantMatches } from '~/utils/tenant-switcher.mjs'

const props = defineProps<{ ts: ReturnType<typeof useTenantSwitch> }>()
const emit = defineEmits<{ close: [refocus: boolean], pick: [id: string] }>()
const LIST_ID = 'top-bar-tenant-list'
const { t } = useI18n({ useScope: 'global' })
const searchEl = ref<HTMLInputElement | null>(null)
/* the placeholder row (no active tenant named yet) is not a choice */
const rows = computed(() => props.ts.box.value.options.filter((o: { id: string }) => o.id))
/* what was typed in the search box, and the highlighted row */
const query = ref('')
const shownRows = computed(() => rows.value.filter((o: { id: string, label: string }) => tenantMatches(o.label || o.id, query.value)))
const activeIndex = ref(Math.max(0, shownRows.value.findIndex((o: { id: string }) => o.id === props.ts.box.value.selected)))
const activeId = computed(() => (activeIndex.value >= 0 && activeIndex.value < shownRows.value.length ? LIST_ID + '-' + activeIndex.value : undefined))

function rowButtons() {
  return [...document.querySelectorAll<HTMLElement>('[data-testid=top-bar-tenant-option]')]
}
onMounted(() => {
  /* a touch screen (pointer: coarse) keeps its on-screen keyboard down */
  if (!window.matchMedia?.('(pointer: coarse)').matches) return focusWithoutScroll(searchEl.value)
  focusWithoutScroll(document.querySelector<HTMLElement>('[data-testid=top-bar-tenant-option][aria-selected=true]') || rowButtons()[0])
})
function onSearchInput(ev: Event) {
  if (!(ev.target instanceof HTMLInputElement)) return
  query.value = ev.target.value
  activeIndex.value = shownRows.value.length ? 0 : -1
}
/** Up/Down step (wrapping), Home/End jump; -1 when nothing is listed */
function nextIndex(key: string, at: number, n: number): number {
  if (!n) return -1
  if (key === 'Home') return 0
  if (key === 'End') return n - 1
  if (at < 0) return key === 'ArrowDown' ? 0 : n - 1
  return (at + (key === 'ArrowDown' ? 1 : -1) + n) % n
}
const MOVE_KEYS = new Set(['ArrowDown', 'ArrowUp', 'Home', 'End'])
function onSearchKey(ev: KeyboardEvent) {
  if (ev.isComposing) return
  if (MOVE_KEYS.has(ev.key)) {
    ev.preventDefault()
    activeIndex.value = nextIndex(ev.key, activeIndex.value, shownRows.value.length)
    document.getElementById(activeId.value || '')?.scrollIntoView({ block: 'nearest' })
  } else if (ev.key === 'Enter') {
    ev.preventDefault()
    const list = shownRows.value
    const row = list[activeIndex.value] || (list.length === 1 ? list[0] : null)
    if (row) emit('pick', row.id)
  }
}
/* the focus on a row (a touch open, or Tab): the arrows walk the rows, and
   a letter goes to the search box (focused during its keydown, so the
   letter lands there) */
function onRowKey(ev: KeyboardEvent) {
  if (ev.target === searchEl.value || ev.isComposing) return
  const buttons = rowButtons()
  const at = buttons.indexOf(ev.target as HTMLElement)
  if (at >= 0 && MOVE_KEYS.has(ev.key)) {
    ev.preventDefault()
    activeIndex.value = nextIndex(ev.key, at, buttons.length)
    focusWithoutScroll(buttons[activeIndex.value])
  } else if (ev.key.length === 1 && ev.key !== ' ' && !ev.ctrlKey && !ev.metaKey && !ev.altKey) {
    focusWithoutScroll(searchEl.value)
  }
}
</script>

<style scoped>
.tb-tenant__scrim {
  position: fixed;
  inset: 0;
  z-index: var(--z-overlay, 1000);
  background: rgb(0 0 0 / .45);
}
.tb-tenant__sheet {
  position: fixed;
  inset-inline: 0;
  bottom: 0;
  z-index: calc(var(--z-overlay, 1000) + 1);
  max-height: 85dvh;
  overflow-y: auto;
  overscroll-behavior: contain;
  box-sizing: border-box;
  padding: 6px 0 calc(8px + env(safe-area-inset-bottom, 0px));
  background: var(--color-bg-2);
  border: 1px solid var(--color-border-strong);
  border-bottom: 0;
  border-radius: var(--radius-md, 12px) var(--radius-md, 12px) 0 0;
  box-shadow: 0 -12px 32px rgb(0 0 0 / .35);
}
.tb-tenant__grip {
  display: block;
  width: 36px;
  height: 4px;
  margin: 2px auto 6px;
  border-radius: var(--radius-pill, 999px);
  background: var(--color-border-strong);
}
.tb-tenant__hint {
  margin: 0;
  padding: 4px 14px 8px;
  font-size: 0.8125rem;
  color: var(--color-muted);
  border-bottom: 1px solid var(--color-border);
}
/* SPL-2268: the search box; 1rem so a phone does not zoom into it */
.tb-tenant__search {
  display: block;
  box-sizing: border-box;
  width: calc(100% - 28px);
  min-height: 40px;
  margin: 8px 14px 0;
  padding: 0 10px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-xs);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
  font-size: 1rem;
}
.tb-tenant__search::placeholder { color: var(--color-muted); opacity: 1; }
.tb-tenant__list { list-style: none; margin: 6px 0 0; padding: 0; }
.tb-tenant__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  width: 100%;
  min-height: 48px;
  padding: 0 14px;
  border: 0;
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.9375rem;
  text-align: start;
  cursor: pointer;
}
.tb-tenant__row[aria-selected=true] { font-weight: 700; color: var(--color-accent); }
.tb-tenant__row:hover, .tb-tenant__row:focus-visible, .tb-tenant__row.is-active { background: var(--color-surface-hover); }
.tb-tenant__row-name { min-width: 0; overflow-wrap: anywhere; }
.tb-tenant__error {
  margin: 6px 14px 0;
  font-size: 0.8125rem;
  color: var(--color-danger);
}
</style>
