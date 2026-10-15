<!-- SPL-2031 (owner HUM-10, t1 dbf2f39b, msg d8f64bc3): "all of the
     information which is related to the system" - the OS, the hardware, the
     system load, the binaries - "as it is displayed now", on Monitoring ->
     Boxes, read-only (d4cdda5f). A read-only extract of BoxStatsPane: the
     box's daily facts (roster boxes[]), its latest box-stats sample's disks,
     and, for the operator admins who may read it, the box's allocation (its
     band in force, its place in the box order), each "(planned)" (6cab186b).
     Lazy: its own chunk. -->
<template>
  <div class="mbf" data-test="monitoring-box-facts" :data-box="box">
    <p class="muted mbf__age" data-test="monitoring-box-facts-age" :title="factsAt ? isoDateTime(factsAt) : undefined">
      {{ factsAt ? t('boxes.facts_age', { age: ageOf(factsAt) }) : t('boxes.facts_never') }}
    </p>
    <div class="mbf__grid">
      <section class="mbf__part" data-test="mbf-os">
        <h4>{{ t('boxes.res_os') }}</h4>
        <dl v-if="os" class="mbf__facts">
          <dt>{{ t('boxes.os_release') }}</dt><dd>{{ os.pretty || '—' }}</dd>
          <dt>{{ t('boxes.os_name') }}</dt><dd>{{ os.name || '—' }}</dd>
          <dt>{{ t('boxes.os_version') }}</dt><dd>{{ os.version || '—' }}</dd>
          <dt>{{ t('boxes.os_kernel') }}</dt><dd>{{ os.kernel || '—' }}</dd>
          <dt>{{ t('boxes.os_arch') }}</dt><dd>{{ os.arch || '—' }}</dd>
        </dl>
        <p v-else class="muted">{{ t('boxes.not_reported') }}</p>
      </section>

      <section class="mbf__part" data-test="mbf-hardware">
        <h4>{{ t('boxes.res_hardware') }}</h4>
        <dl v-if="sys" class="mbf__facts">
          <dt>{{ t('boxes.cpu_model') }}</dt><dd>{{ sys.cpuModel || '—' }}</dd>
          <dt>{{ t('boxes.stat_cpus') }}</dt><dd>{{ sys.cpus ?? '—' }}</dd>
          <dt>{{ t('boxes.stat_mem_total') }}</dt><dd>{{ formatMB(sys.memTotalMB) || '—' }}</dd>
          <dt>{{ t('boxes.mem_avail') }}</dt><dd>{{ formatMB(sys.memAvailMB) || '—' }}</dd>
          <dt>{{ t('boxes.swap') }}</dt><dd>{{ swapLine || '—' }}</dd>
          <dt>{{ t('boxes.disk') }}</dt><dd data-test="mbf-disk" :title="diskTitle(disks, t)">{{ diskLine(lowestDisk(disks), t) || '—' }}</dd>
        </dl>
        <p v-else class="muted">{{ t('boxes.not_reported') }}</p>
      </section>

      <section class="mbf__part" data-test="mbf-system">
        <h4>{{ t('boxes.res_system') }}</h4>
        <dl v-if="sys" class="mbf__facts">
          <dt>{{ t('boxes.sys_hostname') }}</dt><dd><code>{{ sys.hostname || '—' }}</code></dd>
          <dt>{{ t('boxes.sys_state') }}</dt><dd>{{ sys.state || '—' }}</dd>
          <dt>{{ t('boxes.sys_uptime') }}</dt><dd :title="sys.bootAt ? isoDateTime(sys.bootAt) : undefined">{{ sys.bootAt ? ageOf(sys.bootAt) : '—' }}</dd>
          <dt>{{ t('boxes.sys_timezone') }}</dt><dd>{{ sys.timezone || '—' }}</dd>
          <dt>{{ t('boxes.sys_load') }}</dt><dd data-test="mbf-load">{{ sys.load || '—' }}</dd>
        </dl>
        <p v-else class="muted">{{ t('boxes.not_reported') }}</p>
      </section>

      <section class="mbf__part" data-test="mbf-runtimes">
        <h4>{{ t('boxes.res_runtimes') }}</h4>
        <dl v-if="runtimes.length" class="mbf__facts">
          <template v-for="r in runtimes" :key="r.name"><dt><code>{{ r.name }}</code></dt><dd>{{ r.version || '—' }}</dd></template>
        </dl>
        <p v-else class="muted">{{ t('boxes.not_reported') }}</p>
      </section>

      <section class="mbf__part" data-test="mbf-network">
        <h4>{{ t('boxes.res_network') }}</h4>
        <dl v-if="net" class="mbf__facts">
          <dt>{{ t('boxes.net_ips') }}</dt><dd>{{ net.ips.join(', ') || '—' }}</dd>
          <dt>{{ t('boxes.net_gateway') }}</dt><dd><code>{{ net.gateway || '—' }}</code></dd>
          <dt>{{ t('boxes.net_dns') }}</dt><dd>{{ net.dns.join(', ') || '—' }}</dd>
        </dl>
        <p v-else class="muted">{{ t('boxes.not_reported') }}</p>
      </section>

      <section v-if="alloc.length" class="mbf__part" data-test="mbf-allocation">
        <h4>{{ t('monitoring.alloc.title') }}</h4>
        <MonitoringAllocRows :rows="alloc" test-id="mbf-allocation-rows" />
      </section>
    </div>
  </div>
