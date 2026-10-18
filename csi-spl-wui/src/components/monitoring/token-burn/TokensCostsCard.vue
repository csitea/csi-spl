<!-- Spec 140 (SPL-2322, owner HUM-10, t1 e8ae0aad, msgs 9c654846 / ea465d93:
     the owner looks for the token burn under Costs): one card on
     Monitoring -> Costs with today's fleet tokens and cost, linking to the
     Tokens tab. The costs page mounts it for an admin of the operator
     workspace only; any failure (the hub's 403 included) draws nothing. A
     cost with an unpriced lane in it says so, never a false total.
     SPL-2461 (owner HUM-10, t1 efd618b2, msg 5e9c69c4: grok "into the
     monitoring page costs tab"): one line per kind that used tokens today,
     a kind with no price (grok has none) "not priced", never $0.00. -->
<template>
  <NuxtLink v-if="view" class="tk-card" :to="localePath('/monitoring/tokens')" data-test="costs-tokens-card">
    <span class="tk-card-title">{{ t('monitoring.tokens.costs_card_title') }}</span>
    <span class="tk-card-body" data-test="costs-tokens-card-body">{{ t('monitoring.tokens.costs_card_body', { tokens: fmtTokens(view.summary.todayTokens, locale), cost: fmtMoney(view.summary.todayCost, view.currency, locale) }) }}</span>
    <span v-if="view.summary.unpriced || view.summary.unmetered" class="tk-card-note muted" data-test="costs-tokens-card-note">{{ t('monitoring.tokens.kpi_cost_sub', { active: view.summary.active, unmetered: view.summary.unmetered, unpriced: view.summary.unpriced }) }}</span>
    <ul v-if="kinds.length" class="tk-card-kinds">
      <li v-for="k in kinds" :key="k.vendor" data-test="costs-tokens-card-vendor" :data-vendor="k.vendor" :data-priced="k.priced ? '1' : '0'">
        <span class="tk-card-kind">{{ kindLabel(k.vendor) }}</span>
        <span data-test="costs-tokens-card-vendor-body">{{ t('monitoring.tokens.costs_card_body', { tokens: fmtTokens(k.tokens, locale), cost: k.priced ? fmtMoney(k.cost, view.currency, locale) : t('monitoring.tokens.not_priced') }) }}</span>
      </li>
    </ul>
    <span class="tk-card-link">{{ t('monitoring.tokens.costs_card_link') }} →</span>
  </NuxtLink>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { fleetTokensOf, fmtMoney, fmtTokens, tokensCardVendors } from '~/utils/monitoring-tokens.mjs'

type TokensApi = { getFleetTokens: (window?: string) => Promise<unknown> }

const { t, te, locale } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const view = ref<ReturnType<typeof fleetTokensOf> | null>(null)
const kinds = computed(() => (view.value ? tokensCardVendors(view.value) : []))
/* the agent kind labels the roster uses (agents.kinds.*), as the Tokens tab */
const kindLabel = (v: string) => (te('agents.kinds.' + v) ? t('agents.kinds.' + v) : v)

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
.tk-card-kinds { flex-basis: 100%; margin: 0; padding: 0; list-style: none; display: flex; flex-wrap: wrap; gap: 2px 16px; font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.tk-card-kind { font-weight: 600; margin-inline-end: 6px; }
</style>
