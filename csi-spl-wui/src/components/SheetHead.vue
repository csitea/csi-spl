<!-- The column sheet's head, the Event log's (SPL-3366) shared with
     Monitoring -> Lanes (SPL-5276; owner HUM-10, t1 e1e97af9, msg 7ccb6bfa:
     "Sorting and filtering in lanes should behave exactly as sorting and
     filtering for the event log"). On a desktop: each column name is its
     sort button (none -> ▲ -> ▼ -> none, utils/column-sheet.mjs), the th
     carries aria-sort, and the row under the names holds one filter per
     column: a text box, or a select of the choices with All first. On a
     phone the names stay for readers and SheetPhoneBar.vue sorts and
     filters. The `lead` / `lead-filter` slots hold a leading column (the
     Event log's box column). -->
<template>
  <thead :data-test="phone ? undefined : prefix + '-filters'">
    <tr>
      <slot name="lead" />
      <th v-for="c in columns" :key="c.col" scope="col" :class="c.cls" :data-test="c.test" :aria-sort="phone ? undefined : sheetAriaSort(sort, c.col)">
        <button
          v-if="!phone"
          type="button"
          class="sheet-sort-h"
          :data-test="prefix + '-sort-' + c.col"
          :data-sorted="sort.col === c.col ? sort.dir : undefined"
          @click="emit('sort', c.col)"
        >{{ c.label }}<span class="sheet-sort-mark" aria-hidden="true">{{ sheetSortMark(sort, c.col) }}</span></button>
        <template v-else>{{ c.label }}</template>
      </th>
    </tr>
    <tr v-if="!phone" class="sheet-frow">
      <slot name="lead-filter" />
      <th v-for="c in columns" :key="'f-' + c.col" class="sheet-filter-h">
        <SheetFilterField :column="c" :value="filters[c.col] || ''" :prefix="prefix" @filter="(col, v) => emit('filter', col, v)" />
      </th>
    </tr>
  </thead>
</template>

<script setup lang="ts">
import { sheetAriaSort, sheetSortMark } from '~/utils/column-sheet.mjs'
import type { SheetHeadColumn } from '~/components/SheetFilterField.vue'

defineProps<{
  columns: SheetHeadColumn[]
  sort: { col: string, dir: string }
  filters: Record<string, string>
  phone: boolean
  /* the data-test prefix: events-sort-<col>, lanes-filter-<col>, ... */
  prefix: string
}>()
const emit = defineEmits<{ sort: [col: string], filter: [col: string, value: string] }>()
</script>

<style scoped>
.sheet-sort-h {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  max-width: 100%;
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  font-family: inherit;
  font-size: inherit;
  font-weight: inherit;
  line-height: inherit;
  letter-spacing: inherit;
  text-transform: inherit;
  cursor: pointer;
  text-align: start;
}
.sheet-sort-mark {
  display: inline-block;
  min-width: 0.75em;
  font-size: 0.625rem;
  color: var(--color-fg);
}
.sheet-filter-h {
  text-transform: none;
  letter-spacing: normal;
  font-weight: 400;
  vertical-align: middle;
}
</style>
