<!-- Spec 143 costs-redesign.md 3.2, slice S1 (SPL-3798, owner HUM-10, t1
     1be0e370, msg 3f1c7128, answer 6 A): Reporting -> Costs, one tab with
     its pages, each its own path and chunk (utils/reporting-costs.mjs).
     The header's month and currency ride in the query, kept
     across the page bar. /reporting/costs itself lands on the first page, in the
     browser only, so the prerendered page is the bar, never a redirect.
     SPL-5312 (spec 143 costs-redesign.md 3.9; owner HUM-10, t1 41a74806):
     the bar is the four labels, Total (default), Persons, Cloud, Tokens,
     each for every costs reader; the header's period is a month or the
     year to date. The pages before them redirect to their label.
     Spec 123 P05 (SPL-6117; owner HUM-10, t1 e2c0e6b4, msg 3a795cdb, Q-9
     A): the project's cost is the first label and the default, Total
     second; /reporting/costs lands on it. SPL-6300: the header's month
     range (`from`, `to`) travels with the bar too. SPL-6438 (spec 143
     taxes-tab.md section 6): Taxes is drawn only after the tax overview
     read answered 2xx (the tax workspace's persons); the header's period
     and currency do not apply to it and are hidden there. -->
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
    <CostsHeader v-if="costsHeaderApplies(active)" />
    <NuxtPage />
  </div>
</template>

<script setup lang="ts">
import { useOperatorReader } from '~/composables/useOperatorReader'
import CostsHeader from '~/components/reporting/costs/CostsHeader.vue'
import { costsHeaderApplies, costsPageFor, legacyCostsPath, visibleCostsPages } from '~/utils/reporting-costs.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const reader = useOperatorReader()

const taxReader = ref(false)
const api = useSpoolApi() as unknown as { mock?: boolean, base?: string }
const pages = computed(() => visibleCostsPages({ operator: reader.value, taxReader: taxReader.value }))
const active = computed(() => costsPageFor(route.path))
/* the header's picks travel with the page bar */
const carried = computed(() => {
  const q: Record<string, string> = {}
  for (const k of ['month', 'from', 'to', 'currency']) if (typeof route.query[k] === 'string') q[k] = route.query[k] as string
  return q
})

onMounted(() => {
  /* the Taxes label: its own chunk, asked once per page load and hub base */
  void import('~/utils/reporting-tax.mjs')
    .then(({ taxReaderProbe }) => taxReaderProbe(api))
    .then((yes) => { taxReader.value = yes }, () => { taxReader.value = false })
  watch(() => route.path, (p) => {
    const to = costsPageFor(p) ? null : legacyCostsPath(p)
    if (to) void navigateTo({ path: localePath(to), query: route.query, hash: route.hash }, { replace: true })
  }, { immediate: true })
})
</script>
