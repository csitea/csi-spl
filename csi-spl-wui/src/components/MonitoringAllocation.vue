<!-- SPL-2031 (owner HUM-10, t1 dbf2f39b): "Anything which is set by the
     admins in terms of allocation ... should be read-only on the monitoring
     page" (22472356), each value with "a small bracket mentioning that ...
     the allocations or the loads are planned" (6cab186b). The fleet band,
     runner caps, box order, per-box bands and agent types (GET
     /v1/operator/fleet-load) and the vendor split (GET /v1/tenant/settings).
     Shown only when the fleet-load read answered: the same operator admins
     who see Settings -> Fleet load (owner decision A). No input, no save:
     each part links to the settings page that edits it. Lazy: its own chunk. -->
<template>
  <section class="alloc" data-test="monitoring-allocation" :aria-label="t('monitoring.alloc.title')">
    <h3 class="alloc__title">{{ t('monitoring.alloc.title') }}</h3>
    <p class="muted alloc__hint" data-test="monitoring-allocation-hint">{{ t('monitoring.alloc.hint') }}</p>

    <div class="alloc__parts">
      <div class="alloc__part" data-test="alloc-fleet">
        <h4>{{ t('tenant_settings.fleet_load_title') }}</h4>
        <MonitoringAllocRows :rows="fleet" test-id="alloc-fleet-rows" />
      </div>

      <div class="alloc__part" data-test="alloc-order">
        <h4>{{ t('tenant_settings.fleet_load_boxes') }}</h4>
        <MonitoringAllocRows v-if="order.length" :rows="order" test-id="alloc-order-rows" />
        <p v-else class="muted" data-test="alloc-order-empty">{{ t('tenant_settings.fleet_load_boxes_empty') }}</p>
      </div>

      <div class="alloc__part" data-test="alloc-bands">
        <h4>{{ t('tenant_settings.fleet_load_bands') }}</h4>
        <MonitoringAllocRows v-if="bands.length" :rows="bands" test-id="alloc-band-rows" />
        <p v-else class="muted" data-test="alloc-bands-empty">{{ t('tenant_settings.fleet_load_bands_empty') }}</p>
      </div>

      <div class="alloc__part" data-test="alloc-kinds">
        <h4>{{ t('tenant_settings.fleet_load_kinds') }}</h4>
        <MonitoringAllocRows :rows="kinds" test-id="alloc-kind-rows" />
      </div>

      <div class="alloc__part" data-test="alloc-split">
        <h4>{{ t('tenant_settings.split_title') }}</h4>
        <MonitoringAllocRows v-if="shares.length" :rows="shares" test-id="alloc-split-rows" />
        <p v-else class="muted" data-test="alloc-split-none">{{ t('boxes.not_reported') }}</p>
      </div>
    </div>

    <p class="alloc__edit">
      <NuxtLink :to="localePath(ALLOCATION_EDIT_PATHS.fleet)" data-test="alloc-edit-fleet">{{ t('monitoring.alloc.edit') }}: {{ t('tenant_settings.fleet_load_title') }}</NuxtLink>
      <NuxtLink :to="localePath(ALLOCATION_EDIT_PATHS.split)" data-test="alloc-edit-split">{{ t('monitoring.alloc.edit') }}: {{ t('tenant_settings.split_title') }}</NuxtLink>
    </p>
  </section>
</template>

<script setup lang="ts">
import MonitoringAllocRows from '~/components/MonitoringAllocRows.vue'
import {
  ALLOCATION_EDIT_PATHS, agentKindRows, boxBandRows, boxOrderRows, fleetAllocationRows, splitRows,
} from '~/utils/monitoring-allocation.mjs'
import type { FleetLoadView } from '~/utils/fleet-load.mjs'

const props = defineProps<{ view: FleetLoadView, split: Record<string, number> | null }>()

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()

const fleet = computed(() => fleetAllocationRows(props.view))
const order = computed(() => boxOrderRows(props.view))
const bands = computed(() => boxBandRows(props.view))
const kinds = computed(() => agentKindRows(props.view))
const shares = computed(() => splitRows(props.split))
</script>

<style scoped>
.alloc { display: flex; flex-direction: column; gap: 12px; padding: 12px; border: 1px solid var(--color-border); border-radius: var(--radius-md); background: var(--color-surface); min-width: 0; }
.alloc__title { margin: 0; font-size: 1rem; }
.alloc__hint { margin: 0; font-size: 0.8rem; }
.alloc__parts { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 12px 24px; min-width: 0; }
.alloc__part { min-width: 0; }
.alloc__part h4 { margin: 0 0 4px; font-size: 0.85rem; }
.alloc__part p { margin: 0; }
.alloc__edit { display: flex; flex-wrap: wrap; gap: 6px 16px; margin: 0; font-size: 0.85rem; }
@media (max-width: 820px) {
  .alloc__edit a { min-height: var(--tap, 44px); display: inline-flex; align-items: center; }
}
</style>
