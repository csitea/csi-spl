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
      <h2 class="section-title" data-test="monitoring-heading">{{ t('monitoring.title') }}</h2>
      <!-- spec 153 3.1 (SPL-3157, owner HUM-10, t1 5e7b15c9): the tab bar on
           the heading's row; SPL-4811 (t1 c7c44497, msg 416d130f): after
           "  >>  " (main.css .section-title-sep) -->
      <span class="section-title-sep" aria-hidden="true" data-test="monitoring-title-sep">{{ '  >>  ' }}</span>
      <!-- spec 153 3.16 (SPL-4730): the bar and a tab's actions share one
           row; display: contents on a desktop (the header is that row), a
           flex row of its own on a phone, where the header dissolves -->
      <div class="monitoring-tabrow" data-test="monitoring-tabrow">
        <nav ref="bar" class="monitoring-tabs" :aria-label="t('monitoring.tabs_label')" data-test="monitoring-tabs">
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
             on a desktop as on the old /events page; Lanes, Topics, Tokens:
             Refresh, its age, Clear filters), teleported in by the tab -->
        <div id="monitoring-head-actions" class="monitoring-head-actions" data-test="monitoring-head-actions" />
      </div>
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
import { useOperatorReader } from '~/composables/useOperatorReader'
import { MONITORING_DEFAULT_PATH, monitoringStaff, monitoringTabFor, visibleMonitoringTabs } from '~/utils/monitoring-tabs.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const operator = useOperatorPane()
const access = useAccessStore()
/* a permission tab (one naming a `perm`) shows once /v1/view/me answered;
   access.can fails open (no answer = unrestricted), the hub's 403 is the control */
const meRead = ref(false)
const operatorReader = useOperatorReader()
const tabs = computed(() => visibleMonitoringTabs({ operator: operator.visible, staff: monitoringStaff(access.me), operatorReader: operatorReader.value, can: meRead.value ? access.can : undefined }))
const active = computed(() => monitoringTabFor(route.path))

/* 3.16 (SPL-4730): on a phone the bar shares its row with the tab's
   actions and scrolls inside itself, so the open tab is scrolled into it */
const bar = ref<HTMLElement | null>(null)
function showActiveTab() {
  const nav = bar.value
  const tab = nav?.querySelector<HTMLElement>('.monitoring-tab--active')
  if (!nav || !tab) return
  const n = nav.getBoundingClientRect()
  const r = tab.getBoundingClientRect()
  /* scrollLeft takes whole pixels: round up, or a sub-pixel stays cut off */
  if (r.left < n.left) nav.scrollLeft -= Math.ceil(n.left - r.left)
  else if (r.right > n.right) nav.scrollLeft += Math.ceil(r.right - n.right)
}

/* /monitoring has no page of its own: it lands on the first tab (Q1 A). In
   the browser only, so the prerendered page is the bar, never a redirect. */
onMounted(() => {
  void access.load().finally(() => { meRead.value = true })
  watch(() => route.path, (p) => {
    if (productPath(p) === '/monitoring') void navigateTo(localePath(MONITORING_DEFAULT_PATH), { replace: true })
  }, { immediate: true })
  watch(active, () => { void nextTick(showActiveTab) }, { immediate: true })
  if (typeof ResizeObserver !== 'undefined' && bar.value) {
    const ro = new ResizeObserver(showActiveTab)
    ro.observe(bar.value)
    onBeforeUnmount(() => ro.disconnect())
  }
})
</script>

