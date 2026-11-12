<!-- SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806:
     "a nice sortable and listable table for the costs on monthly basis"):
     a label's items per month of the period, one money column per month in
     the header's currency, the period's total when it has more than one
     month, and the item's share. A click (or Enter / Space: each name is a
     button) on a column name sorts by it, a second click flips it; the
     th carries aria-sort. A cell with no amount is a dash with its title
     (never a guess) and sorts last both ways. The rows come formatted from
     CostsLabel.vue; this file only draws and sorts. -->
<template>
  <div class="cmt-wrap" data-test="costs-month-table-wrap">
    <table class="cmt" :aria-label="caption" data-test="costs-month-table" :data-sort="sort ? sort.col + ':' + sort.dir : ''">
      <thead>
        <tr>
          <th v-for="c in cols" :key="c.id" scope="col" :class="{ num: c.id !== 'name' }" :aria-sort="ariaSort(c.id)" :data-test="'cmt-col-' + c.id">
            <button type="button" class="cmt-sort" :data-test="'cmt-sort-' + c.id" @click="clickSort(c.id)">
              <span>{{ c.label }}</span><span class="cmt-mark" aria-hidden="true">{{ mark(c.id) }}</span>
            </button>
          </th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="r in sorted" :key="r.key" data-test="cmt-row" :data-key="r.key">
          <th scope="row" class="cmt-name">
            <NuxtLink v-if="r.to" :to="r.to" data-test="cmt-drill">{{ r.display }}</NuxtLink>
            <span v-else>{{ r.display }}</span>
            <span v-if="r.badge" class="cmt-badge" data-test="cmt-badge">{{ r.badge }}</span>
            <span v-if="r.sub" class="cmt-sub muted">{{ r.sub }}</span>
          </th>
          <td v-for="(c, i) in r.cells" :key="i" class="num" :data-label="months[i]" data-test="cmt-cell" :data-none="c.v === null ? '1' : '0'" :title="cellTitle(c)">{{ cellText(c) }}</td>
          <td v-if="months.length > 1" class="num" :data-label="totalHead" data-test="cmt-total" :data-none-part="r.total.none || 0" :data-none="r.total.v === null ? '1' : '0'" :title="cellTitle(r.total)">{{ cellText(r.total) }}</td>
          <td class="num" :data-label="shareHead" data-test="cmt-pct">{{ r.pct === null ? '' : r.pct + ' %' }}</td>
        </tr>
        <tr v-if="!rows.length">
          <td :colspan="cols.length" class="muted" data-test="cmt-empty">{{ empty }}</td>
        </tr>
      </tbody>
      <tfoot v-if="rows.length">
        <tr data-test="cmt-foot">
          <th scope="row">{{ totalHead }}</th>
          <td v-for="(c, i) in totals.cells" :key="i" class="num" :data-label="months[i]" data-test="cmt-foot-cell" :data-none-part="c.none || 0" :data-left="c.left" :title="cellTitle(c)">{{ cellText(c) }}</td>
          <td v-if="months.length > 1" class="num" :data-label="totalHead" data-test="cmt-foot-total" :data-none-part="totals.total.none || 0" :data-left="totals.total.left" :title="cellTitle(totals.total)">{{ cellText(totals.total) }}</td>
          <td class="num" :data-label="shareHead">{{ totals.total.v ? '100 %' : '' }}</td>
        </tr>
      </tfoot>
    </table>
  </div>
</template>

<script setup lang="ts">
import { costsNextSort, costsSortRows } from '~/utils/costs-labels.mjs'

type Cell = { v: number | null, left: number, empty: boolean, none?: number }
type Row = { key: string, name: string, display: string, sub?: string, badge?: string, to?: unknown, cells: Cell[], total: Cell, pct: number | null }
type Sort = { col: string, dir: 'ascending' | 'descending' }

const props = defineProps<{
  rows: Row[]
  months: string[]
  totals: { cells: Cell[], total: Cell }
  caption: string
  nameHead: string
  money: (c: Cell) => string
  noneTitle: string
  empty: string
}>()

const { t, locale } = useI18n({ useScope: 'global' })
const totalHead = computed(() => t('monitoring.costs.total'))
const shareHead = computed(() => t('reporting.costs.col_share'))
const cols = computed(() => [
  { id: 'name', label: props.nameHead },
  ...props.months.map((m, i) => ({ id: String(i), label: m })),
  ...(props.months.length > 1 ? [{ id: 'total', label: totalHead.value }] : []),
  { id: 'pct', label: shareHead.value },
])

const sort = ref<Sort | null>(null)
const sorted = computed(() => (sort.value ? costsSortRows(props.rows, sort.value.col, sort.value.dir, locale.value) : props.rows) as Row[])
function clickSort(col: string) { sort.value = costsNextSort(sort.value, col) as Sort }
const ariaSort = (col: string) => (sort.value && sort.value.col === col ? sort.value.dir : 'none')
const mark = (col: string) => (sort.value && sort.value.col === col ? (sort.value.dir === 'ascending' ? '▲' : '▼') : '')

function cellText(c: Cell) {
  if (c.empty) return ''
  return c.v === null ? '—' : props.money(c)
}
// A sum that leaves out a cell with no amount (no rate) says so (c-974 review N1).
function cellTitle(c: Cell) {
  if (c.v === null && !c.empty) return props.noneTitle
  const why = [c.none ? props.noneTitle : '', c.left ? t('monitoring.costs.total_unpriced', { n: c.left }) : ''].filter(Boolean)
  return why.length ? why.join(' · ') : undefined
}
</script>

<style scoped>
.cmt-wrap { max-width: 100%; overflow-x: auto; }
.cmt { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.cmt th, .cmt td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.cmt thead th { white-space: nowrap; }
.cmt .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.cmt tbody th { font-weight: 400; }
.cmt tfoot th, .cmt tfoot td { font-weight: 600; border-bottom: 0; }
.cmt-sort { display: inline-flex; align-items: center; gap: 4px; padding: 0; border: 0; background: none; color: inherit; font: inherit; font-weight: 600; cursor: pointer; }
.cmt-mark { min-width: 0.75rem; font-size: 0.75rem; }
.cmt-name { min-width: 8rem; overflow-wrap: anywhere; }
.cmt-badge { margin-inline-start: 6px; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); font-size: 0.75rem; white-space: nowrap; }
.cmt-sub { display: block; font-size: 0.75rem; }
</style>
