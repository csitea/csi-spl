<!-- SPL-4187 (spec 123 5.5; owner HUM-10, t1 e2c0e6b4, msg 81217a3f): Reporting
     -> Costs -> AI tokens, a section of its own (was the S1 shell, spec 143
     costs-redesign.md 3.4). The month read's token parts (GET
     /v1/tenant/costs: fleet_tokens per box, the estate's ai_paid
     subscriptions, a customer workspace's ai_share): the tokens, what was
     paid in the header's currency, and the list price beside it, never
     added (spec 123 13.3). Every member sees its own workspace's (owner
     t1 1be0e370 msg 3f1c7128 answer 1 A); the operator admin also gets
     today's live fleet card (its own chunk). -->
<template>
  <section class="costs-tokens" data-test="costs-tokens">
    <h3>{{ t('reporting.costs.tokens.title') }}</h3>
    <div v-if="operator.visible" class="costs-tokens-slot"><TokensCostsCard /></div>

    <p v-if="state === 'loading'" class="muted" data-test="costs-tokens-loading">{{ t('monitoring.costs.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="tokens-error" data-test="costs-forbidden">{{ t('monitoring.costs.forbidden', { perm: COSTS_READ }) }}</p>
    <p v-else-if="state === 'error'" class="tokens-error" data-test="costs-tokens-error">{{ t('monitoring.costs.error') }}</p>
    <template v-else>
      <p class="muted" data-test="costs-tokens-list-note">{{ t('reporting.costs.tokens.list_note') }}</p>
      <div class="tokens-table-wrap">
        <table class="tokens-table" data-test="costs-tokens-table">
          <thead>
            <tr>
              <th scope="col">{{ t('monitoring.costs.col_part') }}</th>
              <th scope="col" class="num">{{ t('monitoring.costs.col_tokens') }}</th>
              <th scope="col" class="num" data-test="costs-tokens-currency">{{ currency }}</th>
              <th scope="col" class="num">{{ t('monitoring.costs.col_list') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="p in rows" :key="p.key" data-test="costs-tokens-row" :data-source="p.source">
              <td>
                <span class="tokens-part">{{ p.label }}</span>
                <span class="tokens-kind muted">{{ p.kind }}</span>
              </td>
              <td class="num">{{ p.units }}</td>
              <td class="num" :title="p.amount.title">{{ p.amount.text }}</td>
              <td class="num">{{ p.list }}</td>
            </tr>
            <tr v-if="!rows.length">
              <td colspan="4" class="muted" data-test="costs-tokens-empty">{{ t('reporting.costs.tokens.empty') }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { useOperatorPane } from '~/stores/operator-pane'
import { costsCurrency, costsCurrencyOptions, costsMonth, costsMonthOptions } from '~/utils/reporting-costs.mjs'
import { COSTS_READ, costMoney, costMonthOf, costPartKey, costUnits } from '~/utils/tenant-costs.mjs'
import { sectionAmount, tokenParts } from '~/utils/costs-sections.mjs'

/* today's fleet card is its own chunk, as on Spend */
const TokensCostsCard = defineAsyncComponent(() => import('@/components/monitoring/token-burn/TokensCostsCard.vue'))

type CostsApi = { getTenantCosts: (month?: string, secondCurrency?: string) => Promise<unknown> }

const { t, te, locale } = useI18n({ useScope: 'global' })
const route = useRoute()
const session = useSessionStore()
const operator = useOperatorPane()
const pick = computed(() => String(session.claims?.second_currency || ''))
const current = costsMonthOptions(new Date())[0]
const month = computed(() => { const m = costsMonth(route.query.month); return m === current ? '' : m })
const currency = computed(() => costsCurrency(route.query.currency, costsCurrencyOptions(pick.value)))
const view = ref<ReturnType<typeof costMonthOf> | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')

/* fleet_tokens.<box> reads as "Fleet tokens · <box>" */
function sourceLabel(s: string) {
  const [head, box] = [s.split('.')[0], s.split('.').slice(1).join('.')]
  const name = te('monitoring.costs.source.' + head) ? t('monitoring.costs.source.' + head) : head
  return box ? `${name} · ${box}` : name
}
const rows = computed(() => tokenParts(view.value?.parts || []).map((p) => {
  const v = sectionAmount(p, currency.value)
  return {
    key: costPartKey(p),
    source: p.source,
    kind: p.kind,
    label: `${sourceLabel(p.source)} · ${p.projectOrVendor || '-'}`,
    units: costUnits(p.units, locale.value),
    amount: v === null || v === undefined
      ? { text: '—', title: t('monitoring.costs.second_none', { currency: currency.value }) }
      : { text: costMoney(v, currency.value, locale.value), title: undefined },
    list: p.listValueMicros ? costMoney(p.listValueMicros, 'USD', locale.value) : '',
  }
}))

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  try {
    const body = await (useSpoolApi() as unknown as CostsApi).getTenantCosts(month.value, pick.value)
    if (mine !== seq) return
    view.value = costMonthOf(body)
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    state.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
  }
}

onMounted(() => {
  watch(() => [month.value, pick.value], () => { void load() }, { immediate: true })
})
</script>

<style scoped>
.costs-tokens { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.costs-tokens h3 { margin: 0; font-size: 1rem; }
.costs-tokens-slot { display: contents; }
.tokens-error { color: var(--color-danger); }
.tokens-table-wrap { max-width: 100%; overflow-x: auto; }
.tokens-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.tokens-table th, .tokens-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.tokens-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.tokens-part { overflow-wrap: anywhere; }
.tokens-kind { display: block; font-size: 0.75rem; }
</style>
