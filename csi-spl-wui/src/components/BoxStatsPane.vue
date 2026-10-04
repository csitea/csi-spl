<!-- HUM-10 (t1 f77c9f87): the Boxes page's RIGHT pane - "some statistics on
     those" resources the middle pane lists. Agents: "the current info we
     already have" (state, kind, seated since, last hello). Hardware: the load
     and memory history from GET /v1/tenant/box-stats (per-hour avg / peak);
     until a box has sent a sample, or on a hub without the route, a plain
     "no history yet". GCP VM metrics come later: one named slot, no data.
     OS and run-times: what the box's hello reported, else "not reported yet".
     Loaded lazily by pages/boxes/[id].vue (027 initial-chunk budget). -->
<template>
  <div class="bstat" data-test="box-stats-pane" :data-resource="resource">
    <h3 class="bstat__title">{{ t(titleKey) }}</h3>

    <!-- agents: the roster's info per agent -->
    <template v-if="resource === 'agents'">
      <div class="bstat__tiles" data-test="box-stats-agents">
        <div class="bstat__tile"><span class="bstat__num" data-test="box-stats-agents-total">{{ counts.total }}</span><span class="muted">{{ t('boxes.stat_total') }}</span></div>
        <div class="bstat__tile"><span class="bstat__num" data-test="box-stats-agents-online">{{ counts.online }}</span><span class="muted">{{ t('people.online') }}</span></div>
        <div class="bstat__tile"><span class="bstat__num">{{ counts.offline }}</span><span class="muted">{{ t('people.offline') }}</span></div>
      </div>
      <p v-if="agents.length === 0" class="muted" data-test="box-stats-no-agents">{{ t('boxes.no_agents') }}</p>
      <div v-else class="bstat__scroll">
        <table class="bstat__table">
          <thead>
            <tr>
              <th scope="col">{{ t('boxes.col_agent') }}</th>
              <th scope="col">{{ t('agents.kind') }}</th>
              <th scope="col">{{ t('boxes.col_state') }}</th>
              <th scope="col">{{ t('boxes.col_seated') }}</th>
              <th scope="col">{{ t('people.last_seen') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="a in agents" :key="a.label" data-test="box-stats-agent" :data-key="a.label">
              <td><NuxtLink :to="localePath('/agents/' + encodeURIComponent(a.label))">{{ a.id }}</NuxtLink></td>
              <td>{{ t(agentKindLabelKey(a.id)) }}</td>
              <td><span class="status-dot" :class="{ on: a.online }" aria-hidden="true" /> {{ a.online ? t('people.online') : t('people.offline') }}</td>
              <td :title="a.seatedAt ? isoDateTime(a.seatedAt) : undefined">{{ a.seatedAt ? ageOf(a.seatedAt) : '—' }}</td>
              <td>{{ a.lastHello ? isoDateTime(a.lastHello) : t('people.never_seen') }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>

    <!-- hardware: the box-stats history -->
    <template v-else-if="resource === 'hardware'">
      <p v-if="stats.state === 'loading'" class="muted" data-test="box-stats-loading">{{ t('app.loading') }}</p>
      <p v-else-if="stats.state === 'forbidden'" class="muted" data-test="box-stats-forbidden">{{ t('boxes.stats_forbidden') }}</p>
      <p v-else-if="stats.state === 'failed'" class="muted" role="alert" data-test="box-stats-failed">{{ t('boxes.stats_failed') }}</p>
      <p v-else-if="stats.state === 'empty' || !summary" class="muted" data-test="box-stats-empty">{{ t('boxes.stats_empty') }}</p>
      <template v-else>
        <div class="bstat__tiles" data-test="box-stats-hardware">
          <div v-if="latest" class="bstat__tile"><span class="bstat__num">{{ latest.cpus }}</span><span class="muted">{{ t('boxes.stat_cpus') }}</span></div>
          <div v-if="latest" class="bstat__tile"><span class="bstat__num">{{ formatKB(latest.mem_total_kb) }}</span><span class="muted">{{ t('boxes.stat_mem_total') }}</span></div>
          <div class="bstat__tile"><span class="bstat__num">{{ formatLoad(summary.load1Avg) }}</span><span class="muted">{{ t('boxes.stat_load_avg') }}</span></div>
          <div class="bstat__tile"><span class="bstat__num">{{ formatLoad(summary.load1Peak) }}</span><span class="muted">{{ t('boxes.stat_load_peak') }}</span></div>
          <div class="bstat__tile"><span class="bstat__num">{{ formatKB(summary.memUsedPeakKB) }}</span><span class="muted">{{ t('boxes.stat_mem_peak') }}</span></div>
          <div class="bstat__tile"><span class="bstat__num">{{ formatKB(summary.memAvailMinKB) }}</span><span class="muted">{{ t('boxes.stat_mem_free_min') }}</span></div>
        </div>
        <p class="muted bstat__note">{{ t('boxes.stats_window', { n: summary.samples }) }}</p>
        <div class="bstat__scroll">
          <table class="bstat__table" data-test="box-stats-hours">
            <thead>
              <tr>
                <th scope="col">{{ t('boxes.col_hour') }}</th>
                <th scope="col">{{ t('boxes.stat_load_avg') }}</th>
                <th scope="col">{{ t('boxes.stat_load_peak') }}</th>
                <th scope="col">{{ t('boxes.col_mem_avg') }}</th>
                <th scope="col">{{ t('boxes.stat_mem_peak') }}</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="h in hours" :key="h.hour" data-test="box-stats-hour">
                <td>{{ isoDateTime(h.hour) }}</td>
                <td>{{ formatLoad(h.load1_avg) }}</td>
                <td>{{ formatLoad(h.load1_peak) }}</td>
                <td>{{ formatKB(h.mem_used_avg_kb) }}</td>
                <td>{{ formatKB(h.mem_used_peak_kb) }}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </template>
      <section class="bstat__slot" data-test="box-stats-disk">
        <h4>{{ t('boxes.disk') }}</h4>
        <div v-if="disks.length" class="bstat__scroll">
          <table class="bstat__table">
            <thead><tr><th scope="col">{{ t('boxes.col_mount') }}</th><th scope="col">{{ t('boxes.col_size') }}</th><th scope="col">{{ t('boxes.col_free') }}</th></tr></thead>
            <tbody>
              <tr v-for="d in disks" :key="d.mount" data-test="box-stats-disk-row"><td><code>{{ d.mount }}</code></td><td>{{ formatKB(d.totalKB) }}</td><td>{{ formatKB(d.availKB) }}</td></tr>
            </tbody>
          </table>
        </div>
        <p v-else class="muted">{{ t('boxes.not_reported') }}</p>
      </section>
      <!-- the GCP VM metrics slot: filled by a later lane, never with made-up data -->
      <section class="bstat__slot" data-test="box-stats-gcp">
        <h4>{{ t('boxes.gcp_vm') }}</h4>
        <p class="muted">{{ t('boxes.gcp_vm_later') }}</p>
      </section>
    </template>

    <!-- OS: the box's hello -->
    <template v-else-if="resource === 'os'">
      <dl v-if="os" class="bstat__facts" data-test="box-stats-os">
        <dt>{{ t('boxes.os_name') }}</dt><dd>{{ os.name || '—' }}</dd>
        <dt>{{ t('boxes.os_version') }}</dt><dd>{{ os.version || '—' }}</dd>
        <dt>{{ t('boxes.os_kernel') }}</dt><dd>{{ os.kernel || '—' }}</dd>
        <dt>{{ t('boxes.os_arch') }}</dt><dd>{{ os.arch || '—' }}</dd>
      </dl>
      <p v-else class="muted" data-test="box-stats-not-reported">{{ t('boxes.not_reported') }}</p>
    </template>

    <!-- run-times: the box's hello -->
    <template v-else-if="resource === 'runtimes'">
      <div v-if="runtimes.length" class="bstat__scroll">
        <table class="bstat__table" data-test="box-stats-runtimes">
          <thead><tr><th scope="col">{{ t('boxes.col_runtime') }}</th><th scope="col">{{ t('boxes.os_version') }}</th></tr></thead>
          <tbody>
            <tr v-for="r in runtimes" :key="r.name"><td><code>{{ r.name }}</code></td><td>{{ r.version || '—' }}</td></tr>
          </tbody>
        </table>
      </div>
      <p v-else class="muted" data-test="box-stats-not-reported">{{ t('boxes.not_reported') }}</p>
    </template>
  </div>
</template>

<script setup lang="ts">
import { agentKindLabelKey } from '~/utils/agent-kind.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { ageOf, agentCounts, agentStatRows, boxDisksOf, boxOsOf, boxRuntimesOf, formatKB, formatLoad, hardwareSummary, latestBoxStat } from '~/utils/box-resources.mjs'
import type { BoxStat, BoxStatHour } from '~/utils/box-resources.mjs'
import type { BoxDetail } from '~/stores/roster'

const props = defineProps<{
  resource: string
  box: { id: string, agents: { id: string, label: string, box: string, online: boolean }[] }
  detail: BoxDetail | null
  stats: { state: 'loading' | 'ready' | 'empty' | 'forbidden' | 'failed', rows: BoxStat[], hours: BoxStatHour[] }
}>()

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()

const TITLES: Record<string, string> = { agents: 'boxes.res_agents', hardware: 'boxes.res_hardware', os: 'boxes.res_os', runtimes: 'boxes.res_runtimes' }
const titleKey = computed(() => TITLES[props.resource] || 'boxes.stats')
const agents = computed(() => agentStatRows(props.box.agents, props.detail))
const counts = computed(() => agentCounts(agents.value))
const summary = computed(() => hardwareSummary(props.stats.hours))
const latest = computed(() => latestBoxStat(props.stats.rows, props.box.id))
/* newest hour first: the history reads down from now */
const hours = computed(() => [...props.stats.hours].sort((a, b) => String(b.hour).localeCompare(String(a.hour))))
const disks = computed(() => boxDisksOf(latest.value))
const os = computed(() => boxOsOf(props.detail))
const runtimes = computed(() => boxRuntimesOf(props.detail))
</script>

<style scoped>
.bstat { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.bstat__title { margin: 0; font-size: 1rem; }
.bstat__tiles { display: grid; grid-template-columns: repeat(auto-fill, minmax(120px, 1fr)); gap: 8px; }
.bstat__tile {
  display: flex; flex-direction: column; gap: 2px; padding: 10px 12px;
  border: 1px solid var(--color-border); border-radius: var(--radius-md);
  background: var(--color-surface); font-size: 0.8rem; min-width: 0;
}
.bstat__num { font-size: 1.25rem; font-weight: 700; color: var(--color-fg); overflow-wrap: anywhere; }
.bstat__note { margin: 0; font-size: 0.8rem; }
.bstat__scroll { overflow-x: auto; max-width: 100%; }
.bstat__table { border-collapse: collapse; width: 100%; font-size: 0.85rem; }
.bstat__table th, .bstat__table td { text-align: start; padding: 6px 8px; border-bottom: 1px solid var(--color-border); white-space: nowrap; }
.bstat__table th { color: var(--color-muted); font-weight: 600; font-size: 0.78rem; }
.bstat__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.bstat__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.bstat__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.bstat__slot h4 { margin: 0 0 4px; font-size: 0.85rem; }
.bstat__slot p { margin: 0; }
.status-dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); vertical-align: middle; }
.status-dot.on { background: var(--color-ok); }
</style>
