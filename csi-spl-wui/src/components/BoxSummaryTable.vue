<!-- Spec 071 7.4.1 (SPL-6239 row T9; owner HUM-10, t1 78f0138c, msg
     f87c349b): "the most essential info per box should be on the top in a
     single table, in one row, one box, and then the attributes on the table".
     One row per box of this workspace, in the list's order (online, then
     offline; the list's filter applies), every reading from the box's newest
     box-stats sample (utils/box-summary.mjs). A box with no sample reads
     boxes.now_none across its reading cells, never 0. Without audit.read
     (`readings` false) only the Box column is drawn. Narrower than 640 px:
     Box, RAM used, Fullest disk and Sample age stay; the others are in the
     row's title. The State column stays empty until the refresh (row T7). -->
<template>
  <div class="bst" data-test="box-summary">
    <table class="bst__table" :aria-label="t('boxes.sum_title')">
      <thead>
        <tr>
          <th scope="col" data-col="box">{{ t('boxes.sum_col_box') }}</th>
          <template v-if="readings">
            <th scope="col" data-col="ram-pct">{{ t('boxes.sum_col_ram_pct') }}</th>
            <th scope="col" data-col="ram-free" class="bst__wide">{{ t('boxes.sum_col_ram_free') }}</th>
            <th scope="col" data-col="disk">{{ t('boxes.sum_col_disk') }}</th>
            <th scope="col" data-col="load" class="bst__wide">{{ t('boxes.sum_col_load') }}</th>
            <th scope="col" data-col="agents" class="bst__wide">{{ t('boxes.sum_col_agents') }}</th>
            <th scope="col" data-col="age">{{ t('boxes.sum_col_age') }}</th>
            <th scope="col" data-col="state" class="bst__wide">{{ t('boxes.sum_col_state') }}</th>
          </template>
        </tr>
      </thead>
      <tbody>
        <tr v-for="r in rows" :key="r.id" data-test="box-summary-row" :data-box="r.id" :title="readings ? rowTitle(r) : undefined">
          <td data-col="box">
            <NuxtLink class="bst__box" :to="localePath('/monitoring/boxes/' + encodeURIComponent(r.id))">
              <span class="dot" :class="{ on: r.online }" />
              <span>{{ r.tag }}</span>
            </NuxtLink>
          </td>
          <template v-if="readings">
            <template v-if="r.sample">
              <td data-col="ram-pct">{{ t('boxes.sum_pct', { pct: r.sample.ramPct }) }}</td>
              <td data-col="ram-free" class="bst__wide">{{ formatKB(r.sample.ramFreeKB) }}</td>
              <td data-col="disk">{{ r.sample.disk ? t('boxes.sum_disk_val', { mount: r.sample.disk.mount, pct: r.sample.disk.pct }) : '—' }}</td>
              <td data-col="load" class="bst__wide">{{ t('boxes.sum_load_val', { load: formatLoad(r.sample.load1), cpus: r.sample.cpus }) }}</td>
              <td data-col="agents" class="bst__wide">{{ r.sample.agentsLive }}</td>
              <td data-col="age" :title="isoDateTime(r.sample.at)">{{ t('boxes.sum_age', { age: ageOf(r.sample.at) }) }}</td>
            </template>
            <td v-else data-col="none" colspan="6" class="muted">{{ t('boxes.now_none') }}</td>
            <td data-col="state" class="bst__wide" />
          </template>
        </tr>
      </tbody>
    </table>
  </div>
</template>

<script setup lang="ts">
import { isoDateTime } from '~/utils/date-iso.mjs'
import { ageOf, formatKB, formatLoad } from '~/utils/box-resources.mjs'
import type { BoxSummaryRow } from '~/utils/box-summary.mjs'

defineProps<{ rows: BoxSummaryRow[], readings: boolean }>()

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()

/* the columns a narrow table drops, as the row's title text */
function rowTitle(r: BoxSummaryRow) {
  const s = r.sample
  if (!s) return undefined
  return [
    `${t('boxes.sum_col_ram_free')}: ${formatKB(s.ramFreeKB)}`,
    `${t('boxes.sum_col_load')}: ${t('boxes.sum_load_val', { load: formatLoad(s.load1), cpus: s.cpus })}`,
    `${t('boxes.sum_col_agents')}: ${s.agentsLive}`,
  ].join('\n')
}
</script>

<style scoped>
.bst { container-type: inline-size; min-width: 0; }
.bst__table { width: 100%; border-collapse: collapse; font-size: 0.8125rem; }
.bst__table th {
  text-align: left; font-weight: 600; font-size: 0.6875rem; color: var(--color-muted);
  padding: 4px 6px; border-bottom: 1px solid var(--color-border);
}
.bst__table td { padding: 4px 6px; border-bottom: 1px solid var(--color-border); overflow-wrap: anywhere; vertical-align: top; }
.bst__box { display: inline-flex; align-items: center; gap: 6px; color: inherit; text-decoration: none; overflow-wrap: anywhere; }
.bst__box:hover { text-decoration: underline; }
.bst__box .dot { flex: none; }
@container (max-width: 639px) {
  .bst__wide { display: none; }
}
</style>
