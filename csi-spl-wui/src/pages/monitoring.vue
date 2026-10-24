<!-- SPL-1991 (owner HUM-10, t1 dbf2f39b, msg 94283d6b, A on Q1-Q4): the
     Monitoring section. The sidebar keeps the icon rail only (ChannelSidebar
     monitoringRailOnly); this page is the tab bar (on the heading's row,
     spec 153 3.1), the summary strip above every tab (Q1 A, its content is
     a later lane), and the open tab as a child route. Each tab is its own
     path and chunk (D4, the list in utils/monitoring-tabs.mjs); /monitoring
     itself lands on Agents. -->
<template>
  <div class="feed-col monitoring-page" data-test="monitoring-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="monitoring-heading">{{ t('monitoring.title') }}</h2>
      <!-- spec 153 3.1 (SPL-3157, owner HUM-10, t1 5e7b15c9): the tab bar on
           the heading's row, its first label 20 px after "Monitoring" -->
      <nav class="monitoring-tabs" :aria-label="t('monitoring.tabs_label')" data-test="monitoring-tabs">
        <NuxtLink
          v-for="tab in tabs"
          :key="tab.id"
          :to="localePath(tab.path)"
          class="monitoring-tab"
          :class="{ 'monitoring-tab--active': active === tab.id }"
          :aria-current="active === tab.id ? 'page' : undefined"
          :data-test="'monitoring-tab-' + tab.id"
        >{{ t(tab.labelKey) }}</NuxtLink>
      </nav>
      <!-- SPL-3250: a tab's own header actions (Events: Clear log, top right
           on a desktop as on the old /events page), teleported in by the tab -->
      <div id="monitoring-head-actions" class="monitoring-head-actions" data-test="monitoring-head-actions" />
      <SectionClose side="end" />
    </header>
    <!-- the summary strip's slot: empty until its lane fills it -->
    <div class="monitoring-summary" data-test="monitoring-summary" />
    <div class="feed-body monitoring-body">
      <NuxtPage />
    </div>
  </div>
</template>

<script setup lang="ts">
import { useOperatorPane } from '~/stores/operator-pane'
import { useAccessStore } from '~/stores/access'
import { MONITORING_DEFAULT_PATH, monitoringStaff, monitoringTabFor, visibleMonitoringTabs } from '~/utils/monitoring-tabs.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const operator = useOperatorPane()
const access = useAccessStore()
/* a permission tab (Costs: costs.read) shows once /v1/view/me answered;
   access.can fails open (no answer = unrestricted), the hub's 403 is the control */
const meRead = ref(false)
const tabs = computed(() => visibleMonitoringTabs({ operator: operator.visible, staff: monitoringStaff(access.me), can: meRead.value ? access.can : undefined }))
const active = computed(() => monitoringTabFor(route.path))

/* /monitoring has no page of its own: it lands on the first tab (Q1 A). In
   the browser only, so the prerendered page is the bar, never a redirect. */
onMounted(() => {
  void access.load().finally(() => { meRead.value = true })
  watch(() => route.path, (p) => {
    if (productPath(p) === '/monitoring') void navigateTo(localePath(MONITORING_DEFAULT_PATH), { replace: true })
  }, { immediate: true })
})
</script>

