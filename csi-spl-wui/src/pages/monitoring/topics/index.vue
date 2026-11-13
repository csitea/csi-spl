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
     Refresh and stale marker as the Lanes page.
     Id links (SPL-4798): the discussion and the issue keys link through the
     one `type:id` renderer (composables/useLaneLinks.ts ->
     utils/note-links.mjs) on their workspace's host, as on Lanes.
     Like Lanes (3.29, SPL-5430; owner HUM-10, t1 5804c44c, msg b65c7989:
     "The visual layout of the topics in the monitoring should be quite
     similar to the visual layout of the lanes, and it should behave the same
     way, including the refresh button"): the Lanes page's sheet
     (components/SheetHead.vue, SheetPhoneBar.vue, utils/column-sheet.mjs).
     On a desktop each name sorts (▲, ▼, then newest activity first) and the
     row under the names holds one filter per column; on a phone a bar shows
     the sort in words and opens a Sort and a Filters sheet, and the rows are
     cards. The sort and the filters live in the address
     (composables/useSheetListUrl.ts) and survive the minute's refresh.
     Clear filters shows while a filter is on, before Refresh; Refresh is
     last on the tabs' row on a desktop and at the bottom centre above the
     dock on a phone (components/PhoneDockButton.vue), as on Lanes. -->
<template>
  <div class="monitoring-topics" data-test="topics-page">
    <!-- 3.16 (SPL-4730): the age, Clear filters and Refresh on the tabs' row,
         on the right, in the Lanes page's order (3.29) -->
    <ClientOnly>
      <Teleport to="#monitoring-head-actions" defer>
        <span v-if="view" class="tp-age" :data-stale="stale" data-test="topics-age">{{ t('monitoring.tokens.updated', { n: lag }) }}</span>
        <button v-if="topics.length && !phone && filtered" type="button" class="btn ghost" data-test="topics-filter-clear" @click="clearFilters()">{{ t('issues.filter_clear') }}</button>
        <button v-if="!phone" type="button" class="btn tp-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="topics-refresh" @click="refresh()">
          <UiIcon name="refresh" class="mh-icon" /><span class="mh-label">{{ t('monitoring.tokens.refresh') }}</span>
        </button>
      </Teleport>
    </ClientOnly>
    <!-- the red stale line and "shown n of total" stay above the table, a row only while one shows -->
    <div v-if="view && (stale === 'red' || filtered)" class="tp-head">
      <span v-if="stale === 'red'" class="tp-stale" role="status" data-test="topics-stale-red">{{ t('monitoring.lanes.stale_red') }}</span>
      <span v-if="filtered" class="tp-age" role="status" data-test="topics-shown">{{ t('monitoring.topics.shown', { n: rows.length, total: topics.length }) }}</span>
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
        <SheetPhoneBar
          v-if="phone"
          :columns="sheetColumns"
          :sort="sort"
          :filters="filters"
          prefix="topics"
          :sort-words="sortWords"
          :filters-on="filtered"
          @sort="toggleSort"
          @filter="onFilter"
          @clear="clearFilters"
        />
        <table class="tp-table" :aria-label="t('monitoring.topics.table_label')" data-test="topics-table">
          <SheetHead :columns="sheetColumns" :sort="sort" :filters="filters" :phone="phone" prefix="topics" @sort="toggleSort" @filter="onFilter" />
          <tbody>
            <tr v-if="rows.length === 0">
              <td :colspan="sheetColumns.length" class="muted" data-test="topics-no-match">{{ t('monitoring.topics.no_match') }}</td>
            </tr>
            <tr v-for="r in rows" :key="r.topicId || '-'" class="tp-row" data-test="topics-row" :data-topic="r.topicId">
              <th scope="row" class="tp-cut" :title="r.topicTitle || r.topicId || undefined" data-test="topics-topic">
                <NuxtLink v-if="topicTo(r).href" :to="toOf(topicTo(r))" data-test="topics-topic-link">{{ r.topicTitle || r.topicId }}</NuxtLink>
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
                  <NuxtLink v-if="issueTo(i, r).href" class="tp-chip" :to="toOf(issueTo(i, r))" :data-status="i.status" data-test="topics-issue-link">{{ i.key }}<span class="tp-chip-state">{{ i.status }}</span></NuxtLink>
                  <span v-else class="tp-chip" data-test="topics-issue">{{ i.key }}</span>
                </template>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
    <!-- the room the phone's Refresh needs under the last card -->
    <div v-if="phone" class="tp-dock-room" aria-hidden="true" />
    <PhoneDockButton v-if="phone" class="tp-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="topics-refresh" @click="refresh()">
      {{ t('monitoring.tokens.refresh') }}
    </PhoneDockButton>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOperatorPane } from '~/stores/operator-pane'
