<!-- Spec 153 3.2 (build row B4, SPL-3215; owner HUM-10, prd t1 5e7b15c9,
     msgs 5949d68e and 5c7d1395): Monitoring -> Lanes, the fleet's active
     lanes from GET /v1/operator/fleet-lanes (B3). One row per lane: the
     agent id@box, its kind, the scope, the discussion (linked to /t/<uuid>
     when it is this workspace's topic), the issue keys (linked), when the
     row was written and the last token minute, and last the workspace the
     row belongs to (3.8, SPL-3818). Newest write first, as the hub sends
     it. An admin of the operator workspace reads every lane; a
     workspace's owner or admin (3.6, row B6, SPL-3229) reads the lanes on
     its own topics from GET /v1/view/lanes: the page asks the fleet route
     while the operator console shows (or is not known yet) and, once it
     answers 403, the workspace route for the rest of the page's life. The
     tab shows to those two alone (utils/monitoring-tabs.mjs); anyone else
     reaching the URL sees the hub's 403 as a sentence, never a table.
     Refresh (P4): every 60 s while the browser tab is visible (a hidden tab
     makes no call; it catches up when shown), plus a Refresh button, with
     the age of the last answer: amber after 90 s, red after 180 s. -->
<template>
  <div class="monitoring-lanes" data-test="lanes-page">
    <div class="ln-head">
      <button type="button" class="btn ln-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="lanes-refresh" @click="refresh()">
        {{ t('monitoring.tokens.refresh') }}
      </button>
      <span v-if="view" class="ln-age" :data-stale="stale" data-test="lanes-age">{{ t('monitoring.tokens.updated', { n: lag }) }}</span>
      <span v-if="view && stale === 'red'" class="ln-stale" role="status" data-test="lanes-stale-red">{{ t('monitoring.lanes.stale_red') }}</span>
    </div>

    <p v-if="state === 'loading' && !view" class="muted" data-test="lanes-loading">{{ t('monitoring.lanes.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="ln-error" data-test="lanes-forbidden">{{ t('monitoring.lanes.forbidden') }}</p>
    <p v-else-if="state === 'error' && !view" class="ln-error" data-test="lanes-error">
      {{ t('monitoring.lanes.error') }}
      <button type="button" class="btn" data-test="lanes-retry" @click="refresh()">{{ t('monitoring.tokens.retry') }}</button>
    </p>

    <template v-if="view && state !== 'forbidden'">
      <p v-if="view.lanes.length === 0" class="muted" data-test="lanes-empty">{{ t('monitoring.lanes.empty') }}</p>
      <div v-else class="ln-table-wrap">
        <table class="ln-table" :aria-label="t('monitoring.lanes.table_label')" data-test="lanes-table">
          <thead>
            <tr>
              <th scope="col">{{ t('monitoring.tokens.col_agent') }}</th>
              <th scope="col">{{ t('monitoring.tokens.col_vendor') }}</th>
              <th scope="col">{{ t('monitoring.lanes.col_scope') }}</th>
              <th scope="col">{{ t('issues.discussion') }}</th>
              <th scope="col">{{ t('issues.title') }}</th>
              <th scope="col" class="num">{{ t('monitoring.lanes.col_updated') }}</th>
              <th scope="col" class="num">{{ t('monitoring.tokens.col_last') }}</th>
              <th scope="col" data-test="lanes-col-workspace">{{ t('sidebar.tenant') }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="l in view.lanes" :key="l.agentId + '@' + l.box" data-test="lanes-row" :data-agent="l.agentId">
              <th scope="row" class="ln-id" data-test="lanes-agent">{{ laneName(l) }}</th>
              <td data-test="lanes-vendor">{{ l.vendor || DASH }}</td>
              <td class="ln-cut" :title="l.scope || undefined" data-test="lanes-scope">{{ l.scope || DASH }}</td>
              <td class="ln-cut" :title="l.topicTitle || l.topicId || undefined" data-test="lanes-topic">
                <NuxtLink v-if="laneTopicPath(l)" :to="localePath(laneTopicPath(l))" data-test="lanes-topic-link">{{ l.topicTitle }}</NuxtLink>
                <span v-else-if="l.topicId" class="ln-mono">{{ l.topicId }}</span>
                <span v-else class="muted">{{ DASH }}</span>
              </td>
              <td data-test="lanes-issues">
                <span v-if="l.issues.length === 0" class="muted">{{ DASH }}</span>
                <template v-for="i in l.issues" :key="i.key">
                  <NuxtLink v-if="laneIssuePath(i)" class="ln-issue" :to="localePath(laneIssuePath(i))" :title="i.status" data-test="lanes-issue-link">{{ i.key }}</NuxtLink>
                  <span v-else class="ln-issue" data-test="lanes-issue">{{ i.key }}</span>
                </template>
              </td>
              <td class="num" data-test="lanes-updated">{{ ago(l.updatedAt) }}</td>
              <td class="num" data-test="lanes-active">{{ ago(l.lastActive) }}</td>
              <td class="ln-ws" :title="l.workspace || undefined" data-test="lanes-workspace">{{ l.workspaceName || DASH }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOperatorPane } from '~/stores/operator-pane'
import { lagSeconds } from '~/utils/monitoring-tokens.mjs'
import { fleetLanesOf, laneIssuePath, laneName, laneTopicPath, lanesStaleLevel, minutesAgo, startLanesPoll } from '~/utils/monitoring-lanes.mjs'

type LanesApi = { getFleetLanes: (own?: boolean) => Promise<unknown> }
type LanesView = ReturnType<typeof fleetLanesOf>

const DASH = '—'
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const operator = useOperatorPane()
/* the fleet route refused this reader (403): read the workspace's own lanes */
let own = false
const view = ref<LanesView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
/* when the last answer arrived (ms), and a clock that ticks the age while visible */
const fetchedAt = ref(0)
const now = ref(Date.now())
const lag = computed(() => (fetchedAt.value ? lagSeconds(fetchedAt.value, now.value) : 0))
const stale = computed(() => lanesStaleLevel(lag.value))

/** "N min ago" against the answer's as_of; a dash for none */
function ago(at: string) {
  const m = view.value ? minutesAgo(at, view.value.asOf) : null
  return m === null ? DASH : t('monitoring.lanes.min_ago', { n: m })
}

let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    const api = useSpoolApi() as unknown as LanesApi
    const body = await lanesOf(api)
    if (mine !== seq) return
    view.value = fleetLanesOf(body)
    fetchedAt.value = Date.now()
    now.value = fetchedAt.value
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    const err = e as { status?: number }
    if (err && err.status === 403) {
      view.value = null
      state.value = 'forbidden'
    } else state.value = 'error'
  } finally {
    if (mine === seq) busy.value = false
  }
}

/** The fleet route for an operator admin, else (after its 403) the workspace's own. */
async function lanesOf(api: LanesApi) {
  if (own && !operator.visible) return api.getFleetLanes(true)
  try {
    return await api.getFleetLanes(false)
  } catch (e) {
    if ((e as { status?: number })?.status !== 403 || operator.visible) throw e
    own = true
    return api.getFleetLanes(true)
  }
}

let poll: ReturnType<typeof startLanesPoll> | null = null
let clock: ReturnType<typeof setInterval> | null = null
function refresh() {
  if (poll) poll.refresh()
}
function onVisibility() {
  if (document.visibilityState !== 'visible') return
  now.value = Date.now()
  if (poll) poll.wake()
}

onMounted(() => {
  poll = startLanesPoll({ load: () => { void load() }, visibility: () => document.visibilityState, forbidden: () => state.value === 'forbidden' })
  clock = setInterval(() => {
    if (document.visibilityState === 'visible') now.value = Date.now()
  }, 1000)
  document.addEventListener('visibilitychange', onVisibility)
})
onBeforeUnmount(() => {
  if (poll) poll.stop()
  if (clock) clearInterval(clock)
  document.removeEventListener('visibilitychange', onVisibility)
  seq++
})
</script>

<style scoped>
.monitoring-lanes { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.ln-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
.ln-age { color: var(--color-muted); font-size: 0.875rem; }
.ln-age[data-stale="amber"] { color: var(--color-warn); }
.ln-stale { padding: 0 8px; border-radius: var(--radius-pill); background: var(--color-danger); color: var(--color-danger-fg); font-size: 0.8125rem; font-weight: 600; }
.ln-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
/* the table scrolls sideways inside itself, never the page (3.2, as .tk-table-wrap) */
.ln-table-wrap { overflow-x: auto; max-width: 100%; }
.ln-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.ln-table th, .ln-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.ln-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.ln-id { font-family: var(--font-mono); font-weight: 600; white-space: nowrap; }
.ln-mono { font-family: var(--font-mono); }
/* a long scope or topic stays on one line, its full text in the title (3.2) */
.ln-cut { max-width: 280px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ln-issue { margin-inline-end: 6px; white-space: nowrap; font-family: var(--font-mono); }
/* the workspace, the last column (3.8): it may wrap, never dropped (phone too) */
.ln-ws { min-width: 6rem; overflow-wrap: anywhere; }
</style>
