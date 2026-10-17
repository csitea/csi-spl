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
          <tr v-for="v in vendors" :key="v.vendor" data-test="tokens-vendor-row" :data-vendor="v.vendor" :data-status="v.status">
            <th scope="row">{{ kindLabel(v.vendor) }}</th>
            <td class="num" :data-label="t('monitoring.tokens.col_active')">{{ v.active }}</td>
            <td class="num" :data-label="t('monitoring.tokens.col_rate')" data-test="tokens-vendor-rate">
              {{ v.metered ? t('monitoring.tokens.per_min', { n: tokens(v.rate) }) : '—' }}
              <BurnBadge :level="burnLevel(v.fresh)" />
            </td>
            <td class="num" :data-label="t('monitoring.tokens.col_today')" data-test="tokens-vendor-today">{{ v.metered ? tokens(v.todayTokens) : '—' }}</td>
            <td class="num" :data-label="t('monitoring.tokens.col_cost')" data-test="tokens-vendor-cost">
              <span v-if="!v.metered">—</span>
              <span v-else-if="!v.priced" class="tk-unpriced" :title="t('monitoring.tokens.not_priced_title')" data-test="tokens-not-priced">{{ t('monitoring.tokens.not_priced') }}</span>
              <template v-else>{{ money(v.todayCost) }}</template>
            </td>
            <td :data-label="t('monitoring.tokens.col_status')">
              <span v-if="!v.metered" class="tk-badge tk-badge--warn" :title="t('monitoring.tokens.not_metered_title')" data-test="tokens-not-metered">{{ t('monitoring.tokens.status_not_metered') }}</span>
              <span v-else class="tk-badge" :class="{ 'tk-badge--on': v.status === 'metered' }">{{ t(v.status === 'metered' ? 'monitoring.tokens.status_metered' : 'monitoring.tokens.status_idle') }}</span>
            </td>
          </tr>
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
</script>

<style scoped src="./token-burn.css"></style>
