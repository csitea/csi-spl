<!-- Spec 140 4.2 T031 (SPL-2322): the Tokens tab's KPI strip. The fleet burn
     rate (all tokens/min, fresh tokens/min, cost per hour), today's tokens
     with the cache hit %, today's cost, and the live lane counts (not
     metered = agy, not priced = a model the hub holds no price for). A
     missing figure is a dash, never NaN or a false 0. -->
<template>
  <div class="tk-kpis" data-test="tokens-kpis">
    <section class="tk-kpi" data-test="tokens-kpi-rate">
      <h3>{{ t('monitoring.tokens.kpi_rate') }}</h3>
      <i18n-t keypath="monitoring.tokens.per_min" tag="p" scope="global" class="tk-kpi-value tk-kpi-value--unit" data-test="tokens-kpi-rate-value"><template #n><span class="tk-kpi-num">{{ tokens(summary.rate) }}</span></template></i18n-t>
      <p class="tk-kpi-sub muted">{{ t('monitoring.tokens.kpi_rate_sub', { fresh: tokens(summary.fresh), cost: money(summary.costPerHour) }) }}</p>
    </section>
    <section class="tk-kpi" data-test="tokens-kpi-today">
      <h3>{{ t('monitoring.tokens.kpi_today') }}</h3>
      <p class="tk-kpi-value" data-test="tokens-kpi-today-value">{{ tokens(summary.todayTokens) }}</p>
      <p class="tk-kpi-sub muted">{{ t('monitoring.tokens.kpi_today_sub', { pct: hit === null ? '—' : hit }) }}</p>
    </section>
    <section class="tk-kpi" data-test="tokens-kpi-cost">
      <h3>{{ t('monitoring.tokens.kpi_cost') }}</h3>
      <p class="tk-kpi-value" data-test="tokens-kpi-cost-value">{{ money(summary.todayCost) }}</p>
      <p class="tk-kpi-sub muted" data-test="tokens-kpi-lanes">{{ t('monitoring.tokens.kpi_cost_sub', { active: summary.active, unmetered: summary.unmetered, unpriced: summary.unpriced }) }}</p>
    </section>
  </div>
</template>

<script setup lang="ts">
import { cacheHitPct, fmtMoney, fmtTokens } from '~/utils/monitoring-tokens.mjs'

type Summary = {
  rate: number | null, fresh: number | null, costPerHour: number | null,
  todayTokens: number | null, todayCacheRead: number | null, todayCost: number | null,
  active: number, unmetered: number, unpriced: number,
}
const props = defineProps<{ summary: Summary, currency: string }>()
const { t, locale } = useI18n({ useScope: 'global' })
const tokens = (n: number | null) => fmtTokens(n, locale.value)
const money = (n: number | null) => fmtMoney(n, props.currency, locale.value)
const hit = computed(() => cacheHitPct(props.summary.todayCacheRead, props.summary.todayTokens))
</script>

<style scoped>
.tk-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 12px; }
.tk-kpi { border: 1px solid var(--color-border); border-radius: var(--radius-md, 8px); padding: 10px 12px; min-width: 0; }
.tk-kpi h3 { margin: 0 0 4px; font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); }
.tk-kpi-value { margin: 0; font-size: 1.375rem; font-weight: 700; font-variant-numeric: tabular-nums; }
.tk-kpi-sub { margin: 2px 0 0; font-size: 0.8125rem; overflow-wrap: anywhere; }
/* Row 04 of tokens-tab-panel-plan.md: on a phone the three cards sit side
   by side (351px stacked -> under 115px), each subtitle one line. The rate's
   unit shrinks to subtitle size. SPL-2485: a value never wraps or spills
   (fi "113,3 t./minuutti", "19,35 milj." at 360px), so the rate tile is the
   widest, the cost tile the narrowest, and a heading wraps at 0.75rem.
   SPL-2589: the columns follow what each tile needs in fi at 360px under a
   wider fallback font too (DejaVu Sans: the rate figure 130px, the word
   "kustannus" 78px), so no tile is cut to its last 3px. */
@media (max-width: 600px) {
  .tk-kpis { grid-template-columns: minmax(0, 1.38fr) minmax(0, 1.03fr) minmax(0, 0.89fr); gap: 4px; }
  .tk-kpi { padding: 6px 3px; }
  .tk-kpi h3 { margin-bottom: 2px; font-size: 0.75rem; line-height: 1.2; }
  .tk-kpi-value { font-size: 0.8125rem; line-height: 1.25; white-space: nowrap; }
  .tk-kpi-value--unit { font-size: 0.6875rem; }
  .tk-kpi-num { font-size: 0.8125rem; }
  .tk-kpi-sub { line-height: 1.25; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
}
</style>
