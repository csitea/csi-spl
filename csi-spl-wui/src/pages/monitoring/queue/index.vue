<!-- Spec 153 3.22.3 (row Q4, SPL-6740; owner HUM-10, t1 906c1b28, 11-06
     23:50Z: "the priority of the lanes and the future plans and request must
     be setable via the ui"): Monitoring -> Queue, read only, right after
     Lanes. The placer's line from GET /v1/operator/fleet-queue (row Q3,
     hub internal/hub/fleet_queue_view.go), in the hub's order: the rows being
     placed first, then the queue by position (3.22.4, as
     do_spl_spawn_queue reads it). The Requests columns in 3.22.3's order:
     Position (n/total, or placing), Prio (1..5 and where it came from: own,
     discussion, default), Class (and urgent / bypass), Summary, Discussion
     and Issue (linked through the one `type:id` renderer,
     composables/useLaneLinks.ts), Vendor, In line, Waits on (the placer's
     hold reason, else room) and Lane. The Placed filter, off by default,
     adds the closed rows the hub keeps a week; a placed row's lane links to
     its row on Monitoring -> Lanes while that lane is active, else it reads
     "ended" with its agent id as text. Changing a priority (Q5), dragging
     (Q6) and the Plans table (Q7) are later rows.
     For admins of the operator workspace only (3.22.3: the first build is
     operator only): the tab shows to them alone (utils/monitoring-tabs.mjs)
     and anyone else reaching the URL sees the hub's 403 as a sentence,
     never a table. Refresh: every 60 s while the browser tab is visible
     (startLanesPoll, P4), plus a Refresh button. -->
