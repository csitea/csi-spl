<!-- The column sheet on a phone, the Event log's (SPL-3366, SPL-994) shared
     with Monitoring -> Lanes (SPL-5276; owner HUM-10, t1 e1e97af9, msg
     7ccb6bfa): a bar with "Sorted: <column>, <direction>", a Sort button and
     a Filters button (a dot while a filter is on). Each opens a bottom sheet
     over a scrim: Sort lists the columns (a tap cycles that column as its
     name does on a desktop), Filters holds one filter per column and Clear
     filters. Back closes an open sheet first. The page mounts it only while
     usePhone() is on. -->
<template>
  <div class="sheet-mbar" :data-test="prefix + '-mbar'">
    <span class="sheet-mbar__sorted muted" :data-test="prefix + '-sorted-by'" :data-sort="sort.col" :title="sortWords">{{ t('issues_mobile.sorted_by', { sort: sortWords }) }}</span>
    <button type="button" class="btn ghost sheet-mbar__btn" :data-test="prefix + '-sort-open'" :aria-label="t('issues_mobile.sort')" :title="t('issues_mobile.sort')" aria-haspopup="dialog" @click="openSort">
      <UiIcon name="sort" :size="20" />
    </button>
    <button type="button" class="btn ghost sheet-mbar__btn" :data-test="prefix + '-filters-open'" :data-active="filtersOn ? 'true' : 'false'" :aria-label="t('issues_mobile.filters')" :title="t('issues_mobile.filters')" aria-haspopup="dialog" @click="openFilters">
      <UiIcon name="filter" :size="20" />
      <i v-if="filtersOn" class="sheet-mbar__dot" aria-hidden="true" />
    </button>
  </div>
  <template v-if="filtersOpen || sortOpen">
    <div class="sheet-scrim" :data-test="prefix + '-sheet-scrim'" @pointerdown.stop @click="close" />
    <section v-if="sortOpen" class="sheet-sheet" role="dialog" aria-modal="false" :data-test="prefix + '-sort-sheet'" :aria-label="t('issues_mobile.sort')">
      <header class="sheet-sheet__h">
        <UiCloseButton side="start" :size="20" class="sheet-sheet__x" @click="close" />
        <h3>{{ t('issues_mobile.sort') }}</h3>
        <UiCloseButton side="end" :size="20" class="sheet-sheet__x" @click="close" />
      </header>
      <p class="sheet-sort-now" :data-test="prefix + '-sort-now'">{{ sortWords }}</p>
      <button
        v-for="c in columns"
        :key="c.col"
        type="button"
        class="sheet-sort-opt"
        :data-test="prefix + '-sort-' + c.col"
        :aria-pressed="sort.col === c.col ? 'true' : 'false'"
        @click="emit('sort', c.col)"
      >
        <span>{{ c.label }}</span>
        <span aria-hidden="true">{{ sheetSortMark(sort, c.col) }}</span>
      </button>
    </section>
    <section v-if="filtersOpen" class="sheet-sheet" role="dialog" aria-modal="false" :data-test="prefix + '-filters'" :aria-label="t('issues_mobile.filters')">
      <header class="sheet-sheet__h">
        <UiCloseButton side="start" :size="20" class="sheet-sheet__x" @click="close" />
        <h3>{{ t('issues_mobile.filters') }}</h3>
        <UiCloseButton side="end" :size="20" class="sheet-sheet__x" @click="close" />
      </header>
      <label v-for="c in columns" :key="c.col" class="sheet-sheet__f">
        <span>{{ c.label }}</span>
        <SheetFilterField :column="c" :value="filters[c.col] || ''" :prefix="prefix" @filter="(col, v) => emit('filter', col, v)" />
      </label>
      <div class="sheet-sheet__foot">
        <button type="button" class="btn ghost" :data-test="prefix + '-filter-clear'" @click="emit('clear')">{{ t('issues.filter_clear') }}</button>
      </div>
    </section>
  </template>
</template>

<script setup lang="ts">
import { sheetSortMark } from '~/utils/column-sheet.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import type { SheetHeadColumn } from '~/components/SheetFilterField.vue'