</template>

<script setup lang="ts">
import MonitoringAllocRows from '~/components/MonitoringAllocRows.vue'
import { isoDateTime } from '~/utils/date-iso.mjs'
import {
  ageOf, boxDisksOf, boxNetworkOf, boxOsOf, boxRuntimesOf, boxSystemOf, diskLine, diskTitle, factsReportedAt, formatMB, lowestDisk,
} from '~/utils/box-resources.mjs'
import type { BoxStat } from '~/utils/box-resources.mjs'
import { boxAllocationRows } from '~/utils/monitoring-allocation.mjs'
import type { FleetLoadView } from '~/utils/fleet-load.mjs'
import type { BoxDetail } from '~/stores/roster'

const props = defineProps<{ box: string, detail: BoxDetail | null, stat: BoxStat | null, view: FleetLoadView | null }>()

const { t } = useI18n({ useScope: 'global' })

const os = computed(() => boxOsOf(props.detail))
const sys = computed(() => boxSystemOf(props.detail))
const net = computed(() => boxNetworkOf(props.detail))
const runtimes = computed(() => boxRuntimesOf(props.detail))
const factsAt = computed(() => factsReportedAt(props.detail))
const disks = computed(() => boxDisksOf(props.stat))
const alloc = computed(() => boxAllocationRows(props.view, props.box))
/* as BoxStatsPane: "used / total", "0" on a box without swap */
const swapLine = computed(() => {
  const s = sys.value
  if (!s || s.swapTotalMB === null) return ''
  if (s.swapTotalMB === 0) return '0'
  const used = s.swapFreeMB === null ? null : Math.max(0, s.swapTotalMB - s.swapFreeMB)
  return used === null ? formatMB(s.swapTotalMB) : `${formatMB(used)} / ${formatMB(s.swapTotalMB)}`
})
</script>

<style scoped>
.mbf { display: flex; flex-direction: column; gap: 8px; padding: 4px 8px 12px 36px; min-width: 0; }
.mbf__age { margin: 0; font-size: 0.78rem; }
.mbf__grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 10px 18px; min-width: 0; }
.mbf__part { min-width: 0; }
.mbf__part h4 { margin: 0 0 4px; font-size: 0.85rem; }
.mbf__part p { margin: 0; font-size: 0.85rem; }
.mbf__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 2px 12px; margin: 0; font-size: 0.85rem; }
.mbf__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.mbf__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
@media (max-width: 600px) {
  .mbf { padding-inline-start: 8px; }
  .mbf__grid { grid-template-columns: minmax(0, 1fr); }
}
</style>
