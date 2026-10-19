<!-- Spec 140 4.2 + 4.4.1 T032 (SPL-2322): token burn per agent type. Live
     lanes, tokens/min with the burn badge (fresh tokens: elevated from 30k,
     surge above 60k), today's tokens and cost, the status. agy reports no
     tokens: its row is the "Not metered" badge and dashes, never a 0; a kind
     with an unpriced lane says "not priced" for its cost. -->
<template>
  <section class="tk-section" data-test="tokens-vendors">
    <h3>{{ t('monitoring.tokens.vendors_title') }}</h3>
    <div class="tk-table-wrap">
      <table class="tk-table">
        <thead>
          <tr>
            <th scope="col">{{ t('monitoring.tokens.col_vendor') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.col_active') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.col_rate') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.col_today') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.col_cost') }}</th>
            <th scope="col">{{ t('monitoring.tokens.col_status') }}</th>
          </tr>
        </thead>
        <tbody>
          <template v-for="v in vendors" :key="v.vendor">
            <!-- a phone (SPL-2486): an unmetered kind or one with no burn is one muted line; the figures stay in the row, never a 0 for agy -->
            <tr v-if="folded(v)" class="tk-vfold" data-test="tokens-vendor-row" :data-vendor="v.vendor" :data-status="v.status">
              <th scope="row" colspan="6">
                {{ kindLabel(v.vendor) }} · {{ t('monitoring.tokens.col_active') }}: {{ v.active }}
                <span v-if="!v.metered" class="tk-badge tk-badge--warn" :title="t('monitoring.tokens.not_metered_title')" data-test="tokens-not-metered">{{ t('monitoring.tokens.status_not_metered') }}</span>
                <span v-else class="tk-badge">{{ t('monitoring.tokens.status_idle') }}</span>
                <span hidden data-test="tokens-vendor-today">{{ v.metered ? tokens(v.todayTokens) : '—' }}</span>
                <span hidden data-test="tokens-vendor-cost">{{ v.metered ? money(v.todayCost) : '—' }}</span>
              </th>
            </tr>
            <tr v-else class="tk-vrow" data-test="tokens-vendor-row" :data-vendor="v.vendor" :data-status="v.status">
              <th scope="row">{{ kindLabel(v.vendor) }}</th>
              <td class="num tk-vlive" :data-label="t('monitoring.tokens.col_active')">{{ v.active }}</td>
              <td class="num tk-vfig" :data-label="t('monitoring.tokens.col_rate')" data-test="tokens-vendor-rate">
                <i18n-t keypath="monitoring.tokens.per_min" tag="span" scope="global" class="tk-rate"><template #n><span class="tk-rate-num">{{ tokens(v.rate) }}</span></template></i18n-t>
                <BurnBadge :level="burnLevel(v.fresh)" />
              </td>
              <td class="num tk-vfig" :data-label="t('monitoring.tokens.col_today')" :title="t('monitoring.tokens.col_today')" data-test="tokens-vendor-today">{{ tokens(v.todayTokens) }}</td>
              <td class="num tk-vfig" :data-label="t('monitoring.tokens.col_cost')" data-test="tokens-vendor-cost">
                <span v-if="!v.priced" class="tk-unpriced" :title="t('monitoring.tokens.not_priced_title')" data-test="tokens-not-priced">{{ t('monitoring.tokens.not_priced') }}</span>
                <template v-else>{{ money(v.todayCost) }}</template>
              </td>
              <td class="tk-vstatus" :data-label="t('monitoring.tokens.col_status')">
                <span class="tk-badge" :class="{ 'tk-badge--on': v.status === 'metered' }">{{ t(v.status === 'metered' ? 'monitoring.tokens.status_metered' : 'monitoring.tokens.status_idle') }}</span>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
    </div>
  </section>
</template>

<script setup lang="ts">
import { burnLevel, fmtMoney, fmtTokens } from '~/utils/monitoring-tokens.mjs'
import BurnBadge from './BurnBadge.vue'

type Vendor = { vendor: string, active: number, rate: number | null, fresh: number | null, todayTokens: number | null, todayCost: number | null, metered: boolean, status: string, priced: boolean }
const props = defineProps<{ vendors: Vendor[], currency: string }>()
const { t, te, locale } = useI18n({ useScope: 'global' })
const tokens = (n: number | null) => fmtTokens(n, locale.value)
const money = (n: number | null) => fmtMoney(n, props.currency, locale.value)
/* the agent kind labels the roster uses (agents.kinds.*); agy is antigravity there */
const kindLabel = (v: string) => {
  const k = 'agents.kinds.' + (v === 'agy' ? 'antigravity' : v)
  return te(k) ? t(k) : v
}
/* folded to one line: never metered (agy), or metered with no burn and no tokens today (an idle qwen) */
const folded = (v: Vendor) => !v.metered || (!v.active && !v.rate && !v.todayTokens)
</script>

<style scoped src="./token-burn.css"></style>
<style scoped>
/* SPL-2486: on a phone an active kind is a two-line card (name, live, status;
   then rate, today's tokens, cost), and a folded kind is one muted line */
.tk-vfold th { font-weight: 400; color: var(--color-muted); }
@media (max-width: 600px) {
  .tk-table tr.tk-vrow { display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 6px; }
  .tk-table tr.tk-vrow > th { flex: 1 1 auto; order: 0; }
  .tk-table tr.tk-vrow > .tk-vlive { order: 1; }
  .tk-table tr.tk-vrow > .tk-vstatus { order: 2; }
  .tk-table tr.tk-vrow::after { content: ''; flex-basis: 100%; height: 0; order: 3; }
  /* the three figures stay one line in fi at 360px (SPL-2486: the cost fell to a third line, 90px) */
  .tk-table tr.tk-vrow > .tk-vfig { order: 4; padding: 0 1px; font-size: 0.8125rem; white-space: nowrap; }
  .tk-table tr.tk-vrow .tk-rate { font-size: 0.6875rem; }
  .tk-table tr.tk-vrow .tk-rate-num { font-size: 0.8125rem; }
  .tk-table tr.tk-vrow > .tk-vfig::before { content: none; }
  .tk-table tr.tk-vrow > .tk-vfig + .tk-vfig::before { content: '· '; color: var(--color-muted); }
  .tk-table tr.tk-vrow > .tk-vstatus::before { content: none; }
  .tk-table tr.tk-vfold { display: block; padding: 4px 0; }
  .tk-table tr.tk-vfold th { font-size: 0.8125rem; }
}
</style>
