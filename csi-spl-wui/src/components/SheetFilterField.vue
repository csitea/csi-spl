<!-- One column's filter in the column sheet (SPL-5276): a text box, or a
     select of the column's choices with All first. SheetHead.vue puts one
     under each name on a desktop, SheetPhoneBar.vue one per column in its
     filter sheet, so both read the same. -->
<template>
  <input
    v-if="column.kind === 'text'"
    :value="value"
    type="text"
    class="sheet-filter"
    :data-test="prefix + '-filter-' + column.col"
    :aria-label="column.label"
    @input="emit('filter', column.col, ($event.target as HTMLInputElement).value)"
  >
  <select
    v-else
    :value="value"
    class="sheet-filter"
    :data-test="prefix + '-filter-' + column.col"
    :aria-label="column.label"
    @change="emit('filter', column.col, ($event.target as HTMLSelectElement).value)"
  >
    <option value="">{{ t('issues.filter_all') }}</option>
    <option v-for="o in column.choices || []" :key="o.value" :value="o.value">{{ o.label }}</option>
  </select>
</template>

<script lang="ts">
/** A column as the sheet's controls show it: its name in words, a text or choice filter, the choices offered. */
export type SheetHeadColumn = {
  col: string
  label: string
  kind: 'text' | 'choice'
  choices?: { value: string, label: string }[]
  cls?: string
  test?: string
}
</script>

<script setup lang="ts">
defineProps<{ column: SheetHeadColumn, value: string, prefix: string }>()
const emit = defineEmits<{ filter: [col: string, value: string] }>()
const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.sheet-filter {
  width: 100%;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-bg);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 0.15rem 0.35rem;
  font-family: inherit;
  font-size: 0.8125rem;
  font-weight: 400;
  line-height: 1.3;
}
</style>
