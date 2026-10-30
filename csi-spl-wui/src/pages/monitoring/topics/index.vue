<!-- Spec 153 3.10 (row B10, SPL-4421; owner HUM-10, t1 08213e0e, msg
     8caf41ec: "a new topics tab in the monitoring section, which will have
     the same narrow listing like the lanes, but for topics, and outline the
     issues and lanes per discussion /topic"): Monitoring -> Topics. One
     narrow row per topic: its title (linked to /t/<uuid> when it is this
     workspace's topic), its workspace and channel, its last lane activity,
     its lanes (id@box chips, each linking to its row on Monitoring -> Lanes,
     with its state) and its issues (SPL-n chips, linked, with their status),
     newest activity first. The rows are the Lanes answer grouped by topic
     (utils/monitoring-topics.mjs): the same routes, readers, minute poll,
     Refresh, stale marker, sort buttons and filter row as the Lanes page. -->
<template>
  <div class="monitoring-topics" data-test="topics-page">
    <div class="tp-head">
      <button type="button" class="btn tp-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="topics-refresh" @click="refresh()">
        {{ t('monitoring.tokens.refresh') }}
      </button>
      <span v-if="view" class="tp-age" :data-stale="stale" data-test="topics-age">{{ t('monitoring.tokens.updated', { n: lag }) }}</span>
      <span v-if="view && stale === 'red'" class="tp-stale" role="status" data-test="topics-stale-red">{{ t('monitoring.lanes.stale_red') }}</span>
      <span v-if="view && filtered" class="tp-age" role="status" data-test="topics-shown">{{ t('monitoring.topics.shown', { n: rows.length, total: topics.length }) }}</span>
      <button v-if="topics.length" type="button" class="btn ghost" :disabled="!filtered" data-test="topics-filter-clear" @click="clearFilters()">{{ t('issues.filter_clear') }}</button>
    </div>

    <p v-if="state === 'loading' && !view" class="muted" data-test="topics-loading">{{ t('monitoring.topics.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="tp-error" data-test="topics-forbidden">{{ t('monitoring.lanes.forbidden') }}</p>
    <p v-else-if="state === 'error' && !view" class="tp-error" data-test="topics-error">
      {{ t('monitoring.topics.error') }}
      <button type="button" class="btn" data-test="topics-retry" @click="refresh()">{{ t('monitoring.tokens.retry') }}</button>
    </p>

    <template v-if="view && state !== 'forbidden'">
      <p v-if="topics.length === 0" class="muted" data-test="topics-empty">{{ t('monitoring.topics.empty') }}</p>
      <div v-else class="tp-table-wrap">
        <table class="tp-table" :aria-label="t('monitoring.topics.table_label')" data-test="topics-table">
          <thead>
            <tr>
              <th
                v-for="c in columns"
                :key="c.col"
                scope="col"
                :class="c.cls"
                :aria-sort="sort.col === c.col ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none'"
              >
                <SheetSortButton :col="c.col" :name="c.name" :sort="sort" :test="'topics-sort-' + c.col" @sort="toggleSort" />
              </th>
            </tr>
            <tr class="tp-frow" data-test="topics-filters">
              <th colspan="3">
                <input v-model="filters.text" type="search" class="tp-search" data-test="topics-filter-text" :placeholder="t('monitoring.topics.filter_text')" :aria-label="t('monitoring.topics.filter_text')">
              </th>
              <th>
                <select v-model="filters.age" data-test="topics-filter-age" :aria-label="t('monitoring.lanes.filter_age')">
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="a in LANE_AGES" :key="a" :value="a">{{ ageLabel(a) }}</option>
                </select>
              </th>
              <th>
                <div class="tp-fl">
                  <select v-model="filters.box" data-test="topics-filter-box" :aria-label="t('monitoring.lanes.filter_box')">
                    <option value="">{{ t('issues.filter_all') }}</option>
                    <option v-for="b in choices.box" :key="b" :value="b">{{ b }}</option>
                  </select>
                  <select v-model="filters.vendor" data-test="topics-filter-vendor" :aria-label="t('monitoring.lanes.filter_vendor')">
                    <option value="">{{ t('issues.filter_all') }}</option>
                    <option v-for="v in choices.vendor" :key="v" :value="v">{{ v }}</option>
                  </select>
                  <select v-model="filters.state" data-test="topics-filter-state" :aria-label="t('monitoring.lanes.filter_state')">
                    <option value="">{{ t('issues.filter_all') }}</option>
                    <option v-for="s in choices.state" :key="s" :value="s">{{ stateLabel(s) }}</option>
                  </select>
                </div>
              </th>
              <th />
            </tr>
          </thead>
          <tbody>
            <tr v-if="rows.length === 0">
              <td :colspan="columns.length" class="muted" data-test="topics-no-match">{{ t('monitoring.topics.no_match') }}</td>
            </tr>
            <tr v-for="r in rows" :key="r.topicId || '-'" class="tp-row" data-test="topics-row" :data-topic="r.topicId">
              <th scope="row" class="tp-cut" :title="r.topicTitle || r.topicId || undefined" data-test="topics-topic">
                <NuxtLink v-if="laneTopicPath(r)" :to="localePath(laneTopicPath(r))" data-test="topics-topic-link">{{ r.topicTitle }}</NuxtLink>
                <span v-else-if="r.topicId" class="tp-mono">{{ r.topicId }}</span>
                <span v-else class="muted" data-test="topics-none">{{ t('monitoring.topics.no_topic') }}</span>
              </th>
              <td class="tp-ws" :title="r.workspace || undefined" data-test="topics-workspace">{{ r.workspaceName || DASH }}</td>
              <td class="tp-nw" data-test="topics-channel">{{ r.topicChannel ? '#' + r.topicChannel : DASH }}</td>
              <td class="num" data-test="topics-active">{{ ago(r.lastAt) }}</td>
              <td data-test="topics-lanes">
                <NuxtLink
                  v-for="l in r.lanes"
                  :key="l.name"
                  class="tp-chip"
                  :to="localePath(laneDeepLink(l))"
                  :data-state="l.state"
                  :title="stateLabel(l.state)"
                  data-test="topics-lane"
                >{{ l.name }}<span class="tp-chip-state">{{ stateLabel(l.state) }}</span></NuxtLink>
              </td>
              <td data-test="topics-issues">
                <span v-if="r.issues.length === 0" class="muted">{{ DASH }}</span>
                <template v-for="i in r.issues" :key="i.key">
                  <NuxtLink v-if="laneIssuePath(i)" class="tp-chip" :to="localePath(laneIssuePath(i))" :data-status="i.status" data-test="topics-issue-link">{{ i.key }}<span class="tp-chip-state">{{ i.status }}</span></NuxtLink>
                  <span v-else class="tp-chip" data-test="topics-issue">{{ i.key }}</span>
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
import { useOperatorPane } from '~/stores/operator-pane'
import { lagSeconds } from '~/utils/monitoring-tokens.mjs'
import { LANE_AGES, fleetLanesOf, laneDeepLink, laneIssuePath, laneTopicPath, lanesStaleLevel, minutesAgo, readLanes, startLanesPoll } from '~/utils/monitoring-lanes.mjs'
import { TOPIC_COLUMNS, TOPICS_NO_FILTER, filterTopics, sortTopics, topicFilterChoices, topicsOf } from '~/utils/monitoring-topics.mjs'
import { cycleSort } from '~/utils/sheet-sort.mjs'

type LanesApi = { getFleetLanes: (own?: boolean) => Promise<unknown> }
type LanesView = ReturnType<typeof fleetLanesOf>

const DASH = '—'
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const operator = useOperatorPane()
/* the fleet route refused this reader (403): read the workspace's own lanes, as the Lanes page */
const lanesRead = { own: false, operatorVisible: false }
const view = ref<LanesView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
const fetchedAt = ref(0)
const now = ref(Date.now())
const lag = computed(() => (fetchedAt.value ? lagSeconds(fetchedAt.value, now.value) : 0))
const stale = computed(() => lanesStaleLevel(lag.value))

/* the sheet's columns, the sort (none = newest activity first) and the filter row */
const COLUMN_NAMES: Record<string, { key: string, cls?: string }> = {
  topic: { key: 'issues.discussion' },
  workspace: { key: 'sidebar.tenant' },
  channel: { key: 'monitoring.topics.col_channel' },
  active: { key: 'monitoring.topics.col_active', cls: 'num' },
  lanes: { key: 'monitoring.tab.lanes' },
  issues: { key: 'issues.title' },
}
const columns = computed(() => TOPIC_COLUMNS.map((col: string) => ({ col, name: t(COLUMN_NAMES[col]!.key), cls: COLUMN_NAMES[col]!.cls })))
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
function toggleSort(col: string) {
  sort.value = cycleSort(col, sort.value, TOPIC_COLUMNS)
}
const filters = reactive({ ...TOPICS_NO_FILTER })
const filtered = computed(() => Boolean(filters.text.trim() || filters.box || filters.vendor || filters.state || filters.age))
function clearFilters() {
  Object.assign(filters, TOPICS_NO_FILTER)
}
const topics = computed(() => (view.value ? topicsOf(view.value) : []))
const choices = computed(() => topicFilterChoices(topics.value))
const rows = computed(() => sortTopics(filterTopics(topics.value, filters), sort.value))
function ageLabel(a: string) {
  if (a === '1h') return t('monitoring.lanes.age_1h')
  if (a === '24h') return t('monitoring.lanes.age_24h')
  return t('monitoring.lanes.age_older')
}
function stateLabel(s: string) {
  if (s === 'live') return t('monitoring.lanes.state_live')
  if (s === 'queued') return t('monitoring.lanes.state_queued')
  return s
}
function ago(at: string) {
  const m = view.value ? minutesAgo(at, view.value.asOf) : null
  return m === null ? DASH : t('monitoring.lanes.min_ago', { n: m })
}

let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    lanesRead.operatorVisible = operator.visible
    const body = await readLanes(useSpoolApi() as unknown as LanesApi, lanesRead)
    if (mine !== seq) return
    view.value = fleetLanesOf(body)
    fetchedAt.value = Date.now()
    now.value = fetchedAt.value
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
.monitoring-topics { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.tp-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
.tp-age { color: var(--color-muted); font-size: 0.875rem; }
.tp-age[data-stale="amber"] { color: var(--color-warn); }
.tp-stale { padding: 0 8px; border-radius: var(--radius-pill); background: var(--color-danger); color: var(--color-danger-fg); font-size: 0.8125rem; font-weight: 600; }
.tp-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
/* the table scrolls sideways inside itself, never the page (as the Lanes table) */
.tp-table-wrap { overflow-x: auto; max-width: 100%; }
.tp-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.tp-table th, .tp-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.tp-table tbody th { font-weight: 600; }
.tp-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.tp-mono { font-family: var(--font-mono); }
/* a long title stays on one line, its full text in the title attribute */
.tp-cut { max-width: 320px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tp-nw { white-space: nowrap; }
.tp-ws { white-space: nowrap; }
/* a lane or an issue as a chip: its id, then its state or status, small */
.tp-chip { display: inline-flex; align-items: baseline; gap: 4px; margin: 0 6px 2px 0; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); white-space: nowrap; font-family: var(--font-mono); }
.tp-chip-state { color: var(--color-muted); font-family: inherit; font-size: 0.75rem; }
.tp-chip-state:empty { display: none; }
.tp-frow th { font-weight: normal; padding-top: 2px; }
.tp-frow select, .tp-search { width: 100%; min-width: 5rem; max-width: 16rem; font: inherit; }
.tp-fl { display: flex; flex-wrap: wrap; gap: 4px; }
.tp-fl select { width: auto; }
</style>
