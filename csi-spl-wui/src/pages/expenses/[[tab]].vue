<!-- Spec 143 costs-redesign.md 3.8 (SPL-4382; owner HUM-10, t1 4f48f878,
     msg 4cea9710: "the Paid subscriptions and top-ups must become a separate
     costs section 0 level"; msg 50d84663: "at least 3 different tabs"): the
     Expenses section, a rail entry of its own beside Reporting. The sidebar
     keeps the icon rail only (ChannelSidebar expensesRailOnly); this page is
     the tab bar (one tab per cost type, utils/expenses-tabs.mjs) and the open
     tab. One route, /expenses/:tab?, so the entry chunk carries one router
     record, not four (ci_initial_gzip_kb sits on its ceiling); each tab's card
     is its own chunk, the wrappers keep the async components off a bare v-if.
     The bar reuses the Reporting bar's look. The operator workspace's admins,
     and read only its product owners (SPL-5181), biz_owners and internal
     accountants (SPL-5420, useExpensesReader; hiding only, the hub's 403 is
     the control); /expenses itself, or a tab that does not
     exist, lands on AI costs, in the browser only. -->
<template>
  <div class="feed-col expenses-page" data-test="expenses-page">
    <header class="feed-header">
      <MobileBack />
      <h2 class="section-title" data-test="expenses-heading">{{ t('sidebar.expenses') }}</h2>
      <!-- the tab bar on the heading's row, as Reporting's (SPL-4811, main.css .section-title-sep) -->
      <span class="section-title-sep" aria-hidden="true" data-test="expenses-title-sep">{{ '  >>  ' }}</span>
      <nav class="reporting-tabs" :aria-label="t('expenses.tabs_label')" data-test="expenses-tabs">
        <NuxtLink
          v-for="tab in tabs"
          :key="tab.id"
          :to="localePath(tab.path)"
          class="reporting-tab"
          :class="{ 'reporting-tab--active': active === tab.id }"
          :aria-current="active === tab.id ? 'page' : undefined"
          :data-test="'expenses-tab-' + tab.id"
        >{{ t(tab.labelKey) }}</NuxtLink>
      </nav>
    </header>
    <div class="feed-body expenses-body">
      <p v-if="!reader && !writer" class="muted" data-test="expenses-operators-only">{{ t('expenses.operators_only') }}</p>
      <section v-else-if="active === 'ai'" data-test="expenses-ai">
        <div class="tk-lazy"><PaidItemsCard :readonly="!operator.visible" /></div>
      </section>
      <div v-else-if="entryType" class="tk-lazy"><CostEntriesCard :key="entryType" :type="entryType" :readonly="!operator.visible && !writer" :admin="operator.visible" /></div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'
import { useExpensesReader } from '~/composables/useExpensesReader'
import { useCostWriter } from '~/composables/useOperatorReader'
import { EXPENSES_DEFAULT_PATH, expensesTabFor, visibleExpensesTabs } from '~/utils/expenses-tabs.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const operator = useOperatorPane()
const reader = useExpensesReader()
/* SPL-5433: a costs.write member of the operator workspace (the accountants) enters Cloud infra and HR */
const writer = useCostWriter()

const tabs = computed(() => visibleExpensesTabs({ operator: reader.value, costs: writer.value }))
const active = computed(() => expensesTabFor(route.path))
const entryType = computed(() => (active.value === 'cloud' || active.value === 'hr' ? active.value : null))
const PaidItemsCard = defineAsyncComponent(() => import('~/components/monitoring/token-burn/PaidItemsCard.vue'))
const CostEntriesCard = defineAsyncComponent(() => import('~/components/expenses/CostEntriesCard.vue'))

onMounted(() => {
  watch(() => [route.path, writer.value] as const, ([path]) => {
    const p = String(path)
    const here = productPath(p)
    if ((here === '/expenses' || here.startsWith('/expenses/')) && !expensesTabFor(p)) void navigateTo({ path: localePath(EXPENSES_DEFAULT_PATH), query: route.query }, { replace: true })
    /* an accountant who is no operator reader lands on the first tab they see (HR or Cloud), not on AI costs */
    else if (!reader.value && writer.value && active.value && !tabs.value.some((x) => x.id === active.value) && tabs.value.length) void navigateTo({ path: localePath(tabs.value[0].path), query: route.query }, { replace: true })
  }, { immediate: true })
})
</script>

<style scoped>
/* top and sides only: the shell's padding-bottom keeps the last row clear of the phone's composer dock (main.css, .spool-shell .feed-body) */
.expenses-body { padding-block-start: 16px; padding-inline: 16px; display: flex; flex-direction: column; gap: 12px; }
.tk-lazy { display: contents; }
</style>
