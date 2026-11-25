<!-- SPL-6438 (spec 143 taxes-tab.md section 5; owner HUM-10, csitea topic
     dc7c9c9a, msg fc8f964e: "Every person of csitea; agents never",
     "Weekly, after the weekly tax check"): Reporting -> Costs -> Taxes, its
     own route and chunk. The main box's tax index as the hub keeps it
     (GET /v1/view/tax/overview, utils/reporting-tax.mjs): what is due in
     the next 30 days (overdue marked), this week's new and changed
     documents and open questions, and the year's documents with filters.
     No amount and no document link: the index has none and the documents
     stay on the main box. In every other workspace, and for a seat that is
     not a person's, the hub refuses and this page shows one neutral line,
     never a row. -->
<template>
  <div class="reporting-taxes" data-test="reporting-taxes">
    <p v-if="state === 'loading'" class="muted" role="status" data-test="taxes-loading">{{ t('reporting.taxes.loading') }}</p>
    <p v-else-if="state === 'absent'" class="muted" role="status" data-test="taxes-absent">{{ t('reporting.taxes.absent') }}</p>
    <p v-else-if="state === 'error'" class="tax-error" role="alert" data-test="taxes-error">{{ t('reporting.taxes.error') }}</p>
    <template v-else>
      <div class="tax-head" data-test="taxes-head">
        <label v-if="years.length > 1" class="tax-pick">
          <span>{{ t('reporting.taxes.year') }}</span>
          <select :value="year" data-test="taxes-year" @change="pickYear">
            <option v-for="y in years" :key="y" :value="y">{{ y }}</option>
          </select>
        </label>
        <span v-if="view?.taken_at" class="muted" data-test="taxes-as-of">{{ t('reporting.taxes.as_of', { time: isoDateTime(view.taken_at) }) }}</span>
      </div>

      <p v-if="!view?.snapshot_id" class="muted" data-test="taxes-empty">{{ t('reporting.taxes.empty') }}</p>
      <template v-else>
        <section class="tax-card" :aria-label="t('reporting.taxes.due.title')" data-test="taxes-due">
          <h3 class="tax-title">{{ t('reporting.taxes.due.title') }}</h3>
          <p v-if="!blocks.due.length" class="muted" data-test="taxes-due-empty">{{ t('reporting.taxes.due.empty') }}</p>
          <ul v-else class="tax-list">
            <li v-for="(d, i) in blocks.due" :key="'due' + i" data-test="taxes-due-row" :data-overdue="d.overdue ? 'true' : 'false'">
              <span class="num">{{ d.due_date }}</span>
              <span class="tax-what">{{ d.kind }} · {{ d.doc_type }} · {{ d.tax_type }} · {{ d.period }}</span>
              <span v-if="d.overdue" class="tax-flag tax-flag--warn" data-test="taxes-overdue">{{ t('reporting.taxes.overdue') }}</span>
            </li>
          </ul>
        </section>

        <section class="tax-card" :aria-label="t('reporting.taxes.week.title')" data-test="taxes-week">
          <h3 class="tax-title">{{ t('reporting.taxes.week.title') }}</h3>
          <p v-if="!blocks.compared" class="muted" data-test="taxes-week-first">{{ t('reporting.taxes.week.first') }}</p>
          <template v-else>
            <p class="tax-summary" data-test="taxes-week-summary">
              {{ t('reporting.taxes.week.summary', { new: blocks.week.new, changed: blocks.week.changed }) }}
              <span class="muted">{{ t('reporting.taxes.week.compared', { time: isoDateTime(view.previous_taken_at) }) }}</span>
            </p>
            <p v-if="!blocks.week.byCategory.length" class="muted" data-test="taxes-week-none">{{ t('reporting.taxes.week.none') }}</p>
            <div v-for="g in blocks.week.byCategory" :key="g.category" class="tax-group" data-test="taxes-week-group" :data-category="g.category">
              <h4 class="tax-sub">{{ t('reporting.taxes.category.' + g.category) }}</h4>
              <ul class="tax-list">
                <li v-for="(d, i) in g.docs" :key="g.category + i" data-test="taxes-week-row" :data-status="d.status">
                  <span class="tax-flag">{{ t('reporting.taxes.status.' + d.status) }}</span>
                  <span class="tax-what">{{ d.kind }} · {{ d.doc_type }} · {{ d.tax_type }} · {{ d.period }}</span>
                </li>
              </ul>
            </div>
          </template>
          <div v-if="blocks.week.open.length" class="tax-group" data-test="taxes-open">
            <h4 class="tax-sub">{{ t('reporting.taxes.week.open') }}</h4>
            <ul class="tax-list">
              <li v-for="(d, i) in blocks.week.open" :key="'open' + i" data-test="taxes-open-row">
                <span class="num">{{ d.arrival_date }}</span>
                <span class="tax-what">{{ d.kind }} · {{ d.doc_type }} · {{ d.tax_type }} · {{ d.period }}</span>
              </li>
            </ul>
          </div>
        </section>

        <section class="tax-card" :aria-label="t('reporting.taxes.docs.title', { year })" data-test="taxes-docs">
          <h3 class="tax-title">{{ t('reporting.taxes.docs.title', { year }) }}</h3>
          <div class="tax-filters">
            <label class="tax-pick">
              <span>{{ t('reporting.taxes.filter.category') }}</span>
              <select v-model="category" data-test="taxes-filter-category">
                <option value="">{{ t('reporting.taxes.filter.all') }}</option>
                <option v-for="c in TAX_CATEGORIES" :key="c" :value="c">{{ t('reporting.taxes.category.' + c) }}</option>
              </select>
            </label>
            <label class="tax-pick">
              <span>{{ t('reporting.taxes.filter.tax_type') }}</span>
              <select v-model="taxType" data-test="taxes-filter-tax-type">
                <option value="">{{ t('reporting.taxes.filter.all') }}</option>
                <option v-for="x in blocks.taxTypes" :key="x" :value="x">{{ x }}</option>
              </select>
            </label>
          </div>
          <p v-if="!blocks.all.length" class="muted" data-test="taxes-docs-empty">{{ t('reporting.taxes.docs.empty') }}</p>
          <div v-else class="tax-table-wrap">
            <table class="tax-table" :aria-label="t('reporting.taxes.docs.title', { year })" data-test="taxes-docs-table">
              <thead>
                <tr>
                  <th scope="col">{{ t('reporting.taxes.col.arrival') }}</th>
                  <th scope="col">{{ t('reporting.taxes.col.kind') }}</th>
                  <th scope="col">{{ t('reporting.taxes.col.type') }}</th>
                  <th scope="col">{{ t('reporting.taxes.col.tax_type') }}</th>
                  <th scope="col">{{ t('reporting.taxes.col.period') }}</th>
                  <th scope="col">{{ t('reporting.taxes.col.due') }}</th>
                  <th scope="col">{{ t('reporting.taxes.col.category') }}</th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="(d, i) in blocks.all" :key="'doc' + i" data-test="taxes-doc" :data-category="d.category">
                  <td class="num" :data-label="t('reporting.taxes.col.arrival')">{{ d.arrival_date }}</td>
                  <td class="tax-what" :data-label="t('reporting.taxes.col.kind')">{{ d.kind }}</td>
                  <td :data-label="t('reporting.taxes.col.type')">{{ d.doc_type }}</td>
                  <td :data-label="t('reporting.taxes.col.tax_type')">{{ d.tax_type }}</td>
                  <td :data-label="t('reporting.taxes.col.period')">{{ d.period }}</td>
                  <td class="num" :data-label="t('reporting.taxes.col.due')">{{ d.due_date }}</td>
                  <td :data-label="t('reporting.taxes.col.category')">{{ t('reporting.taxes.category.' + d.category) }}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </template>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { TAX_CATEGORIES, TAX_OVERVIEW_PATH, taxBlocks, taxCall } from '~/utils/reporting-tax.mjs'

