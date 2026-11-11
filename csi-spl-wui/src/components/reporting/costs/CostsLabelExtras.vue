<!-- SPL-5312 (spec 143 costs-redesign.md 3.9): what a label shows under its
     table, kept from the pages before the four labels.
     Total, a single month: "n of N days complete" per source and the
     sources with no money yet (spec 123 5, SPL-2056).
     Tokens: the list price is never added to a cost (rule 3.1.1); Price per
     token, whose figures (each agent type's effective price per 1M tokens)
     live in Expenses -> AI costs, a link there; for an operator admin
     today's live fleet card (spec 140, its own chunk) and the estate's
     token burn per workspace over the period (spec 140 3.10). -->
<template>
  <template v-if="section === 'total' && single && views[0]">
    <ul v-if="empties.length" class="cle-empties" data-test="costs-empties">
      <li v-for="s in empties" :key="s" data-test="costs-empty-source" :data-source="s">{{ t('monitoring.costs.empty_source', { source: sourceLabel(s) }) }}</li>
    </ul>
    <section v-if="coverage.length" class="cle-coverage" data-test="costs-coverage">
      <h4>{{ t('monitoring.costs.coverage_title') }}</h4>
      <ul>
        <li v-for="c in coverage" :key="c.source" data-test="costs-coverage-row" :data-source="c.source" :data-complete="c.complete ? '1' : '0'">
          <span class="cle-source">{{ sourceLabel(c.source) }}</span>
          <span>{{ t('monitoring.costs.coverage_row', { n: c.ok, total: c.days }) }}</span>
          <span v-if="c.partial" class="cle-gap">{{ t('monitoring.costs.coverage_partial', { n: c.partial }) }}</span>
          <span v-if="c.missing" class="cle-gap">{{ t('monitoring.costs.coverage_missing', { n: c.missing }) }}</span>
          <span v-if="c.unrecorded" class="cle-gap">{{ t('monitoring.costs.coverage_unrecorded', { n: c.unrecorded }) }}</span>
        </li>
      </ul>
    </section>
  </template>
  <template v-if="section === 'tokens'">
    <p class="muted" data-test="costs-tokens-list-note">{{ t('reporting.costs.tokens.list_note') }}</p>
    <p data-test="costs-price-link"><NuxtLink :to="localePath('/expenses/ai')">{{ t('reporting.costs.price_link') }}</NuxtLink></p>
    <div v-if="reader" class="cle-slot"><TokensCostsCard /></div>
    <section v-if="burn.length" class="cle-burn" data-test="costs-workspaces">
      <h4>{{ t('monitoring.costs.workspaces_title') }}</h4>
      <div class="cle-wrap">
        <table class="cle-table">
          <thead>
            <tr>
              <th scope="col">{{ t('monitoring.costs.col_workspace') }}</th>
              <th scope="col">{{ t('monitoring.costs.col_vendor') }}</th>
              <th scope="col" class="num">{{ t('monitoring.costs.col_tokens') }}</th>
              <th scope="col" class="num">{{ t('monitoring.costs.col_list') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="w in burn" :key="w.key" data-test="costs-workspace-row" :data-workspace="w.workspace" :data-vendor="w.vendor">
              <td>{{ w.workspace }}</td>
              <td>{{ w.vendor }}</td>
              <td class="num">{{ costUnits(w.tokens, locale) }}</td>
              <td class="num">{{ w.listValueMicros ? costMoney(w.listValueMicros, 'USD', locale) : '' }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </template>
</template>

<script setup lang="ts">
import { useOperatorReader } from '~/composables/useOperatorReader'
import type { CostMonth } from '~/composables/useCostsPeriod'
import { costsWorkspaceBurn } from '~/utils/costs-labels.mjs'
import { costCoverageRows, costEmptySources, costMoney, costUnits } from '~/utils/tenant-costs.mjs'

const TokensCostsCard = defineAsyncComponent(() => import('@/components/monitoring/token-burn/TokensCostsCard.vue'))

const props = defineProps<{ section: string, views: CostMonth[], single: boolean }>()
const { t, te, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const reader = useOperatorReader()

const sourceLabel = (s: string) => (te('monitoring.costs.source.' + s) ? t('monitoring.costs.source.' + s) : s)
const empties = computed(() => (props.views[0] ? costEmptySources(props.views[0]) : []))
const coverage = computed(() => (props.views[0] ? costCoverageRows(props.views[0]) : []))
const burn = computed(() => costsWorkspaceBurn(props.views))
</script>

<style scoped>
.cle-empties { margin: 0; padding-left: 18px; color: var(--color-muted); }
.cle-coverage h4, .cle-burn h4 { font-size: 0.9375rem; margin: 0 0 6px; }
.cle-coverage ul { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
.cle-coverage li { display: flex; flex-wrap: wrap; gap: 4px 10px; }
.cle-source { font-weight: 600; }
.cle-gap { color: var(--color-warn); }
.cle-slot { display: contents; }
.cle-wrap { max-width: 100%; overflow-x: auto; }
.cle-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.cle-table th, .cle-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; }
.cle-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
</style>
