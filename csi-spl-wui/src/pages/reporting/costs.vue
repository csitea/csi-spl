<!-- Spec 143 costs-redesign.md 3.2, slice S1 (SPL-3798, owner HUM-10, t1
     1be0e370, msg 3f1c7128, answer 6 A): Reporting -> Costs, one tab with
     four pages, each its own path and chunk (utils/reporting-costs.mjs):
     Spend (default), Tokens, Price per token and Paid items (the last two
     drawn for an operator admin only; hiding only, the hub's 403 is the
     control). The header's month and currency ride in the query, kept
     across the page bar. /reporting/costs itself lands on Spend, in the
     browser only, so the prerendered page is the bar, never a redirect. -->
<template>
  <div class="reporting-costs" data-test="reporting-costs">
    <nav class="costs-pages" :aria-label="t('reporting.costs.pages_label')" data-test="costs-pages">
      <NuxtLink
        v-for="page in pages"
        :key="page.id"
        :to="{ path: localePath(page.path), query: carried }"
        class="costs-page-link"
        :class="{ 'costs-page-link--active': active === page.id }"
        :aria-current="active === page.id ? 'page' : undefined"
        :data-test="'costs-page-' + page.id"
      >{{ t(page.labelKey) }}</NuxtLink>
    </nav>
    <CostsHeader />
    <NuxtPage />
  </div>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'
import CostsHeader from '~/components/reporting/costs/CostsHeader.vue'
import { costsPageFor, legacyCostsPath, visibleCostsPages } from '~/utils/reporting-costs.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const operator = useOperatorPane()

const pages = computed(() => visibleCostsPages({ operator: operator.visible }))
const active = computed(() => costsPageFor(route.path))
/* the header's picks travel with the page bar */
const carried = computed(() => {
  const q: Record<string, string> = {}
  for (const k of ['month', 'currency']) if (typeof route.query[k] === 'string') q[k] = route.query[k] as string
  return q
})

onMounted(() => {
  watch(() => route.path, (p) => {
    const to = costsPageFor(p) ? null : legacyCostsPath(p)
    if (to) void navigateTo({ path: localePath(to), query: route.query, hash: route.hash }, { replace: true })
  }, { immediate: true })
})
</script>
