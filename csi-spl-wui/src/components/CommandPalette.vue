<!-- 081 T004 (FR-001, FR-002): the command palette, Ctrl + K / Cmd + K.
     One input over one ranked list: the sections, channels, people, topics,
     docs and settings pages usePaletteItems builds, ordered by
     utils/palette.mjs (an empty input lists the recent ones, else the
     sections). The input keeps the focus and is a combobox; the list is a
     listbox whose active row is aria-activedescendant, so ↑ / ↓ move it and
     Enter goes there. UiDialog owns Escape, the focus trap and giving the
     focus back. Mounted by the layout only while open (useGlobalKeys), so
     its chunk loads on the first Ctrl + K. It only navigates: it never sends
     a message (FR-005).
     081 T005 (FR-004): a leading '>' lists the actions instead
     (usePaletteActions): the selected card's menu items, each with its Shift
     key, then the page's own; Enter runs the item's own handler. -->
<template>
  <UiDialog v-model:open="open" :title="t('palette.title')" size="md">
    <div class="palette" data-testid="command-palette">
      <input
        v-model="query"
        class="palette__input"
        type="text"
        role="combobox"
        data-autofocus
        data-testid="command-palette-input"
        autocomplete="off"
        spellcheck="false"
        aria-autocomplete="list"
        :aria-expanded="rows.length > 0"
        :aria-controls="listId"
        :aria-activedescendant="activeRow ? optionId(active) : undefined"
        :aria-label="t('palette.input_label')"
        :placeholder="t('palette.placeholder')"
        @keydown="onKeydown"
      >
      <p v-if="!rows.length" class="muted palette__empty" data-testid="command-palette-empty">
        {{ t('palette.no_results') }}
      </p>
      <ul
        v-show="rows.length"
        :id="listId"
        ref="listEl"
        class="palette__list"
        role="listbox"
        :aria-label="t('palette.results_label')"
      >
        <li
          v-for="(row, i) in rows"
          :id="optionId(i)"
          :key="row.id"
          class="palette__row"
          role="option"
          data-testid="command-palette-row"
          :data-item="row.id"
          :aria-selected="i === active"
          @mousedown.prevent
          @mousemove="active = i"
          @click="run(row)"
        >
          <UiIcon v-if="row.icon" class="palette__icon" :name="row.icon" :size="16" />
          <span class="palette__label">{{ row.label }}</span>
          <kbd v-if="hintOf(row)" class="palette__key" data-testid="command-palette-key">{{ hintOf(row) }}</kbd>
          <span class="muted palette__group">{{ t('palette.group.' + row.group) }}</span>
        </li>
      </ul>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import { usePaletteOpen } from '~/composables/useGlobalKeys'
import { usePaletteActions, usePaletteItems, type PaletteActionItem, type PaletteGoItem } from '~/composables/usePaletteItems'
import { holdPanel, paletteCard } from '~/composables/useMsgShortcuts'
import { loadRecent, parseQuery, rankItems } from '~/utils/palette.mjs'

/** Rows drawn at most: the ranking puts the good ones first. */
const MAX_ROWS = 50

const { t } = useI18n({ useScope: 'global' })
const open = usePaletteOpen()
const palette = usePaletteItems()
const query = ref('')
const active = ref(0)
const listEl = ref<HTMLElement | null>(null)
const listId = useId()
const optionId = (i: number) => `${listId}-opt-${i}`

/* the card the actions act on, read before the dialog takes the focus */
const card = paletteCard()
const paletteActions = usePaletteActions()
const actions = computed(() => paletteActions.actions(card))

type PaletteRow = PaletteGoItem | PaletteActionItem
const isAction = (row: PaletteRow): row is PaletteActionItem => row.group === 'actions'
const hintOf = (row: PaletteRow) => (isAction(row) ? row.hint : '')

const recent = ref<string[]>([])
try { recent.value = loadRecent(window.localStorage) } catch { /* storage off: no recents */ }
palette.load()

const rows = computed<PaletteRow[]>(() => {
  const q = parseQuery(query.value)
  if (q.mode === 'actions') return (q.text ? rankItems(actions.value, q.text) : actions.value).slice(0, MAX_ROWS)
  const ranked = rankItems(palette.items.value, q.text, recent.value)
  if (!q.text && !ranked.length) return palette.sections.value.slice(0, MAX_ROWS)
  return ranked.slice(0, MAX_ROWS)
})
const activeRow = computed(() => rows.value[active.value] ?? null)

watch(query, () => { active.value = 0 })
watch(() => rows.value.length, (n) => { if (active.value >= n) active.value = Math.max(0, n - 1) })
watch(active, (i) => {
  void nextTick(() => listEl.value?.querySelector(`#${CSS.escape(optionId(i))}`)?.scrollIntoView({ block: 'nearest' }))
})

function step(by: number) {
  const n = rows.value.length
  if (n) active.value = (active.value + by + n) % n
}

function onKeydown(ev: KeyboardEvent) {
  if (ev.isComposing) return
  if (ev.key === 'ArrowDown') { ev.preventDefault(); step(1) } else if (ev.key === 'ArrowUp') { ev.preventDefault(); step(-1) } else if (ev.key === 'Enter') {
    ev.preventDefault()
    if (activeRow.value) void run(activeRow.value)
  }
}

/** After a go-to, the reader is in the page they went to: its middle pane holds the focus. */
function focusMiddle() {
  if (document.querySelector('[role="dialog"][aria-modal="true"]')) return
  const main = document.querySelector<HTMLElement>('.spool-main')
  if (!main || main.contains(document.activeElement)) return
  const target = main.querySelector<HTMLElement>('[data-selected="true"]') || main
  if (target === main && !main.hasAttribute('tabindex')) main.setAttribute('tabindex', '-1')
  target.focus({ preventScroll: true })
}

async function run(row: PaletteRow) {
  if (isAction(row)) return runAction(row)
  /* go() starts the navigation before closing unmounts this dialog */
  const going = palette.go(row)
  open.value = false
  await going
  /* the Settings pages open a dialog, and a list opens in the left pane: those place their own focus */
  if (!row.to || row.group === 'settings') return
  await nextTick()
  focusMiddle()
}

/** An action runs once the dialog is gone and the focus is back where it was. */
async function runAction(row: PaletteActionItem) {
  open.value = false
  await nextTick()
  /* as a Shift key does: the focus stays in the card's panel */
  if (row.row) holdPanel(row.row)
  await row.run()
}
</script>

<style scoped>
.palette { display: flex; flex-direction: column; gap: 0.5rem; padding: 0.5rem 1rem 1rem; min-height: 0; }
.palette__input {
  width: 100%;
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-bg);
  color: var(--color-fg);
  font: inherit;
}
.palette__empty { margin: 0.5rem 0; }
.palette__list { list-style: none; margin: 0; padding: 0; overflow-y: auto; max-height: min(60vh, 28rem); }
.palette__row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  min-height: 2.25rem;
  padding: 0.375rem 0.75rem;
  border-radius: var(--radius-sm);
  cursor: pointer;
  min-width: 0;
}
.palette__row[aria-selected="true"] { background: var(--color-surface-hover); }
.palette__icon { flex: none; color: var(--color-muted); }
.palette__label { min-width: 0; flex: 1 1 auto; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.palette__group { flex: none; font-size: 0.75rem; }
.palette__key {
  flex: none;
  padding: 0 0.375rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  color: var(--color-muted);
  font: inherit;
  font-size: 0.75rem;
}
</style>
