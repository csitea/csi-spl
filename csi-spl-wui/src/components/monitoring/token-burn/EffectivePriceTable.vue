<!-- Spec 140 3.8 (SPL-2567): the effective price per token per vendor, as
     GET /v1/operator/fleet-tokens/effective answers it, beside the
     list-price one of the same days. A vendor with paid items but no tokens
     logged (agy) says "not metered" with its daily share; cache reads stay
     their own column, never divided in (the hub's rule). A vendor with
     tokens but a list cost of 0 has no price held (grok): "not priced". -->
<template>
  <section class="tk-section" data-test="paid-effective">
    <h3>{{ t('monitoring.tokens.paid.effective_title') }}</h3>
    <p v-if="view.from" class="muted pd-range" data-test="paid-effective-range">{{ t('monitoring.tokens.paid.effective_range', { days: view.days, from: view.from, to: view.to }) }}</p>
    <div class="tk-table-wrap">
      <table class="tk-table">
        <thead>
          <tr>
            <th scope="col">{{ t('monitoring.tokens.col_vendor') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_list_mtok') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_eff_mtok') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_paid') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_paid_day') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_tokens') }}</th>
            <th scope="col" class="num">{{ t('monitoring.tokens.paid.col_cache') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="v in view.vendors" :key="v.vendor" data-test="paid-effective-row" :data-vendor="v.vendor" :data-status="v.status">
            <th scope="row">{{ kindLabel(v.vendor) }}</th>
            <td class="num" :data-label="t('monitoring.tokens.paid.col_list_mtok')" data-test="paid-eff-list">
              <span v-if="!v.listPriced" class="tk-unpriced" :title="t('monitoring.tokens.not_priced_title')" data-test="paid-eff-not-priced">{{ t('monitoring.tokens.not_priced') }}</span>
              <template v-else>{{ fmtPerMTok(v.listPerMTok, locale) }}</template>
            </td>
            <td class="num" :data-label="t('monitoring.tokens.paid.col_eff_mtok')" data-test="paid-eff-value">
              <span v-if="v.status === 'effective'">{{ fmtPerMTok(v.effectivePerMTok, locale) }}</span>
              <span v-else class="tk-badge" :class="{ 'tk-badge--warn': v.status !== 'list_only' }" data-test="paid-eff-status">{{ t('monitoring.tokens.paid.status_' + v.status) }}</span>
            </td>
            <td class="num" :data-label="t('monitoring.tokens.paid.col_paid')" data-test="paid-eff-paid">{{ fmtMoney(v.paidUSD, 'USD', locale) }}</td>
            <td class="num" :data-label="t('monitoring.tokens.paid.col_paid_day')" data-test="paid-eff-day">{{ fmtMoney(v.paidPerDayUSD, 'USD', locale) }}</td>
            <td class="num" :data-label="t('monitoring.tokens.paid.col_tokens')">{{ fmtTokens(v.tokens, locale) }}</td>
            <td class="num" :data-label="t('monitoring.tokens.paid.col_cache')">{{ fmtTokens(v.cacheRead, locale) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>

<script setup lang="ts">
import { fmtMoney, fmtTokens } from '~/utils/monitoring-tokens.mjs'
import { fmtPerMTok, paidEffectiveOf } from '~/utils/monitoring-paid.mjs'

defineProps<{ view: ReturnType<typeof paidEffectiveOf> }>()
const { t, te, locale } = useI18n({ useScope: 'global' })
const kindLabel = (v: string) => {
  const k = 'agents.kinds.' + (v === 'agy' ? 'antigravity' : v)
  return te(k) ? t(k) : v
}
</script>

<style scoped src="./token-burn.css"></style>
<style scoped>
.pd-range { margin: 0 0 6px; font-size: 0.8125rem; }
</style>
