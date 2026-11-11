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
     tab shows to those two and to the operator workspace's product owner, who
     reads the fleet route (SPL-5181; utils/monitoring-tabs.mjs); anyone else
     reaching the URL sees the hub's 403 as a sentence, never a table.
     Refresh (P4): every 60 s while the browser tab is visible (a hidden tab
     makes no call; it catches up when shown), plus a Refresh button, with
     the age of the last answer: amber after 90 s, red after 180 s.
     Sort and filter (SPL-3887; owner HUM-10, t1 31f6f470, msgs 1eedefed and
     08b25696): the Issues sheet's controls. A column name sorts by that
     column (▲, ▼, then back to the hub's order; components/SheetSortButton.vue),
     the row under the names filters by box, vendor, state, age and text, and
     Clear filters resets them. Both survive the minute's refresh.
     Box (SPL-4458; owner HUM-10, t1 0acd4eaa, msg 97453531): the box a lane
     works on is its own column after the agent, sortable, its select under
     it; the workspace route sends no box, so the cell is a dash there.
     Prio (3.14, SPL-4727; owner HUM-10, t1 0d0bc34c, msgs 136f2e49 and
     c78812f2): the lane's prio, the highest among its issues (1 highest),
     is the 3rd column, sortable like the others; a lane with no issue
     shows a dash and sorts last.
     Workspace filter (SPL-4705; owner HUM-10, t1 0ea86216, msg c50a260f):
     a select under the Workspace column, which stays last, offering the
     answer's workspaces by name and matching on the row's id.
     Deep link (3.9, SPL-4206; owner HUM-10, t1 fb9b6e4b, msg 470ae116): a
     lane on the agent card opens this page at ?lane=<id@box>; that row is
     marked selected and scrolled into view once it is in the answer.
     Shareable list (3.15, SPL-4729; owner HUM-10, t1 0a730c21, msg
     ea87c5c1): the sort and the filter row live in the address
     (utils/monitoring-lanes-url.mjs), so a copied URL opens the same list.
     A change replaces the address, never adds a history entry; a default
     writes no parameter; Clear filters drops them; ?lane= stays. The first
     answer sets back to All a box, vendor, state or workspace it does not
     offer: a member reads the workspace route, which sends no box, so an
     operator's link with a box shows the member's lanes, never a false
     empty list.
     Id links (SPL-4798; owner HUM-10, t1 0c2d08a2, msg ea369ab0): the
     discussion (a topic uuid, a dispatch-<topic8> task), the issue keys and
     the origin issue link through the one `type:id` renderer
     (composables/useLaneLinks.ts -> utils/note-links.mjs), on the workspace
     host they belong to, at render time; `unknown` and an id with no known
     host stay text.
     Like the Event log (SPL-5276; owner HUM-10, t1 e1e97af9, msgs 7ccb6bfa
     and 2dedcc73: "Sorting and filtering in lanes should behave exactly as
     sorting and filtering for the event log", "the refresh button should be
     in the same place where the clear lock button is"): the sheet is the
     Event log's (components/SheetHead.vue, SheetPhoneBar.vue,
     utils/column-sheet.mjs). On a desktop each name sorts (▲, ▼, then the
     hub's order) and the row under the names holds one filter per column; on
     a phone a bar shows the sort in words and opens a Sort and a Filters
     sheet. Clear filters shows while a filter is on, before the last action.
     Refresh takes Clear log's place: the right end of the tabs' row on a
     desktop, the bottom centre above the dock on a phone
     (components/PhoneDockButton.vue). -->
<template>
  <div class="monitoring-lanes" data-test="lanes-page">
    <!-- 3.16 (SPL-4730; owner HUM-10, t1 3238db2c, msg 2dd25d62): the age,
         Clear filters and Refresh sit on the tabs' row, on the right
         (monitoring.vue #monitoring-head-actions); client only, as Events'
         Clear log: the prerendered tab has no answer yet. SPL-5276: in the
         Event log's order, Clear filters (desktop, a filter on) and then
         Refresh last, where Clear log is; a phone's Refresh is at the
         bottom centre, as its Clear log -->
    <ClientOnly>
      <Teleport to="#monitoring-head-actions" defer>
        <span v-if="view" class="ln-age" :data-stale="stale" data-test="lanes-age">{{ t('monitoring.tokens.updated', { n: lag }) }}</span>
        <button v-if="view && view.lanes.length && !phone && filtered" type="button" class="btn ghost" data-test="lanes-filter-clear" @click="clearFilters()">{{ t('issues.filter_clear') }}</button>
        <button v-if="!phone" type="button" class="btn ln-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="lanes-refresh" @click="refresh()">
          <UiIcon name="refresh" class="mh-icon" /><span class="mh-label">{{ t('monitoring.tokens.refresh') }}</span>
        </button>
      </Teleport>
    </ClientOnly>
    <!-- the red stale line and "shown n of total" stay above the table, a row only while one shows -->
    <div v-if="view && (stale === 'red' || filtered)" class="ln-head">
      <span v-if="stale === 'red'" class="ln-stale" role="status" data-test="lanes-stale-red">{{ t('monitoring.lanes.stale_red') }}</span>
      <span v-if="filtered" class="ln-age" role="status" data-test="lanes-shown">{{ t('monitoring.lanes.shown', { n: rows.length, total: view.lanes.length }) }}</span>
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
        <SheetPhoneBar
          v-if="phone"
          :columns="sheetColumns"
          :sort="sort"
          :filters="filters"
          prefix="lanes"
          :sort-words="sortWords"
          :filters-on="filtered"
          @sort="toggleSort"
          @filter="onFilter"
          @clear="clearFilters"
        />
        <table class="ln-table" :aria-label="t('monitoring.lanes.table_label')" data-test="lanes-table">
          <SheetHead :columns="sheetColumns" :sort="sort" :filters="filters" :phone="phone" prefix="lanes" @sort="toggleSort" @filter="onFilter" />
          <tbody>
            <tr v-if="rows.length === 0">
              <td :colspan="sheetColumns.length" class="muted" data-test="lanes-no-match">{{ t('monitoring.lanes.no_match') }}</td>
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
              <!-- 3.20 (SPL-4810): the lane opens in a dialog, its console at the end -->
              <th scope="row" class="ln-id" data-test="lanes-agent"><button type="button" class="ln-open" :title="t('monitoring.lanes.console.open_title')" data-test="lanes-open" @click="openLane(l)">{{ laneName(l) }}</button></th>
              <td class="ln-box" data-test="lanes-box">{{ l.box || DASH }}</td>
              <td class="num" data-test="lanes-priority" :data-priority="l.priority || undefined">
                <span v-if="l.priority" class="ln-prio" :class="'ln-prio--' + l.priority">{{ l.priority }}</span>
                <span v-else class="muted">{{ DASH }}</span>
              </td>
              <td data-test="lanes-vendor">{{ l.vendor || DASH }}</td>
              <td data-test="lanes-state" :data-state="l.state">{{ stateLabel(l.state) }}</td>
              <td class="ln-cut" :title="l.scope || undefined" data-test="lanes-scope">{{ l.scope || DASH }}</td>
              <td class="ln-cut" :title="l.topicTitle || l.topicId || undefined" data-test="lanes-topic">
                <NuxtLink v-if="topicTo(l).href" :to="toOf(topicTo(l))" data-test="lanes-topic-link">{{ l.topicTitle || l.topicId }}</NuxtLink>
                <span v-else-if="l.topicId" class="ln-mono">{{ l.topicId }}</span>
                <span v-else-if="l.roleSeat" class="muted" data-test="lanes-role-seat">{{ t('monitoring.lanes.role_seat') }}</span>
                <span v-else class="muted">{{ DASH }}</span>
              </td>
              <td :title="l.issues.map((i: { key: string }) => i.key).join(', ') || undefined" data-test="lanes-issues">
                <span v-if="l.issues.length === 0 && l.roleSeat" class="muted" data-test="lanes-role-seat">{{ t('monitoring.lanes.role_seat') }}</span>
                <span v-else-if="l.issues.length === 0" class="muted">{{ DASH }}</span>
                <template v-for="i in l.issues" :key="i.key">
                  <NuxtLink v-if="issueTo(i, l).href" class="ln-issue" :to="toOf(issueTo(i, l))" :title="i.status || undefined" data-test="lanes-issue-link">{{ i.key }}</NuxtLink>
                  <span v-else class="ln-issue" data-test="lanes-issue">{{ i.key }}</span>
                </template>
              </td>
              <td data-test="lanes-origin">
                <template v-if="l.originIssue">
                  <NuxtLink v-if="issueTo(l.originIssue, l).href" class="ln-issue" :to="toOf(issueTo(l.originIssue, l))" :title="l.originIssue.status || undefined" data-test="lanes-origin-link">{{ l.originIssue.key }}</NuxtLink>
                  <span v-else class="ln-issue">{{ l.originIssue.key }}</span>
                </template>
              </td>
              <td class="num" :title="t('monitoring.lanes.col_updated')" data-test="lanes-updated">{{ ago(l.updatedAt) }}</td>
              <td class="num" :title="t('monitoring.tokens.col_last')" data-test="lanes-active">{{ ago(l.lastActive) }}</td>
              <td class="ln-ws" :title="l.workspace || undefined" data-test="lanes-workspace">{{ l.workspaceName || DASH }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
    <!-- the room the phone's Refresh needs under the last card -->
    <div v-if="phone" class="ln-dock-room" aria-hidden="true" />
    <PhoneDockButton v-if="phone" class="ln-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="lanes-refresh" @click="refresh()">
      {{ t('monitoring.tokens.refresh') }}
    </PhoneDockButton>
    <LaneDialog
      v-if="opened"
      :open="!!opened"
      :title="laneName(opened)"
      :agent-id="opened.agentId"
      :agent-box="opened.box"
      :live="opened.state === 'live'"
      :own="openedOwn"
      :fields="openedFields"
      @close="opened = null"
    />
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOperatorReader } from '~/composables/useOperatorReader'
import { useAccessStore } from '~/stores/access'
import { gateMe, lanesReadPlan } from '~/utils/read-gates.mjs'
import { lagSeconds } from '~/utils/monitoring-tokens.mjs'
import { LANE_AGE_COLUMNS, LANE_AGES, LANE_QUERY, LANE_SHEET_COLUMNS, LANES_DEFAULT_SORT, LANES_NO_FILTER, filterLanes, fleetLanesOf, laneFilterChoices, laneIssueRef, laneName, laneTopicRef, lanesFiltered, lanesStaleLevel, minutesAgo, readLanes, sortLanes, startLanesPoll } from '~/utils/monitoring-lanes.mjs'
import { lanesFiltersOffered, lanesStateFromQuery, lanesStateQuery, plainQuery, sameLanesQuery } from '~/utils/monitoring-lanes-url.mjs'
import { nextSheetSort, sheetSortLabel } from '~/utils/column-sheet.mjs'
import { usePhone } from '~/composables/useTouchUi'
import { useLaneLinks, type LaneLink } from '~/composables/useLaneLinks'

type LanesApi = { getFleetLanes: (own?: boolean) => Promise<unknown> }
type LanesView = ReturnType<typeof fleetLanesOf>

const DASH = '—'
const { t } = useI18n({ useScope: 'global' })
const operatorReader = useOperatorReader()
const route = useRoute()
const phone = usePhone()
/* SPL-4798: a row's ids as links, on the host of the workspace they belong to */
const { pageTenant, linkOf } = useLaneLinks()
const topicTo = (l: LanesView['lanes'][number]) => linkOf(laneTopicRef(l, pageTenant.value))
const issueTo = (i: { key: string, status: string }, l: LanesView['lanes'][number]) => linkOf(laneIssueRef(i, l, pageTenant.value))
/** this host: the router's path; another workspace's host: the whole address */
const toOf = (to: LaneLink) => (to.here ? to.path : to.href)
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

/* the sheet's columns, the sort (none = the hub's order) and one filter per
   column: the Event log's (SPL-5276, utils/column-sheet.mjs) */
const COLUMN_EXTRA: Record<string, { cls?: string, test?: string }> = {
  box: { test: 'lanes-col-box' },
  priority: { cls: 'num', test: 'lanes-col-priority' },
  origin: { test: 'lanes-col-origin' },
  updated: { cls: 'num' },
  active: { cls: 'num' },
  workspace: { test: 'lanes-col-workspace' },
}
const sort = ref<{ col: string, dir: string }>({ col: '', dir: '' })
function toggleSort(col: string) {
  sort.value = nextSheetSort(col, sort.value, LANE_SHEET_COLUMNS)
}
const filters = reactive<Record<string, string>>({ ...LANES_NO_FILTER })
const filtered = computed(() => lanesFiltered(filters))
function onFilter(col: string, value: string) {
  filters[col] = value
}
function clearFilters() {
  Object.assign(filters, LANES_NO_FILTER)
}
const choices = computed(() => laneFilterChoices(view.value ? view.value.lanes : []))
/** a choice column's options: the answer's values, in words where the page has them */
function choicesOf(col: string): { value: string, label: string }[] {
  if (LANE_AGE_COLUMNS.includes(col)) return LANE_AGES.map((a) => ({ value: a, label: ageLabel(a) }))
  if (col === 'workspace') return choices.value.workspace.map((w) => ({ value: w.id, label: w.name }))
  if (col === 'state') return choices.value.state.map((v) => ({ value: v, label: stateLabel(v) }))
  const list: string[] = (choices.value as unknown as Record<string, string[]>)[col] || []
  return list.map((v) => ({ value: v, label: v }))
}
const sheetColumns = computed(() => LANE_SHEET_COLUMNS.map((c) => ({
  col: c.col,
  label: t(c.key),
  kind: c.kind,
  choices: c.kind === 'choice' ? choicesOf(c.col) : undefined,
  ...COLUMN_EXTRA[c.col],
})))
const sortWords = computed(() => {
  const bits = sheetSortLabel(sort.value, LANE_SHEET_COLUMNS, LANES_DEFAULT_SORT)
  return t('issues_mobile.sort_now', { col: t(bits.colKey), dir: t(bits.dirKey) })
})
const rows = computed(() => (view.value ? sortLanes(filterLanes(view.value.lanes, filters, view.value.asOf), sort.value) : []))

/* the sort and the filters follow the address and back (3.15, SPL-4729) */
const router = useRouter()
const listPath = route.path
/* replaces on their way: the route still names the state before them */
let writing = 0
/** the address's sort and filters, each value the answer does not offer set back to All */
function readUrl() {
  const q = lanesStateFromQuery(route.query)
  if (q.sort.col !== sort.value.col || q.sort.dir !== sort.value.dir) sort.value = q.sort
  const f = view.value ? lanesFiltersOffered(q.filters, choices.value) : q.filters
  const now: Record<string, string> = filters
  if (Object.entries(f).some(([k, v]) => now[k] !== v)) Object.assign(filters, f)
}
function writeUrl() {
  if (!import.meta.client || router.currentRoute.value.path !== listPath) return
  const base = plainQuery(route.query)
  const next = lanesStateQuery({ sort: sort.value, filters }, base)
  if (sameLanesQuery(next, base)) return
  writing++
  const done = () => { writing-- }
  router.replace({ query: next }).then(done, done)
}
readUrl()
/* SPL-5276: closing a phone sheet steps Back over the sheet's history entry.
   vue-router hears that popstate before useMobileStack's capture listener
   (at the window, listeners fire in the order they were added: Chrome 154),
   so the route moves to the entry under the sheet, without the sort or filter
   just picked, while the stack puts the sheet's address back. The address
   bar wins: the router follows it, and the page keeps what was picked.
   The router's own history.location is the popped entry too, so the check
   reads the address bar (window.location), less the router's base.
   The router's navigation and this watcher can both settle in the microtask
   checkpoint between the two popstate listeners (seen under load: e2e P5b
   at 320 px), before the stack has put the address back; so the check runs
   once more after the event (setTimeout 0), and the router follows then. */
function addressNow() {
  const base = router.options.history.base || ''
  const path = window.location.pathname
  return (base && path.startsWith(base) ? path.slice(base.length) || '/' : path) + window.location.search + window.location.hash
}
function routeLagsAddress() {
  return import.meta.client && router.resolve(addressNow()).fullPath !== router.currentRoute.value.fullPath
}
function followAddress() {
  if (router.currentRoute.value.path === listPath && routeLagsAddress()) void router.replace(addressNow())
}
watch(() => route.query, () => {
  if (import.meta.client) setTimeout(followAddress, 0)
  if (writing) return
  if (routeLagsAddress()) return void router.replace(addressNow())
  readUrl()
})
watch([sort, filters], writeUrl, { deep: true })
/* the first answer checks the link's values against what it offers */
let offeredChecked = false
watch(view, (v) => {
  if (!v || offeredChecked) return
  offeredChecked = true
  Object.assign(filters, lanesFiltersOffered({ ...filters }, choices.value))
  /* SPL-5276: the address names what the page shows from its first answer on:
     an old link's ?age= becomes ?updated=, its ?text= goes (nothing else
     writes it while no sort or filter changes) */
  writeUrl()
})
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

const access = useAccessStore()
let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    const api = useSpoolApi() as unknown as LanesApi
    /* SPL-4453: /v1/view/me picks the read; a member sends none and gets the line */
    const plan = lanesReadPlan(await gateMe(access))
    if (mine !== seq) return
    lanesRead.operatorVisible = operatorReader.value
    if (plan === 'none') {
      view.value = null
      state.value = 'forbidden'
      return
    }
    if (plan === 'own') lanesRead.own = true
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

/* 3.20 (SPL-4810; owner HUM-10, t1 27162335): a row opens its lane in a
   dialog (lazy: never in the first chunk), the way an issue opens from the
   Issues sheet; the console is inside it. The minute's refresh updates it. */
const LaneDialog = defineAsyncComponent(() => import('~/components/monitoring/LaneDialog.vue'))
type Lane = LanesView['lanes'][number]
const opened = ref<Lane | null>(null)
const openedOwn = ref(false)
function openLane(l: Lane) {
  openedOwn.value = lanesRead.own
  opened.value = l
}
watch(view, (v) => {
  const o = opened.value
  const now = o && v ? v.lanes.find((l) => laneName(l) === laneName(o)) : null
  if (now) opened.value = now
})
const openedFields = computed(() => {
  const l = opened.value
  if (!l) return []
  const topic = l.topicTitle || l.topicId || DASH
  return [
    { test: 'box', label: t('monitoring.lanes.col_box'), value: l.box || DASH },
    { test: 'priority', label: t('issues.field_priority'), value: l.priority ? String(l.priority) : DASH },
    { test: 'vendor', label: t('monitoring.tokens.col_vendor'), value: l.vendor || DASH },
    { test: 'state', label: t('monitoring.lanes.col_state'), value: stateLabel(l.state) },
    { test: 'scope', label: t('monitoring.lanes.col_scope'), value: l.scope || DASH },
    { test: 'topic', label: t('issues.discussion'), value: topic },
    { test: 'issues', label: t('issues.title'), value: l.issues.map((i: { key: string }) => i.key).join(', ') || DASH },
    { test: 'origin', label: t('monitoring.lanes.col_origin_issue'), value: l.originIssue ? l.originIssue.key : DASH },
    { test: 'updated', label: t('monitoring.lanes.col_updated'), value: ago(l.updatedAt) },
    { test: 'active', label: t('monitoring.tokens.col_last'), value: ago(l.lastActive) },
    { test: 'workspace', label: t('sidebar.tenant'), value: l.workspaceName || DASH },
  ]
})

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
/* the table scrolls sideways inside itself, never the page (3.2, as .tk-table-wrap); a phone reads cards (3.25, below) */
.ln-table-wrap { overflow-x: auto; max-width: 100%; }
.ln-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.ln-table :deep(th), .ln-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.ln-table :deep(.num) { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.ln-row[data-selected="1"] > * { background: var(--color-selected); }
.ln-id { font-family: var(--font-mono); font-weight: 600; white-space: nowrap; }
/* the agent opens its lane's dialog (3.20): a link-like button, the cell's text kept */
.ln-open { padding: 0; border: 0; background: none; font: inherit; color: var(--color-accent); cursor: pointer; text-align: start; }
.ln-open:hover { text-decoration: underline; }
.ln-mono { font-family: var(--font-mono); }
/* the box name is short: one line, never dropped (phone too) */
.ln-box { font-family: var(--font-mono); white-space: nowrap; }
/* a long scope or topic stays on one line, its full text in the title (3.2) */
.ln-cut { max-width: 280px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ln-issue { margin-inline-end: 6px; white-space: nowrap; font-family: var(--font-mono); }
/* the filter row under the names is SheetHead.vue's, as the Event log's
   (SPL-5276); a filter keeps a usable width in the auto-width table */
.ln-table :deep(.sheet-filter) { min-width: 5rem; max-width: 16rem; }
/* the room under the last card for the phone's Refresh (PhoneDockButton) */
.ln-dock-room { height: calc(var(--tap, 44px) + 16px); }
/* the prio, coloured as on the Issues sheet (3.14) */
.ln-prio { font-weight: 600; font-variant-numeric: tabular-nums; }
.ln-prio--1 { color: var(--color-danger); }
.ln-prio--2 { color: var(--color-warn); }
.ln-prio--3 { color: var(--color-accent); }
.ln-prio--4, .ln-prio--5 { color: var(--color-muted); }
/* the workspace, the last column (3.8): it may wrap, never dropped (phone too) */
.ln-ws { min-width: 6rem; overflow-wrap: anywhere; }

/* 3.25 (SPL-5235; owner HUM-10, t1 389ad5fd, msg e3fad8e4): on a phone
   (the one 820 px breakpoint) the same table reads as a list of dense
   cards, the whole width, nothing scrolls sideways. The Event log's phone
   bar sorts and filters above it (SPL-5276); each row is a card of three short lines:
     1  prio  agent@box  vendor  state ............ updated
     2  discussion (cut) ................... issues  origin
     3  scope (cut) ......... box  workspace (cut)  last active
   Every cell, link, data-test and the row's click stay as on the desktop. */
@media (max-width: 820px) {
  .ln-table-wrap { overflow-x: visible; }
  .ln-table, .ln-table tbody { display: block; width: 100%; }
  /* SPL-5276: the names stay in the DOM for readers, visually hidden, as
     the Event log's cards; the bar above (SheetPhoneBar) sorts and filters */
  .ln-table thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
  .ln-table tbody tr { display: block; }
  .ln-table tbody .ln-row { display: flex; flex-wrap: wrap; align-items: baseline; gap: 2px 6px; padding: 6px 2px; font-size: 0.8125rem; border-bottom: 1px solid var(--color-border); }
  .ln-row > th, .ln-row > td { padding: 0; border: 0; min-width: 0; }
  .ln-row > td:empty { display: none; }
  .ln-row[data-selected="1"] { background: var(--color-selected); }
  /* the two line breaks between the card's three lines */
  .ln-row::before, .ln-row::after { content: ""; flex: 0 0 100%; height: 0; }
  .ln-row::before { order: 10; }
  .ln-row::after { order: 20; }
  .ln-row > [data-test=lanes-priority] { order: 1; }
  .ln-row > .ln-id { order: 2; }
  .ln-row > [data-test=lanes-vendor] { order: 3; color: var(--color-muted); }
  .ln-row > [data-test=lanes-state] { order: 4; }
  .ln-row > [data-test=lanes-updated] { order: 5; margin-inline-start: auto; color: var(--color-muted); }
  /* the two cut cells take what the line leaves, down to their basis */
  .ln-row > [data-test=lanes-topic] { order: 11; flex: 1 1 5rem; max-width: none; }
  /* the keys stay on line 2, on one line, at most 45 % of it; the rest is
     cut, every key in the cell's title and the LaneDialog (W1: they stacked
     one per line, 4..6 lines at 320 px with 3+ keys) */
  .ln-row > [data-test=lanes-issues] { order: 12; flex: 0 1 auto; max-width: 45%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ln-row > [data-test=lanes-origin] { order: 13; }
  .ln-row .ln-issue { font-size: 0.75rem; }
  .ln-row .ln-issue:last-child { margin-inline-end: 0; }
  .ln-row > [data-test=lanes-scope] { order: 21; flex: 1 1 3rem; max-width: none; color: var(--color-muted); }
  .ln-row > .ln-box { order: 22; color: var(--color-muted); }
  .ln-row > .ln-ws { order: 23; flex: 0 1 auto; min-width: 0; max-width: 35%; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ln-row > [data-test=lanes-active] { order: 24; color: var(--color-muted); }
}
</style>
