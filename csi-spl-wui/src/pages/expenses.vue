<!-- Spec 143 costs-redesign.md 3.8 (SPL-4382; owner HUM-10, t1 4f48f878,
     msg 4cea9710: "the Paid subscriptions and top-ups must become a separate
     costs section 0 level"; msg 50d84663: "at least 3 different tabs"): the
     Expenses section, a rail entry of its own beside Reporting. The sidebar
     keeps the icon rail only (ChannelSidebar expensesRailOnly); this page is
     the tab bar (one tab per cost type, utils/expenses-tabs.mjs) and the open
     tab as a child route. The bar reuses the Reporting bar's look. Operator
     admins only (hiding only, the hub's 403 is the control); /expenses itself
     lands on AI costs, in the browser only, so the prerendered page is the
     bar, never a redirect. -->
<template>
  <div class="feed-col expenses-page" data-test="expenses-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="expenses-heading">{{ t('sidebar.expenses') }}</h2>
      <SectionClose side="end" />
    </header>
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
    <div class="feed-body expenses-body">
      <p v-if="!operator.visible" class="muted" data-test="expenses-operators-only">{{ t('expenses.operators_only') }}</p>
      <NuxtPage v-else />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'
import { EXPENSES_DEFAULT_PATH, expensesTabFor, visibleExpensesTabs } from '~/utils/expenses-tabs.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const operator = useOperatorPane()

const tabs = computed(() => visibleExpensesTabs({ operator: operator.visible }))
const active = computed(() => expensesTabFor(route.path))

onMounted(() => {
  watch(() => route.path, (p) => {
    if (productPath(p) === '/expenses') void navigateTo({ path: localePath(EXPENSES_DEFAULT_PATH), query: route.query }, { replace: true })
  }, { immediate: true })
})
</script>

<style scoped>
.expenses-body { padding: 16px; display: flex; flex-direction: column; gap: 12px; }
</style>