import { useAccessStore } from '~/stores/access'
import { gateMe, lanesReadPlan } from '~/utils/read-gates.mjs'
import { lagSeconds } from '~/utils/monitoring-tokens.mjs'
import { LANE_AGES, fleetLanesOf, laneDeepLink, laneIssueRef, laneTopicRef, lanesStaleLevel, minutesAgo, readLanes, startLanesPoll } from '~/utils/monitoring-lanes.mjs'
import { TOPIC_AGE_COLUMNS, TOPIC_SHEET_COLUMNS, TOPICS_DEFAULT_SORT, TOPICS_NO_FILTER, TOPICS_URL_SPEC, filterTopics, sortTopics, topicFilterChoices, topicsFiltered, topicsOf } from '~/utils/monitoring-topics.mjs'
import { nextSheetSort, sheetSortLabel } from '~/utils/column-sheet.mjs'
import { usePhone } from '~/composables/useTouchUi'
import { useSheetListUrl } from '~/composables/useSheetListUrl'
import { useLaneLinks, type LaneLink } from '~/composables/useLaneLinks'

type LanesApi = { getFleetLanes: (own?: boolean) => Promise<unknown> }
type LanesView = ReturnType<typeof fleetLanesOf>

const DASH = '—'
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const operator = useOperatorPane()
const phone = usePhone()
/* SPL-4798: a row's ids as links, on the host of the workspace they belong to */
const { pageTenant, linkOf } = useLaneLinks()
type TopicRow = ReturnType<typeof topicsOf>[number]
const topicTo = (r: TopicRow) => linkOf(laneTopicRef(r, pageTenant.value))
const issueTo = (i: { key: string, status: string }, r: TopicRow) => linkOf(laneIssueRef(i, r, pageTenant.value))
/** this host: the router's path; another workspace's host: the whole address */
const toOf = (to: LaneLink) => (to.here ? to.path : to.href)
/* the fleet route refused this reader (403): read the workspace's own lanes, as the Lanes page */
const lanesRead = { own: false, operatorVisible: false }
const view = ref<LanesView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
const fetchedAt = ref(0)
const now = ref(Date.now())
const lag = computed(() => (fetchedAt.value ? lagSeconds(fetchedAt.value, now.value) : 0))
const stale = computed(() => lanesStaleLevel(lag.value))

/* the sheet's columns, the sort (none = newest activity first) and one
   filter per column: the Lanes page's (3.29, utils/column-sheet.mjs) */
const COLUMN_EXTRA: Record<string, { cls?: string }> = { active: { cls: 'num' } }
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
function toggleSort(col: string) {
  sort.value = nextSheetSort(col, sort.value, TOPIC_SHEET_COLUMNS)
}
const filters = reactive<Record<string, string>>({ ...TOPICS_NO_FILTER })
const filtered = computed(() => topicsFiltered(filters))
function onFilter(col: string, value: string) {
  filters[col] = value
}
function clearFilters() {
  Object.assign(filters, TOPICS_NO_FILTER)
}
const topics = computed(() => (view.value ? topicsOf(view.value) : []))
const choices = computed(() => topicFilterChoices(topics.value))
/** a choice column's options: the answer's values, in words where the page has them */
function choicesOf(col: string): { value: string, label: string }[] {
  if (TOPIC_AGE_COLUMNS.includes(col)) return LANE_AGES.map((a) => ({ value: a, label: ageLabel(a) }))
  if (col === 'workspace') return choices.value.workspace.map((w) => ({ value: w.id, label: w.name }))
  return choices.value.channel.map((c) => ({ value: c, label: '#' + c }))
}
const sheetColumns = computed(() => TOPIC_SHEET_COLUMNS.map((c) => ({
  col: c.col,
  label: t(c.key),
  kind: c.kind,
  choices: c.kind === 'choice' ? choicesOf(c.col) : undefined,
  ...COLUMN_EXTRA[c.col],
})))
const sortWords = computed(() => {
  const bits = sheetSortLabel(sort.value, TOPIC_SHEET_COLUMNS, TOPICS_DEFAULT_SORT)
  return t('issues_mobile.sort_now', { col: t(bits.colKey), dir: t(bits.dirKey) })
})
const rows = computed(() => sortTopics(filterTopics(topics.value, filters), sort.value))
/* the sort and the filters follow the address and back, as on Lanes (3.15, 3.29) */
useSheetListUrl({ spec: TOPICS_URL_SPEC, sort, filters, answer: view, choices: () => choices.value })

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

