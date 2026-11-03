<!-- spec 143 1.3 (SPL-2324, SPL-2351): the Reporting section, beside
     Monitoring. The sidebar keeps the icon rail only (ChannelSidebar
     reportingRailOnly); this page is the tab bar and the open tab as a child
     route. Each tab is its own path and chunk (the list in
     utils/reporting-tabs.mjs); /reporting itself lands on Releases. -->
<template>
  <div class="feed-col reporting-page" data-test="reporting-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="reporting-heading">{{ t('reporting.title') }}</h2>
      <SectionClose side="end" />
    </header>
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
    <div class="feed-body reporting-body">
      <NuxtPage />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'
import { useAccessStore } from '~/stores/access'
import { monitoringStaff } from '~/utils/monitoring-tabs.mjs'
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
   (Marketing, spec 163 Q8) to the workspace's owner or an admin. Hiding
   only: the hub's 403 is the control. The Finance tab (spec 125 B7) shows
   to the workspace's Netvisor owner alone (C7): its settings read is sent
   only in the operator workspace (the one workspace with Netvisor data), by
   an admin there, and the tab shows when it answered 2xx. */
const meRead = ref(false)
const netvisorOwner = ref(false)
const api = useSpoolApi() as unknown as { mock?: boolean, base?: string }
const tabs = computed(() => visibleReportingTabs({
  operator: operator.visible,
  admin: meRead.value && access.me?.role === 'admin',
  staff: meRead.value && monitoringStaff(access.me),
  can: meRead.value ? access.can : undefined,
  netvisorOwner: netvisorOwner.value,
}))
const active = computed(() => reportingTabFor(route.path))

/* /reporting has no page of its own: it lands on the first tab. In the
   browser only, so the prerendered page is the bar, never a redirect. */
onMounted(() => {
  void access.load().finally(() => { meRead.value = true })
  watch(() => operator.visible, async (v) => {
    if (!v || netvisorOwner.value) return
    const { netvisorOwnerProbe } = await import('~/utils/reporting-finance.mjs')
    netvisorOwner.value = await netvisorOwnerProbe(api)
  }, { immediate: true })
  watch(() => route.path, (p) => {
    if (productPath(p) === '/reporting') void navigateTo(localePath(REPORTING_DEFAULT_PATH), { replace: true })
  }, { immediate: true })
})
</script>