type Doc = { arrival_date: string, kind: string, doc_type: string, tax_type: string, period: string, due_date: string, category: string, status: string, due_soon: boolean, overdue: boolean, open_question: boolean }
type View = { tax_year: number, years: number[], taken_at: string, previous_taken_at: string, snapshot_id: string, documents: Doc[] }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as { mock?: boolean, base?: string }

const state = ref<'loading' | 'ready' | 'absent' | 'error'>('loading')
const view = ref<View | null>(null)
const category = ref('')
const taxType = ref('')

const years = computed(() => view.value?.years || [])
const year = computed(() => view.value?.tax_year || new Date().getUTCFullYear())
const blocks = computed(() => taxBlocks(view.value, { category: category.value, taxType: taxType.value }))

async function load(y?: number) {
  try {
    view.value = await taxCall(api, TAX_OVERVIEW_PATH + (y ? `?year=${y}` : '')) as View
    state.value = 'ready'
  } catch (e) {
    const status = (e as { status?: number })?.status
    /* one neutral line for every refusal: no other workspace learns more */
    state.value = status === 403 || status === 404 || status === 401 ? 'absent' : 'error'
  }
}

function pickYear(e: Event) {
  const y = Number((e.target as HTMLSelectElement).value)
  category.value = ''
  taxType.value = ''
  void load(y)
}

/* in the browser only: the prerendered page is the loading line */
onMounted(() => { void load() })
</script>

<style scoped>
.reporting-taxes { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.tax-error { color: var(--color-danger); margin: 0; }
.tax-head, .tax-filters { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
.tax-pick { display: inline-flex; align-items: center; gap: 6px; font-size: 0.875rem; }
.tax-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
  padding: 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
}
.tax-title { margin: 0; font-size: 1rem; font-weight: 600; }
.tax-sub { margin: 0; font-size: 0.875rem; font-weight: 600; }
.tax-summary { margin: 0; display: flex; flex-wrap: wrap; gap: 4px 12px; }
.tax-group { display: flex; flex-direction: column; gap: 4px; }
.tax-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; font-size: 0.875rem; }
.tax-list li { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; }
.tax-what { overflow-wrap: anywhere; min-width: 0; }
.num { white-space: nowrap; font-variant-numeric: tabular-nums; }
.tax-flag { display: inline-block; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); font-size: 0.75rem; white-space: nowrap; }
.tax-flag--warn { color: var(--color-warn); border-color: var(--color-warn); }
.tax-table-wrap { overflow-x: auto; max-width: 100%; }
.tax-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.tax-table th, .tax-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
/* a phone: each row is a card, its cells labelled (no sideways scroll) */
@media (max-width: 600px) {
  .tax-table thead { display: none; }
  .tax-table tr { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 12px; padding: 6px 0; border-bottom: 1px solid var(--color-border); }
  .tax-table th, .tax-table td { border-bottom: 0; padding: 0 4px; }
  .tax-table [data-label]:not(:empty)::before { content: attr(data-label) ": "; color: var(--color-muted); }
}
</style>