<template>
  <div class="monitoring-queue" data-test="queue-page">
    <ClientOnly>
      <Teleport to="#monitoring-head-actions" defer>
        <label v-if="state !== 'forbidden'" class="mq-placed" data-test="queue-placed">
          <input v-model="placed" type="checkbox" data-test="queue-placed-input">
          <span>{{ t('monitoring.queue.placed_filter') }}</span>
        </label>
        <button type="button" class="btn mq-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="queue-refresh" @click="refresh()">
          <UiIcon name="refresh" class="mh-icon" /><span class="mh-label">{{ t('monitoring.tokens.refresh') }}</span>
        </button>
      </Teleport>
    </ClientOnly>

    <p class="muted mq-hint">{{ t('monitoring.queue.hint') }}</p>

    <p v-if="state === 'loading' && !view" class="muted" data-test="queue-loading">{{ t('monitoring.queue.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="mq-error" data-test="queue-forbidden">{{ t('monitoring.queue.forbidden') }}</p>
    <p v-else-if="state === 'error' && !view" class="mq-error" data-test="queue-error">
      {{ t('monitoring.queue.error') }}
      <button type="button" class="btn" data-test="queue-retry" @click="refresh()">{{ t('monitoring.tokens.retry') }}</button>
    </p>

    <template v-if="view && mq && state !== 'forbidden'">
      <p v-if="view.rows.length === 0" class="muted" data-test="queue-empty">{{ t('monitoring.queue.empty') }}</p>
      <div v-else class="mq-table-wrap">
        <table class="mq-table" :aria-label="t('monitoring.queue.table_label')" data-test="queue-table">
          <thead>
            <tr>
              <th v-for="c in COLUMNS" :key="c" scope="col" :data-test="'queue-col-' + c">{{ t('monitoring.queue.col_' + c) }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in view.rows" :key="r.askId" class="mq-row" data-test="queue-row" :data-ask="r.askId" :data-state="r.state">
              <th scope="row" class="num" data-test="queue-position">{{ cell(mq.queuePositionCell(r, view.total)) }}</th>
              <td class="num" :data-label="t('monitoring.queue.col_prio')" data-test="queue-prio" :data-priority="r.priority || undefined" :data-source="r.prioritySource || undefined">
                <span v-if="r.priority" class="mq-prio" :class="'mq-prio--' + r.priority">{{ r.priority }}</span>
                <span v-else class="muted">{{ DASH }}</span>
                <span v-if="r.prioritySource" class="mq-src" data-test="queue-prio-source">{{ t('monitoring.queue.prio_' + r.prioritySource) }}</span>
              </td>
              <td :data-label="t('monitoring.queue.col_class')" data-test="queue-class">
                {{ classLabel(r.class) }}
                <span v-if="r.flag" class="mq-flag" :data-flag="r.flag" data-test="queue-flag">{{ t('monitoring.queue.flag_' + r.flag) }}</span>
              </td>
              <td class="mq-cut" :title="r.summary || undefined" :data-label="t('monitoring.queue.col_summary')" data-test="queue-summary">{{ r.summary || DASH }}</td>
              <td :data-label="t('monitoring.queue.col_discussion')" data-test="queue-discussion">
                <NuxtLink v-if="topicTo(r).href" :to="toOf(topicTo(r))" class="mq-mono" :title="r.discussion" data-test="queue-discussion-link">{{ r.discussion.slice(0, 8) }}</NuxtLink>
                <span v-else-if="r.discussion" class="mq-mono">{{ r.discussion }}</span>
                <span v-else class="muted">{{ DASH }}</span>
              </td>
              <td :data-label="t('monitoring.queue.col_issue')" data-test="queue-issue">
                <NuxtLink v-if="issueTo(r).href" :to="toOf(issueTo(r))" data-test="queue-issue-link">{{ r.issueKey }}</NuxtLink>
                <span v-else-if="r.issueKey">{{ r.issueKey }}</span>
                <span v-else class="muted">{{ DASH }}</span>
              </td>
              <td :data-label="t('monitoring.queue.col_vendor')" data-test="queue-vendor">{{ r.vendor || DASH }}</td>
              <td class="num" :data-label="t('monitoring.queue.col_in_line')" data-test="queue-in-line">{{ mq.queueOpen(r) ? cell(mq.queueInLine(r.inLineS)) : DASH }}</td>
              <td :data-label="t('monitoring.queue.col_waits')" data-test="queue-waits" :data-hold="r.holdReason ? '1' : undefined">
                {{ mq.queueOpen(r) ? (r.holdReason || t('monitoring.queue.waits_room')) : DASH }}
              </td>
              <td :data-label="t('monitoring.queue.col_lane')" data-test="queue-lane">
                <template v-if="laneOf(r)">
                  <NuxtLink v-if="laneOf(r)!.to" :to="localePath(laneOf(r)!.to!)" class="mq-mono" data-test="queue-lane-link">{{ laneOf(r)!.lane }}</NuxtLink>
                  <span v-else class="muted" data-test="queue-lane-ended">{{ t('monitoring.queue.lane_ended', { id: laneOf(r)!.agentId }) }}</span>
                </template>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { gateMe, operatorReadable } from '~/utils/read-gates.mjs'
import { useLaneLinks, type LaneLink } from '~/composables/useLaneLinks'
/* types only: the modules load in onMounted / load(), so their chunks are the page's own dependency and not one
   more name in the entry chunk's route table (C107, ci_initial_gzip_kb, perf-budgets.json) */
import type * as Queue from '~/utils/monitoring-queue.mjs'
import type * as Lanes from '~/utils/monitoring-lanes.mjs'

/* the lazy client's lanes method (spool-client-lazy.mjs getFleetLanes('queue', placed)): no new stub in the initial chunk */
type QueueApi = { getFleetLanes: (own?: boolean | 'queue', placed?: boolean) => Promise<unknown> }
type QueueView = ReturnType<typeof Queue.fleetQueueOf>
type Row = QueueView['rows'][number]

const COLUMNS = ['position', 'prio', 'class', 'summary', 'discussion', 'issue', 'vendor', 'in_line', 'waits', 'lane'] as const
const DASH = '—'
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const view = ref<QueueView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
const placed = ref(false)
/* the active lanes' id@box, read only while Placed is on; null = not read (a lane then links) */
const active = shallowRef<Set<string> | null>(null)
const api = () => useSpoolApi() as unknown as QueueApi
const mq = shallowRef<typeof Queue | null>(null)

const { pageTenant, linkOf } = useLaneLinks()
const topicTo = (r: Row): LaneLink => linkOf(mq.value?.queueTopicRef(r, pageTenant.value) ?? null)
const issueTo = (r: Row): LaneLink => linkOf(mq.value?.queueIssueRef(r, pageTenant.value) ?? null)
const toOf = (l: LaneLink) => l.here ? l.path : l.href
const laneOf = (r: Row) => mq.value?.queueLaneCell(r, active.value) ?? null
const cell = (c: { key?: string, text?: string, params?: Record<string, number> }) => c.key ? t(c.key, c.params || {}) : (c.text || DASH)
const classLabel = (cls: string) => {
  const key = mq.value?.queueClassKey(cls)
  return key ? t(key) : (cls || DASH)
}

const access = useAccessStore()
let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    if (!operatorReadable(await gateMe(access))) {
      if (mine !== seq) return
      view.value = null
      state.value = 'forbidden'
      return
    }
    const withPlaced = placed.value
    const [body, m] = await Promise.all([api().getFleetLanes('queue', withPlaced), mq.value || import('~/utils/monitoring-queue.mjs')])
    if (mine !== seq) return
    mq.value = m
    const v = m.fleetQueueOf(body)
    active.value = withPlaced && v.rows.some((r) => r.lane) ? await activeLanes() : null
    if (mine !== seq) return
    view.value = v
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    if ((e as { status?: number })?.status === 403) {
      view.value = null
      state.value = 'forbidden'
    } else state.value = 'error'
  } finally {
    if (mine === seq) busy.value = false
  }
}

/** The lanes active now, to tell a placed row's live lane from an ended one; null when the read fails. */
async function activeLanes(): Promise<Set<string> | null> {
  try {
    const ml = lanesMod || await import('~/utils/monitoring-lanes.mjs')
    const lanes = ml.fleetLanesOf(await api().getFleetLanes(false)).lanes
    return new Set(lanes.map((l) => ml.laneName(l)))
  } catch {
    return null
  }
}

let lanesMod: typeof Lanes | null = null
let poll: { wake: () => void, refresh: () => void, stop: () => void } | null = null
const refresh = () => (poll ? poll.refresh() : void load())
watch(placed, () => refresh())
const onVisible = () => { if (document.visibilityState === 'visible') poll?.wake() }

onMounted(async () => {
  lanesMod = await import('~/utils/monitoring-lanes.mjs')
  poll = lanesMod.startLanesPoll({ load: () => { void load() }, visibility: () => document.visibilityState, forbidden: () => state.value === 'forbidden' })
  document.addEventListener('visibilitychange', onVisible)
})
onBeforeUnmount(() => {
  seq++
  poll?.stop()
  document.removeEventListener('visibilitychange', onVisible)
})
</script>

<style scoped>
.monitoring-queue { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.mq-hint { margin: 0; }
.mq-refresh { display: inline-flex; align-items: center; gap: 6px; }
.mq-placed { display: inline-flex; align-items: center; gap: 6px; font-size: 0.875rem; white-space: nowrap; }
.mq-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.mq-table-wrap { overflow-x: auto; max-width: 100%; }
.mq-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.mq-table th, .mq-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.mq-table tbody th { font-weight: 600; }
.mq-table .num { white-space: nowrap; font-variant-numeric: tabular-nums; }
.mq-cut { max-width: 28rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.mq-mono { font-family: var(--font-mono); font-size: 0.75rem; overflow-wrap: anywhere; }
.mq-prio { font-weight: 600; }
.mq-prio--1, .mq-prio--2 { color: var(--color-danger); }
.mq-src, .mq-flag { display: inline-block; margin-inline-start: 4px; color: var(--color-muted); font-size: 0.75rem; }
.mq-flag { font-weight: 600; }
@media (max-width: 600px) {
  .mq-table thead { display: none; }
  .mq-table tr { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 12px; padding: 6px 0; border-bottom: 1px solid var(--color-border); }
  .mq-table th, .mq-table td { border-bottom: 0; padding: 0 4px; min-width: 0; }
  .mq-table tr > :first-child, .mq-table .mq-cut { grid-column: 1 / -1; }
  .mq-cut { max-width: none; white-space: normal; }
  .mq-table td[data-label]::before { content: attr(data-label) ": "; color: var(--color-muted); }
}
</style>
