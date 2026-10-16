<!-- SPL-1991: Monitoring -> Boxes (v1). A list over the roster
     (utils/box-rows.mjs, machines only), each row opening the box's card at
     /monitoring/boxes/<id>.

     SPL-2075 (owner HUM-10, t1 dbf2f39b, msg fd5a2bf4): what the old Boxes
     section's list had comes here before its icon goes: a filter on id/tag,
     the count, and the rows grouped Online / Offline, so a fleet stays
     readable.

     SPL-2031 (owner HUM-10, t1 dbf2f39b, d8f64bc3 / d4cdda5f / 22472356 /
     6cab186b): under each row its system facts (MonitoringBoxFacts), and
     above the list the admins' Allocation (MonitoringAllocation), all
     read-only, each set value "(planned)". A block on this tab, not a tab of
     its own: the allocation is per box (band, place in the order), so one
     fleet-load read serves the block and every row. Both are lazy chunks;
     the allocation shows only when GET /v1/operator/fleet-load answers (the
     operator admins, as Settings -> Fleet load). -->
<template>
  <div class="monitoring-list" data-test="monitoring-boxes">
    <MonitoringAllocation v-if="fleet" :view="fleet" :split="split" />
    <p v-if="rows.length === 0" class="muted monitoring-empty" data-test="monitoring-boxes-empty">{{ t('boxes.none') }}</p>
    <template v-else>
      <input
        v-model="filter"
        class="boxes-filter"
        type="search"
        data-test="boxes-filter"
        :placeholder="t('boxes.filter')"
        :aria-label="t('boxes.filter')"
      >
      <p class="muted boxes-count" data-test="boxes-count">{{ t('boxes.count', { count: shown.length }) }}</p>
      <p v-if="shown.length === 0" class="muted monitoring-empty" data-test="boxes-no-match">{{ t('boxes.no_match') }}</p>
    </template>
    <template v-for="g in groups" :key="g.key">
      <div v-if="g.rows.length" class="boxes-group" :data-test="'boxes-group-' + g.key">
        <p class="boxes-group__head muted">{{ g.label }} <span class="boxes-group__n">{{ g.rows.length }}</span></p>
        <div v-for="b in g.rows" :key="b.id" class="monitoring-box" data-test="monitoring-box" :data-box="b.id">
          <div class="nav-row">
            <NuxtLink
              class="nav-item"
              :data-key="b.id"
              :data-online="b.online ? '1' : '0'"
              :to="localePath('/monitoring/boxes/' + encodeURIComponent(b.id))"
            >
              <UiIcon name="server" :size="20" />
              <span class="dot" :class="{ on: b.online }" />
              <span class="label">{{ b.tag }}</span>
            </NuxtLink>
            <LazyBoxSeatCounts :box="b" />
          </div>
          <MonitoringBoxFacts :box="b.id" :detail="roster.boxes[b.id] || null" :stat="latestBoxStat(stats, b.id)" :view="fleet" />
        </div>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { boxRows, filterBoxes } from '~/utils/box-rows.mjs'
import { boxStatsOf, latestBoxStat } from '~/utils/box-resources.mjs'
import type { BoxStat } from '~/utils/box-resources.mjs'
import { normalizeFleetLoad } from '~/utils/fleet-load.mjs'
import type { FleetLoadView } from '~/utils/fleet-load.mjs'
import { normalizeTenantSettings } from '~/utils/tenant-settings.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'

const MonitoringAllocation = defineAsyncComponent(() => import('@/components/MonitoringAllocation.vue'))
const MonitoringBoxFacts = defineAsyncComponent(() => import('@/components/MonitoringBoxFacts.vue'))

type MonitoringApi = {
  getFleetLoad: () => Promise<unknown>
  getTenantSettings: () => Promise<unknown>
  boxStats: (opts?: { box?: string, since?: string }) => Promise<unknown>
}

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const roster = useRosterStore()
const rows = computed(() => boxRows(roster.people, roster.boxes))
const filter = ref('')
const shown = computed(() => filterBoxes(rows.value, filter.value))
const groups = computed(() => [
  { key: 'online', label: t('people.online'), rows: shown.value.filter((b) => b.online) },
  { key: 'offline', label: t('people.offline'), rows: shown.value.filter((b) => !b.online) },
])

const fleet = ref<FleetLoadView | null>(null)
const split = ref<Record<string, number> | null>(null)
const stats = ref<BoxStat[]>([])

/* three reads, each on its own: a 403 or a hub without the route hides
   only its part (the hub's 403 is the gate, as on the settings pages) */
onMounted(() => {
  const api = useSpoolApi() as unknown as MonitoringApi
  void api.getFleetLoad().then(async (body) => {
    fleet.value = normalizeFleetLoad(body)
    try {
      split.value = { ...normalizeTenantSettings(await api.getTenantSettings()).agentSplit }
    } catch { split.value = null }
  }).catch(() => { fleet.value = null })
  void api.boxStats({ since: '1h' }).then((body) => {
    stats.value = boxStatsOf(body as { rows?: unknown[] } | null).rows
  }).catch(() => { stats.value = [] })
})
</script>

<style scoped>
.monitoring-list { display: flex; flex-direction: column; gap: 8px; }
.monitoring-box { border-bottom: 1px solid var(--color-border); min-width: 0; }
/* BoxSeatCounts sits on a second line under the name (absolute), as in the
   sidebar, whose row rules are scoped to ChannelSidebar */
.monitoring-box .nav-row { position: relative; }
.monitoring-box .nav-row > .nav-item { padding-bottom: 20px; display: flex; justify-content: flex-start; }
/* SPL-2075: the old Boxes list's filter, count and status groups */
.boxes-filter {
  width: 100%; box-sizing: border-box; margin: 4px 0 0;
  padding: 5px 8px; font: inherit; font-size: 0.8125rem;
  color: var(--color-fg); background: var(--color-surface);
  border: 1px solid var(--color-border); border-radius: var(--radius-sm);
}
.boxes-count { margin: 0; font-size: 0.6875rem; }
.boxes-group { display: flex; flex-direction: column; gap: 8px; }
.boxes-group__head { margin: 6px 0 0; font-size: 0.6875rem; text-transform: uppercase; letter-spacing: 0.04em; }
.boxes-group__n { opacity: 0.7; }
</style>
