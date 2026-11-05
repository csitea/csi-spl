<!-- spec 143 1.3 (SPL-2324, SPL-2351): the Reporting section, beside
     Monitoring. The sidebar keeps the icon rail only (ChannelSidebar
     reportingRailOnly); this page is the tab bar (on the heading's row,
     SPL-4811) and the open tab as a child
     route. Each tab is its own path and chunk (the list in
     utils/reporting-tabs.mjs); /reporting itself lands on Releases. -->
<template>
  <div class="feed-col reporting-page" data-test="reporting-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 class="section-title" data-test="reporting-heading">{{ t('reporting.title') }}</h2>
      <!-- SPL-4811 (owner HUM-10, t1 c7c44497, msg 416d130f): the tab bar on
           the heading's row, after "  >>  " (main.css .section-title-sep) -->
      <span class="section-title-sep" aria-hidden="true" data-test="reporting-title-sep">{{ '  >>  ' }}</span>
      <nav class="reporting-tabs" :aria-label="t('reporting.tabs_label')" data-test="reporting-tabs">
        <NuxtLink
          v-for="tab in tabs"
          :key="tab.id"
          :to="localePath(tab.path)"
          class="reporting-tab"
          :class="{ 'reporting-tab--active': active === tab.id }"
          :aria-current="active === tab.id ? 'page' : undefined"
          :data-test="'reporting-tab-' + tab.id"
        >{{ t(tab.labelKey) }}</NuxtLink>
      </nav>
      <SectionClose side="end" />
    </header>
    <div class="feed-body reporting-body">
      <NuxtPage />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'
import { useAccessStore } from '~/stores/access'
import { monitoringStaff } from '~/utils/monitoring-tabs.mjs'
import { reportingOwner } from '~/utils/read-gates.mjs'
import { REPORTING_DEFAULT_PATH, reportingTabFor, visibleReportingTabs } from '~/utils/reporting-tabs.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const operator = useOperatorPane()
const access = useAccessStore()
/* an admin-only tab shows once /v1/view/me answered with role admin; an
   operator-only one (Lanes) only to an operator admin; a permission one
   (Costs: costs.read) once me answered and grants it; a staff one
   (Marketing, spec 163 Q8) to the workspace's owner or an admin; an owner
   one (Incomes, SPL-4697) to the workspace's owner alone. Hiding
   only: the hub's 403 is the control. The Finance tab (spec 125 B7) shows
   to every person of the Netvisor workspace (C7 as rewritten, SPL-4792):
   one forecast read per page load, in any workspace (the hub alone knows
   which one keeps Netvisor data and answers 404 in the others), and the tab
   shows when it answered 2xx. */
const meRead = ref(false)
const netvisorReader = ref(false)
const api = useSpoolApi() as unknown as { mock?: boolean, base?: string }
const tabs = computed(() => visibleReportingTabs({
  operator: operator.visible,
  admin: meRead.value && access.me?.role === 'admin',
  staff: meRead.value && monitoringStaff(access.me),
  owner: meRead.value && reportingOwner(access.me),
  can: meRead.value ? access.can : undefined,
  netvisorReader: netvisorReader.value,
}))
const active = computed(() => reportingTabFor(route.path))

/* /reporting has no page of its own: it lands on the first tab. In the
   browser only, so the prerendered page is the bar, never a redirect. */
onMounted(() => {
  void access.load().finally(() => { meRead.value = true })
  void import('~/utils/reporting-finance.mjs')
    .then(({ netvisorReaderProbe }) => netvisorReaderProbe(api))
    .then((yes) => { netvisorReader.value = yes }, () => { netvisorReader.value = false })
  watch(() => route.path, (p) => {
    if (productPath(p) === '/reporting') void navigateTo(localePath(REPORTING_DEFAULT_PATH), { replace: true })
  }, { immediate: true })
})
</script>
