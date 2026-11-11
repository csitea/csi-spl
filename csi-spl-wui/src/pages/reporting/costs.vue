<!-- Spec 143 costs-redesign.md 3.2, slice S1 (SPL-3798, owner HUM-10, t1
     1be0e370, msg 3f1c7128, answer 6 A): Reporting -> Costs, one tab with
     its pages, each its own path and chunk (utils/reporting-costs.mjs).
     The header's month and currency ride in the query, kept
     across the page bar. /reporting/costs itself lands on Total, in the
     browser only, so the prerendered page is the bar, never a redirect.
     SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806):
     the bar is the four labels, Total (default), Persons, Cloud, Tokens,
     each for every costs reader; the header's period is a month or the
     year to date. The pages before them redirect to their label. -->
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
import { useOperatorReader } from '~/composables/useOperatorReader'
import CostsHeader from '~/components/reporting/costs/CostsHeader.vue'
import { costsPageFor, legacyCostsPath, visibleCostsPages } from '~/utils/reporting-costs.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const reader = useOperatorReader()

const pages = computed(() => visibleCostsPages({ operator: reader.value }))
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
