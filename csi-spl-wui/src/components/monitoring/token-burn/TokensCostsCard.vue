<!-- Spec 140 (SPL-2322, owner HUM-10, t1 e8ae0aad, msgs 9c654846 / ea465d93:
     the owner looks for the token burn under Costs): one card on
     Monitoring -> Costs with today's fleet tokens and cost, linking to the
     Tokens tab. The costs page mounts it for an admin of the operator
     workspace only; any failure (the hub's 403 included) draws nothing. A
     cost with an unpriced lane in it says so, never a false total. -->
<template>
  <NuxtLink v-if="view" class="tk-card" :to="localePath('/monitoring/tokens')" data-test="costs-tokens-card">
    <span class="tk-card-title">{{ t('monitoring.tokens.costs_card_title') }}</span>
    <span class="tk-card-body" data-test="costs-tokens-card-body">{{ t('monitoring.tokens.costs_card_body', { tokens: fmtTokens(view.summary.todayTokens, locale), cost: fmtMoney(view.summary.todayCost, view.currency, locale) }) }}</span>
    <span v-if="view.summary.unpriced || view.summary.unmetered" class="tk-card-note muted" data-test="costs-tokens-card-note">{{ t('monitoring.tokens.kpi_cost_sub', { active: view.summary.active, unmetered: view.summary.unmetered, unpriced: view.summary.unpriced }) }}</span>
    <span class="tk-card-link">{{ t('monitoring.tokens.costs_card_link') }} →</span>
  </NuxtLink>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { fleetTokensOf, fmtMoney, fmtTokens } from '~/utils/monitoring-tokens.mjs'

type TokensApi = { getFleetTokens: (window?: string) => Promise<unknown> }

const { t, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const view = ref<ReturnType<typeof fleetTokensOf> | null>(null)

onMounted(async () => {
  try {
    view.value = fleetTokensOf(await (useSpoolApi() as unknown as TokensApi).getFleetTokens('today'))
  } catch {
    view.value = null
  }
})
</script>

<style scoped>
.tk-card { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 12px; padding: 10px 12px; border: 1px solid var(--color-border); border-radius: var(--radius-md); color: inherit; text-decoration: none; }
.tk-card:hover { background: var(--color-surface-hover); }
.tk-card-title { font-weight: 600; }
.tk-card-body { font-variant-numeric: tabular-nums; }
.tk-card-note { font-size: 0.8125rem; }
.tk-card-link { margin-inline-start: auto; color: var(--color-accent); white-space: nowrap; }
</style>
