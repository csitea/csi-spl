<!-- A sheet's column name as its sort control: a click cycles ▲, ▼, then
     back to the list's own order (utils/sheet-sort.mjs cycleSort); only the
     sorted column shows its triangle (owner, topic e00da93b). The th around
     it carries aria-sort. Moved out of pages/issues.vue so the Issues list
     and Monitoring -> Lanes share one control (SPL-3887; owner HUM-10, t1
     31f6f470: "the same controls as the issues listing"). Listeners such as
     @keydown fall through to the button. -->
<template>
  <button
    type="button"
    class="issues-sort-h"
    :data-test="test"
    :data-sorted="sorted || undefined"
    @click="emit('sort', col)"
  >{{ name }}<span class="issues-sort-mark" aria-hidden="true">{{ sorted === 'asc' ? '▲' : sorted === 'desc' ? '▼' : '' }}</span></button>
</template>

<script setup lang="ts">
const props = defineProps<{
  /* the column's id and its shown name */
  col: string
  name: string
  /* the sheet's current sort ({ col: '', dir: '' } = its own order) */
  sort: { col: string, dir: string }
  test?: string
}>()
const emit = defineEmits<{ sort: [col: string] }>()
const sorted = computed(() => (props.sort.col === props.col && (props.sort.dir === 'asc' || props.sort.dir === 'desc') ? props.sort.dir : ''))
</script>

<style scoped>
.issues-sort-h {
  display: inline-block;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  font: inherit;
  cursor: pointer;
  white-space: nowrap;
}
.issues-sort-h::first-letter { text-transform: uppercase; }
.issues-sort-mark { display: inline-block; min-width: 0.75em; margin-inline-start: 4px; font-size: 0.625rem; color: var(--color-fg); }
.issues-sort-h:not([data-sorted]):hover .issues-sort-mark::before,
.issues-sort-h:not([data-sorted]):focus-visible .issues-sort-mark::before { content: '▲'; opacity: 0.35; }
</style>