const access = useAccessStore()
let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    lanesRead.operatorVisible = operator.visible
    /* SPL-4724: /v1/view/me picks the read, as the Lanes page (SPL-4453); a member sends none and gets the line */
    const plan = lanesReadPlan(await gateMe(access))
    if (mine !== seq) return
    if (plan === 'none') {
      view.value = null
      state.value = 'forbidden'
      return
    }
    if (plan === 'own') lanesRead.own = true
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
/* the table scrolls sideways inside itself, never the page (as the Lanes table); a phone reads cards (below) */
.tp-table-wrap { overflow-x: auto; max-width: 100%; }
.tp-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.tp-table :deep(th), .tp-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.tp-table tbody th { font-weight: 600; }
.tp-table :deep(.num) { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.tp-mono { font-family: var(--font-mono); }
/* a long title stays on one line, its full text in the title attribute */
.tp-cut { max-width: 320px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tp-nw { white-space: nowrap; }
.tp-ws { white-space: nowrap; }
/* a lane or an issue as a chip: its id, then its state or status, small */
.tp-chip { display: inline-flex; align-items: baseline; gap: 4px; margin: 0 6px 2px 0; padding: 0 6px; border: 1px solid var(--color-border); border-radius: var(--radius-pill); white-space: nowrap; font-family: var(--font-mono); }
.tp-chip-state { color: var(--color-muted); font-family: inherit; font-size: 0.75rem; }
.tp-chip-state:empty { display: none; }
/* the filter row under the names is SheetHead.vue's, as on Lanes; a filter keeps a usable width */
.tp-table :deep(.sheet-filter) { min-width: 5rem; max-width: 16rem; }
/* the room under the last card for the phone's Refresh (PhoneDockButton) */
.tp-dock-room { height: calc(var(--tap, 44px) + 16px); }

/* 3.29 (SPL-5430): on a phone (the one 820 px breakpoint) the same table
   reads as a list of dense cards, the whole width, nothing sideways, as the
   Lanes cards (3.25). The phone bar sorts and filters above it; each row is
   a card of three short lines:
     1  topic (cut) ............................ last activity
     2  lanes (chips) ............................... issues
     3  #channel  workspace (cut)
   Every cell, link and data-test stays as on the desktop. */
@media (max-width: 820px) {
  .tp-table-wrap { overflow-x: visible; }
  .tp-table, .tp-table tbody { display: block; width: 100%; }
  /* the names stay in the DOM for readers, visually hidden, as on Lanes */
  .tp-table thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
  .tp-table tbody tr { display: block; }
  .tp-table tbody .tp-row { display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 6px; padding: 6px 2px; font-size: 0.8125rem; border-bottom: 1px solid var(--color-border); }
  .tp-row > th, .tp-row > td { padding: 0; border: 0; min-width: 0; }
  .tp-row > td:empty { display: none; }
  /* the two line breaks between the card's three lines */
  .tp-row::before, .tp-row::after { content: ""; flex: 0 0 100%; height: 0; }
  .tp-row::before { order: 10; }
  .tp-row::after { order: 20; }
  .tp-row > [data-test=topics-topic] { order: 1; flex: 1 1 5rem; max-width: none; }
  .tp-row > [data-test=topics-active] { order: 2; margin-inline-start: auto; color: var(--color-muted); }
  .tp-row > [data-test=topics-lanes] { order: 11; flex: 1 1 auto; }
  .tp-row > [data-test=topics-issues] { order: 12; flex: 0 1 auto; max-width: 50%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .tp-row .tp-chip { font-size: 0.75rem; }
  .tp-row > [data-test=topics-channel] { order: 21; color: var(--color-muted); }
  .tp-row > .tp-ws { order: 22; flex: 0 1 auto; min-width: 0; max-width: 60%; overflow: hidden; text-overflow: ellipsis; color: var(--color-muted); }
}
</style>
