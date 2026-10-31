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
     the age of the last answer: amber after 90 s, red after 180 s.
     Sort and filter (SPL-3887; owner HUM-10, t1 31f6f470, msgs 1eedefed and
     08b25696): the Issues sheet's controls. A column name sorts by that
     column (▲, ▼, then back to the hub's order; components/SheetSortButton.vue),
     the row under the names filters by box, vendor, state, age and text, and
     Clear filters resets them. Both survive the minute's refresh.
     Deep link (3.9, SPL-4206; owner HUM-10, t1 fb9b6e4b, msg 470ae116): a
     lane on the agent card opens this page at ?lane=<id@box>; that row is
     marked selected and scrolled into view once it is in the answer. -->
<template>
  <div class="monitoring-lanes" data-test="lanes-page">
    <div class="ln-head">
      <button type="button" class="btn ln-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="lanes-refresh" @click="refresh()">
        {{ t('monitoring.tokens.refresh') }}
      </button>
      <span v-if="view" class="ln-age" :data-stale="stale" data-test="lanes-age">{{ t('monitoring.tokens.updated', { n: lag }) }}</span>
      <span v-if="view && stale === 'red'" class="ln-stale" role="status" data-test="lanes-stale-red">{{ t('monitoring.lanes.stale_red') }}</span>
      <span v-if="view && filtered" class="ln-age" role="status" data-test="lanes-shown">{{ t('monitoring.lanes.shown', { n: rows.length, total: view.lanes.length }) }}</span>
      <button v-if="view && view.lanes.length" type="button" class="btn ghost" :disabled="!filtered" data-test="lanes-filter-clear" @click="clearFilters()">{{ t('issues.filter_clear') }}</button>
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
              <th
                v-for="c in columns"
                :key="c.col"
                scope="col"
                :class="c.cls"
                :data-test="c.test"
                :aria-sort="sort.col === c.col ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'"
              >
                <SheetSortButton :col="c.col" :name="c.name" :sort="sort" :test="'lanes-sort-' + c.col" @sort="toggleSort" />
              </th>
            </tr>
            <tr class="ln-frow" data-test="lanes-filters">
              <th>
                <select v-model="filters.box" data-test="lanes-filter-box" :aria-label="t('monitoring.lanes.filter_box')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="b in choices.box" :key="b" :value="b">{{ b }}</option>
                </select>
              </th>
              <th>
                <select v-model="filters.vendor" data-test="lanes-filter-vendor" :aria-label="t('monitoring.lanes.filter_vendor')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="v in choices.vendor" :key="v" :value="v">{{ v }}</option>
                </select>
              </th>
              <th>
                <select v-model="filters.state" data-test="lanes-filter-state" :aria-label="t('monitoring.lanes.filter_state')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="s in choices.state" :key="s" :value="s">{{ stateLabel(s) }}</option>
                </select>
              </th>
              <th colspan="3">
                <input v-model="filters.text" type="search" class="ln-search" data-test="lanes-filter-text" :placeholder="t('monitoring.lanes.filter_text')" :aria-label="t('monitoring.lanes.filter_text')">
              </th>
              <th>
                <select v-model="filters.age" data-test="lanes-filter-age" :aria-label="t('monitoring.lanes.filter_age')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="a in LANE_AGES" :key="a" :value="a">{{ ageLabel(a) }}</option>
                </select>
              </th>
              <th colspan="2" />
            </tr>
          </thead>
          <tbody>
            <tr v-if="rows.length === 0">
              <td :colspan="columns.length" class="muted" data-test="lanes-no-match">{{ t('monitoring.lanes.no_match') }}</td>
            </tr>
            <tr
              v-for="l in rows"
              :key="l.agentId + '@' + l.box"
              class="ln-row"
              data-test="lanes-row"
              :data-agent="l.agentId"
              :data-lane="laneName(l)"
              :data-selected="laneName(l) === selectedLane ? '1' : undefined"
              :aria-current="laneName(l) === selectedLane ? 'true' : undefined"
            >
              <th scope="row" class="ln-id" data-test="lanes-agent">{{ laneName(l) }}</th>
              <td data-test="lanes-vendor">{{ l.vendor || DASH }}</td>
              <td data-test="lanes-state" :data-state="l.state">{{ stateLabel(l.state) }}</td>
              <td class="ln-cut" :title="l.scope || undefined" data-test="lanes-scope">{{ l.scope || DASH }}</td>
              <td class="ln-cut" :title="l.topicTitle || l.topicId || undefined" data-test="lanes-topic">
                <NuxtLink v-if="laneTopicPath(l)" :to="localePath(laneTopicPath(l))" data-test="lanes-topic-link">{{ l.topicTitle }}</NuxtLink>
                <span v-else-if="l.topicId" class="ln-mono">{{ l.topicId }}</span>
                <span v-else-if="l.roleSeat" class="muted" data-test="lanes-role-seat">{{ t('monitoring.lanes.role_seat') }}</span>
                <span v-else class="muted">{{ DASH }}</span>
              </td>
              <td data-test="lanes-issues">
                <span v-if="l.issues.length === 0 && l.roleSeat" class="muted" data-test="lanes-role-seat">{{ t('monitoring.lanes.role_seat') }}</span>
                <span v-else-if="l.issues.length === 0" class="muted">{{ DASH }}</span>
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
import { LANE_AGES, LANE_COLUMNS, LANE_QUERY, LANES_NO_FILTER, filterLanes, fleetLanesOf, laneFilterChoices, laneIssuePath, laneName, laneTopicPath, lanesFiltered, lanesStaleLevel, minutesAgo, readLanes, sortLanes, startLanesPoll } from '~/utils/monitoring-lanes.mjs'
import { cycleSort } from '~/utils/sheet-sort.mjs'

type LanesApi = { getFleetLanes: (own?: boolean) => Promise<unknown> }
type LanesView = ReturnType<typeof fleetLanesOf>

const DASH = '—'
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const operator = useOperatorPane()
const route = useRoute()
/* the fleet route refused this reader (403, s.own): read the workspace's own lanes */
const lanesRead = { own: false, operatorVisible: false }
const view = ref<LanesView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
/* when the last answer arrived (ms), and a clock that ticks the age while visible */
const fetchedAt = ref(0)
const now = ref(Date.now())
const lag = computed(() => (fetchedAt.value ? lagSeconds(fetchedAt.value, now.value) : 0))
const stale = computed(() => lanesStaleLevel(lag.value))

/* the sheet's columns, the sort (none = the hub's order) and the filter row (SPL-3887) */
const COLUMN_NAMES: Record<string, { key: string, cls?: string, test?: string }> = {
  agent: { key: 'monitoring.tokens.col_agent' },
  vendor: { key: 'monitoring.tokens.col_vendor' },
  state: { key: 'monitoring.lanes.col_state' },
  scope: { key: 'monitoring.lanes.col_scope' },
  topic: { key: 'issues.discussion' },
  issues: { key: 'issues.title' },
  updated: { key: 'monitoring.lanes.col_updated', cls: 'num' },
  active: { key: 'monitoring.tokens.col_last', cls: 'num' },
  workspace: { key: 'sidebar.tenant', test: 'lanes-col-workspace' },
}
const columns = computed(() => LANE_COLUMNS.map((col: string) => ({ col, name: t(COLUMN_NAMES[col]!.key), cls: COLUMN_NAMES[col]!.cls, test: COLUMN_NAMES[col]!.test })))
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
function toggleSort(col: string) {
  sort.value = cycleSort(col, sort.value, LANE_COLUMNS)
}
const filters = reactive({ ...LANES_NO_FILTER })
const filtered = computed(() => lanesFiltered(filters))
function clearFilters() {
  Object.assign(filters, LANES_NO_FILTER)
}
const choices = computed(() => laneFilterChoices(view.value ? view.value.lanes : []))
const rows = computed(() => (view.value ? sortLanes(filterLanes(view.value.lanes, filters), sort.value) : []))
/** the age filter's choices in words */
function ageLabel(a: string) {
  if (a === '1h') return t('monitoring.lanes.age_1h')
  if (a === '24h') return t('monitoring.lanes.age_24h')
  return t('monitoring.lanes.age_older')
}
/** live / queued in words; a state the page does not know shows as sent */
function stateLabel(s: string) {
  if (s === 'live') return t('monitoring.lanes.state_live')
  if (s === 'queued') return t('monitoring.lanes.state_queued')
  return s
}

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
    lanesRead.operatorVisible = operator.visible
    const body = await readLanes(api, lanesRead)
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

/* the lane a deep link selects (?lane=<id@box>), scrolled into view once it is shown */
const selectedLane = computed(() => {
  const q = route.query[LANE_QUERY]
  return String((Array.isArray(q) ? q[0] : q) || '')
})
let scrolledTo = ''
watch([selectedLane, rows], async () => {
  const want = selectedLane.value
  if (!want || want === scrolledTo || !rows.value.some((l) => laneName(l) === want)) return
  scrolledTo = want
  await nextTick()
  const row = document.querySelector(`[data-test=lanes-row][data-lane="${CSS.escape(want)}"]`)
  if (row) row.scrollIntoView({ block: 'center' })
})

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
.ln-row[data-selected="1"] > * { background: var(--color-selected); }
.ln-id { font-family: var(--font-mono); font-weight: 600; white-space: nowrap; }
.ln-mono { font-family: var(--font-mono); }
/* a long scope or topic stays on one line, its full text in the title (3.2) */
.ln-cut { max-width: 280px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ln-issue { margin-inline-end: 6px; white-space: nowrap; font-family: var(--font-mono); }
/* the filter row under the names, as the Issues sheet's (SPL-3887) */
.ln-frow th { font-weight: normal; padding-top: 2px; }
.ln-frow select, .ln-search { width: 100%; min-width: 5rem; max-width: 16rem; font: inherit; }
/* the workspace, the last column (3.8): it may wrap, never dropped (phone too) */
.ln-ws { min-width: 6rem; overflow-wrap: anywhere; }
</style>
