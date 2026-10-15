<!-- SPL-2031 (owner HUM-10, t1 dbf2f39b, msgs d4cdda5f, 22472356, 6cab186b):
     a list of admin-set values, read-only, each with a small "(planned)"
     marker. The rows come from utils/monitoring-allocation.mjs. A later lane
     adds the "(measured)" value beside the planned one, in the same cell.
     No input, no button, no save: editing stays in Workspace settings. -->
<template>
  <dl class="alloc-rows" :data-test="testId">
    <template v-for="r in rows" :key="r.id">
      <dt :data-test="'alloc-label-' + r.id">
        <code v-if="r.label && !r.labelKey">{{ r.label }}</code>
        <template v-else>{{ t(r.labelKey) }}</template>
      </dt>
      <dd class="alloc-rows__val" data-test="alloc-value" :data-key="r.id">
        <span class="alloc-rows__planned-val">{{ r.valueKey ? t(r.valueKey, r.params) : r.text }}</span>
        <small v-if="r.planned" class="muted alloc-rows__mark" data-test="alloc-planned">({{ t('monitoring.alloc.planned') }})</small>
      </dd>
    </template>
  </dl>
</template>

<script setup lang="ts">
import type { AllocationRow } from '~/utils/monitoring-allocation.mjs'

defineProps<{ rows: AllocationRow[], testId?: string }>()

const { t } = useI18n({ useScope: 'global' })
</script>

<style scoped>
.alloc-rows { display: grid; grid-template-columns: fit-content(45%) minmax(0, 1fr); gap: 4px 14px; margin: 0; }
.alloc-rows dt { color: var(--color-muted); font-size: 0.8125rem; overflow-wrap: anywhere; }
.alloc-rows dd { margin: 0; min-width: 0; overflow-wrap: break-word; font-size: 0.875rem; }
.alloc-rows__mark { margin-inline-start: 4px; font-size: 0.75rem; white-space: nowrap; }
</style>