defineProps<{
  columns: SheetHeadColumn[]
  sort: { col: string, dir: string }
  filters: Record<string, string>
  /* the data-test prefix: events-sort-open, lanes-filters, ... */
  prefix: string
  /* "<column>, <direction>" in words (utils/column-sheet.mjs sheetSortLabel) */
  sortWords: string
  filtersOn: boolean
}>()
const emit = defineEmits<{ sort: [col: string], filter: [col: string, value: string], clear: [] }>()
const { t } = useI18n({ useScope: 'global' })
const stack = useMobileStack()

const sortOpen = ref(false)
const filtersOpen = ref(false)
/* SPL-994: each sheet is the top level while open. Back closes it first. */
stack.overlay(() => filtersOpen.value, () => { filtersOpen.value = false })
stack.overlay(() => sortOpen.value, () => { sortOpen.value = false })

function close() {
  sortOpen.value = false
  filtersOpen.value = false
}
function openSort() {
  filtersOpen.value = false
  sortOpen.value = true
}
function openFilters() {
  sortOpen.value = false
  filtersOpen.value = true
}
defineExpose({ close })
</script>

<style scoped>
/* the phone bar and the sheets mount only while usePhone() is on (<= 820px) */
.sheet-mbar {
  display: flex;
  gap: 8px;
  padding: 0 12px 8px;
  align-items: center;
  min-width: 0;
}
.sheet-mbar__btn {
  position: relative;
  z-index: 0;
  flex: none;
  min-height: var(--tap, 44px);
  min-width: var(--tap, 44px);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  /* the Event log's own `.events-table-wrap .btn { margin-top: 0.75rem }` set
     this on master; a scoped rule does not reach a child component, so it is
     kept here, or the Event log's phone bar drops from 66 to 52 px */
  margin-top: 0.75rem;
}
.sheet-mbar__btn.btn.ghost,
.sheet-mbar__btn.btn.ghost:active { border: 0; background: transparent; }
.sheet-mbar__btn::before {
  content: '';
  position: absolute;
  inset: 5px;
  z-index: -1;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
}
.sheet-mbar__sorted {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 0.8125rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.sheet-mbar__dot {
  position: absolute;
  top: 8px;
  inset-inline-end: 8px;
  width: 8px;
  height: 8px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
}
.sheet-scrim {
  position: fixed;
  inset: 0;
  z-index: 38;
  background: rgb(0 0 0 / .4);
}
.sheet-sheet {
  position: fixed;
  inset-inline: 0;
  bottom: 0;
  left: 0;
  z-index: 39;
  width: 100%;
  min-width: 0;
  max-width: 100%;
  max-height: 75vh;
  max-height: 75dvh;
  overflow: auto;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 8px 16px calc(16px + env(safe-area-inset-bottom, 0px));
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-bottom: 0;
  border-radius: var(--radius-md) var(--radius-md) 0 0;
  box-shadow: 0 -8px 24px rgb(0 0 0 / .3);
}
.sheet-sheet__h { display: flex; align-items: center; gap: 8px; }
.sheet-sheet__h h3 {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  line-height: 1.3;
}
.sheet-sheet__x {
  min-width: var(--tap, 44px);
  min-height: var(--tap, 44px);
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.sheet-sheet__f {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.sheet-sheet :deep(.sheet-filter) {
  min-height: var(--tap, 44px);
  font-size: 1rem;
  line-height: 1.3;
}
.sheet-sheet__foot { display: flex; justify-content: flex-end; gap: 8px; }
.sheet-sheet__foot .btn { min-height: var(--tap, 44px); }
.sheet-sort-now { margin: 0; font-size: 0.875rem; font-weight: 600; line-height: 1.3; }
.sheet-sort-opt {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-height: var(--tap, 44px);
  width: 100%;
  margin: 0;
  padding: 0 8px;
  border: 0;
  background: transparent;
  color: inherit;
  font-family: inherit;
  font-size: 1rem;
  font-weight: 400;
  line-height: 1.3;
  text-align: start;
  cursor: pointer;
}
</style>
