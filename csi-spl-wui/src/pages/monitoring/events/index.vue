<!-- Personal event log (topic 4335f075). SPL-3250 (owner HUM-10, t1
     463d7692, msgs 24316f72 + ac1c95f9): Monitoring -> Events, the page that
     was the Event log rail section (pages/events.vue, which now redirects
     here); same rows, same Clear log, for everyone as before.

     Lists GET /api/v1/auth/events via createEventsClient.
     Signed-out shows the catalogue line and never POSTs. A failed read
     is a sentence, never written back into the journal.

     SPL-3366: sort and filter the rows this page already holds. The list
     call stays limit and before. A hash row stays visible when a filter
     would hide it. Clear log still clears the whole personal log.

     Spec 162 B1: the request and code columns (E1), When as ISO 8601 with
     seconds and the viewer's offset (E7), and Clear log asks first (E2). -->
<template>
  <div class="monitoring-events" data-test="events-page">
    <!-- a desktop's Clear log sits in the Monitoring header row, top right,
         where the old /events page had it (SPL-2093 keeps the phone's at the
         bottom centre, below); client only: the prerendered tab has no rows -->
    <ClientOnly>
      <Teleport to="#monitoring-head-actions" defer>
        <button
          v-if="signedIn && !phone && filtersOn"
          type="button"
          class="btn ghost"
          data-test="events-filter-clear"
          @click="clearFilters"
        >{{ t('issues.filter_clear') }}</button>
        <button
          v-if="signedIn && rows.length && !phone"
          type="button"
          class="btn"
          data-test="events-clear"
          :disabled="busy"
          @click="onClear"
        >{{ t('events.clear') }}</button>
      </Teleport>
    </ClientOnly>
    <div class="events-body">
      <p v-if="session.state === 'loading'" class="muted" data-test="events-loading">{{ t('common.loading') }}</p>
      <p v-else-if="!signedIn" class="muted" data-test="events-signed-out">{{ t('events.signed_out') }}</p>
      <p v-else-if="loadError" class="events-error" role="alert" data-test="events-error">{{ t(loadError) }}</p>
      <p v-else-if="loading" class="muted" data-test="events-loading">{{ t('common.loading') }}</p>
      <p v-else-if="!rows.length" class="muted" data-test="events-empty">{{ t('events.empty') }}</p>
      <div v-else class="events-table-wrap">
        <div v-if="phone" class="events-mbar" data-test="events-mbar">
          <span class="events-mbar__sorted muted" data-test="events-sorted-by" :data-sort="sort.col" :title="sortWords">{{ t('issues_mobile.sorted_by', { sort: sortWords }) }}</span>
          <button type="button" class="btn ghost events-mbar__btn" data-test="events-sort-open" :aria-label="t('issues_mobile.sort')" :title="t('issues_mobile.sort')" aria-haspopup="dialog" @click="openSort">
            <UiIcon name="sort" :size="20" />
          </button>
          <button type="button" class="btn ghost events-mbar__btn" data-test="events-filters-open" :data-active="filtersOn ? 'true' : 'false'" :aria-label="t('issues_mobile.filters')" :title="t('issues_mobile.filters')" aria-haspopup="dialog" @click="openFilters">
            <UiIcon name="filter" :size="20" />
            <i v-if="filtersOn" class="events-mbar__dot" aria-hidden="true" />
          </button>
        </div>
        <table class="events-table" data-test="events-table">
          <thead :data-test="phone ? undefined : 'events-filters'">
            <tr>
              <th v-for="c in EVENT_COLUMNS" :key="c.col" scope="col" :aria-sort="phone ? undefined : ariaSort(c.col)">
                <button
                  v-if="!phone"
                  type="button"
                  class="events-sort-h"
                  :data-test="'events-sort-' + c.col"
                  :data-sorted="sort.col === c.col ? sort.dir : undefined"
                  @click="onHeaderSort(c.col)"
                >{{ t(c.key) }}<span class="events-sort-mark" aria-hidden="true">{{ sortMark(c.col) }}</span></button>
                <template v-else>{{ t(c.key) }}</template>
              </th>
            </tr>
            <tr v-if="!phone" class="events-frow">
              <th v-for="c in EVENT_COLUMNS" :key="'f-' + c.col" class="events-filter-h">
                <input
                  v-if="c.kind === 'text'"
                  v-model="filters[c.col]"
                  type="text"
                  class="events-filter"
                  :data-test="'events-filter-' + c.col"
                  :aria-label="t(c.key)"
                >
                <select
                  v-else
                  v-model="filters[c.col]"
                  class="events-filter"
                  :data-test="'events-filter-' + c.col"
                  :aria-label="t(c.key)"
                >
                  <option value="">{{ t('issues.filter_all') }}</option>
                  <option v-for="v in choicesFor(c.col)" :key="v" :value="v">{{ v }}</option>
                </select>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in view" :id="r.id > 0 ? String(r.id) : undefined" :key="r.id" data-test="events-row" :class="{ 'events-row--focus': route.hash === '#' + r.id }">
              <td dir="ltr" :data-label="t('events.col_when')"><time :datetime="utcOf(r) || undefined" :title="utcOf(r) || undefined" data-test="events-when">{{ whenOf(r) }}</time></td>
              <td :data-label="t('events.col_id')"><code dir="ltr">{{ r.error_id }}</code></td>
              <td dir="ltr" :data-label="t('events.col_source')">{{ r.source }}</td>
              <td dir="ltr" :data-label="t('events.col_status')">{{ r.status ? String(r.status) : '' }}</td>
              <td :data-label="t('events.col_request')" data-test="events-request"><code v-if="eventRequestText(r)" dir="ltr" :title="r.origin || undefined">{{ eventRequestText(r) }}</code></td>
              <td :data-label="t('events.col_code')" data-test="events-code"><span class="events-code"><code v-if="r.code" dir="ltr">{{ r.code }}</code><code v-if="r.name" dir="ltr" class="events-code__name">{{ r.name }}</code></span></td>
              <td :data-label="t('events.col_message')" data-test="events-message">{{ r.message }}</td>
              <td :data-label="t('events.col_route')"><code dir="ltr">{{ r.route }}</code></td>
            </tr>
          </tbody>
        </table>
        <p v-if="!view.length" class="muted" data-test="events-no-match">{{ t('release_notes.no_match') }}</p>
        <button
          v-if="nextBefore"
          type="button"
          class="btn ghost"
          data-test="events-load-more"
          :disabled="busy"
          @click="loadMore"
        >{{ t('events.load_more') }}</button>
      </div>
      <!-- SPL-2093 (owner, t1 04d9c246): on a phone Clear log sits at the
           bottom centre, just above the dock; this spacer lets the last card
           scroll clear of it -->
      <div v-if="phone && signedIn && rows.length" class="events-clear-room" aria-hidden="true" />
    </div>
    <button
      v-if="phone && signedIn && rows.length"
      type="button"
      class="btn events-clear--phone"
      data-test="events-clear"
      :disabled="busy"
      @click="onClear"
    >{{ t('events.clear') }}</button>
    <UiConfirm
      v-if="clearOpen"
      :open="clearOpen"
      :title="t('events.clear_confirm_title')"
      testid="events-clear-confirm"
      :confirm-label="t('events.clear')"
      :busy-label="t('events.clear')"
      :busy="busy"
      :error="clearError ? t(clearError) : ''"
      @update:open="clearOpen = $event"
      @confirm="onConfirmClear"
    >
      <p>{{ t('events.clear_confirm_body', { n: rows.length }) }}</p>
      <p v-if="nextBefore" data-testid="events-clear-confirm-older">{{ t('events.clear_confirm_older') }}</p>
    </UiConfirm>
    <template v-if="phone && (filtersOpen || sortOpen)">
      <div class="events-sheet-scrim" data-test="events-sheet-scrim" @pointerdown.stop @click="closeSheets" />
      <section v-if="sortOpen" class="events-sheet" role="dialog" aria-modal="false" data-test="events-sort-sheet" :aria-label="t('issues_mobile.sort')">
        <header class="events-sheet__h">
          <UiCloseButton side="start" :size="20" class="events-sheet__x" @click="closeSheets" />
          <h3>{{ t('issues_mobile.sort') }}</h3>
          <UiCloseButton side="end" :size="20" class="events-sheet__x" @click="closeSheets" />
        </header>
        <p class="events-sort-now" data-test="events-sort-now">{{ sortWords }}</p>
        <button
          v-for="c in EVENT_COLUMNS"
          :key="c.col"
          type="button"
          class="events-sort-opt"
          :data-test="'events-sort-' + c.col"
          :aria-pressed="sort.col === c.col ? 'true' : 'false'"
          @click="onHeaderSort(c.col)"
        >
          <span>{{ t(c.key) }}</span>
          <span aria-hidden="true">{{ sortMark(c.col) }}</span>
        </button>
      </section>
      <section v-if="filtersOpen" class="events-sheet" role="dialog" aria-modal="false" data-test="events-filters" :aria-label="t('issues_mobile.filters')">
        <header class="events-sheet__h">
          <UiCloseButton side="start" :size="20" class="events-sheet__x" @click="closeSheets" />
          <h3>{{ t('issues_mobile.filters') }}</h3>
          <UiCloseButton side="end" :size="20" class="events-sheet__x" @click="closeSheets" />
        </header>
        <label v-for="c in EVENT_COLUMNS" :key="c.col" class="events-sheet__f">
          <span>{{ t(c.key) }}</span>
          <input
            v-if="c.kind === 'text'"
            v-model="filters[c.col]"
            type="text"
            class="events-filter"
            :data-test="'events-filter-' + c.col"
            :aria-label="t(c.key)"
          >
          <select
            v-else
            v-model="filters[c.col]"
            class="events-filter"
            :data-test="'events-filter-' + c.col"
            :aria-label="t(c.key)"
          >
            <option value="">{{ t('issues.filter_all') }}</option>
            <option v-for="v in choicesFor(c.col)" :key="v" :value="v">{{ v }}</option>
          </select>
        </label>
        <div class="events-sheet__foot">
          <button type="button" class="btn ghost" data-test="events-filter-clear" @click="clearFilters">{{ t('issues.filter_clear') }}</button>
        </div>
      </section>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { createEventsClient, eventsErrorKey } from '~/utils/event-log.mjs'
import { isoDateTimeOffset } from '~/utils/date-iso-offset.mjs'
import { formatIsoTs } from '~/utils/channel-feed.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { eventRowsOf } from '~/utils/event-rows.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import { usePhone } from '~/composables/useTouchUi'
import {
  EVENT_COLUMNS,
  applyEventSheet,
  emptyEventFilters,
  emptyEventSort,
  eventRequestText,
  eventSortLabel,
  filtersActive as sheetFiltersActive,
  nextEventSort,
  presentValues,
} from '~/utils/event-sheet.mjs'

type EventRow = ReturnType<typeof eventRowsOf>[number]
type EventSort = { col: string, dir: string }

const EVENTS_PAGE = 30

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const session = useSessionStore()
const phone = usePhone()
const stack = useMobileStack()
const client = createEventsClient({ base: useAuthBase() })
const signedIn = computed(() => session.state === 'in')

const rows = ref<EventRow[]>([])
const nextBefore = ref(0)
const loading = ref(false)
const busy = ref(false)
const loadError = ref('')
const clearOpen = ref(false)
const clearError = ref('')
const sort = ref<EventSort>(emptyEventSort())
const filters = ref<Record<string, string>>(emptyEventFilters())
const sortOpen = ref(false)
const filtersOpen = ref(false)
/* SPL-994: each sheet is the top level while open. Back closes it first. */
stack.overlay(() => phone.value && filtersOpen.value, () => { filtersOpen.value = false })
stack.overlay(() => phone.value && sortOpen.value, () => { sortOpen.value = false })

const pinId = computed(() => {
  const hash = decodeURIComponent(String(route.hash || '').replace(/^#/, ''))
  return /^[1-9][0-9]*$/.test(hash) ? hash : ''
})
const view = computed(() => applyEventSheet(rows.value, {
  sort: sort.value,
  filters: filters.value,
  pinId: pinId.value,
}))
const filtersOn = computed(() => sheetFiltersActive(filters.value))
const sortWords = computed(() => {
  const bits = eventSortLabel(sort.value)
  return t('issues_mobile.sort_now', { col: t(bits.colKey), dir: t(bits.dirKey) })
})

/* CLE-77908 (owner, 07b84fd7): stored UTC, shown in the person's own zone for
   this workspace (Settings -> Appearance, else the browser's); the hover and
   the <time datetime> keep the exact UTC instant, ISO 8601 with Z. Spec 162
   E7: the cell carries seconds and the offset; When sorts by eventInstant. */
function whenOf(r: EventRow) {
  const raw = r.at || r.received_at || ''
  return isoDateTimeOffset(raw) || raw
}
function utcOf(r: EventRow) {
  const raw = r.at || r.received_at || ''
  return raw ? formatIsoTs(raw) : ''
}

function ariaSort(col: string): 'ascending' | 'descending' | 'none' {
  if (sort.value.col !== col) return 'none'
  if (sort.value.dir === 'asc') return 'ascending'
  if (sort.value.dir === 'desc') return 'descending'
  return 'none'
}
function sortMark(col: string): string {
  if (sort.value.col !== col) return ''
  if (sort.value.dir === 'asc') return '▲'
  if (sort.value.dir === 'desc') return '▼'
  return ''
}
function onHeaderSort(col: string) {
  sort.value = nextEventSort(col, sort.value)
}
function clearFilters() {
  filters.value = emptyEventFilters()
}
function closeSheets() {
  sortOpen.value = false
  filtersOpen.value = false
}
function openSort() {
  filtersOpen.value = false
  sortOpen.value = true
}
function openFilters() {
  sortOpen.value = false
  filtersOpen.value = true
}
function resetSheet() {
  sort.value = emptyEventSort()
  clearFilters()
  closeSheets()
}
function choicesFor(field: string): string[] {
  return presentValues(rows.value, field)
}

async function load(before = 0, append = false) {
  if (!signedIn.value) {
    rows.value = []
    nextBefore.value = 0
    loadError.value = ''
    return
  }
  if (append) busy.value = true
  else loading.value = true
  loadError.value = ''
  /* owner 73c9704c: "use the last 30 entries ... to be quick and nimble" -
     a page of 30, Load more for older (it was 50) */
  const res = await client.list({ limit: EVENTS_PAGE, before })
  if (!res.ok) {
    loadError.value = eventsErrorKey(res.error)
    if (!append) rows.value = []
  } else {
    const page = eventRowsOf(res.data)
    rows.value = append ? [...rows.value, ...page] : page
    const nb = res.data && typeof res.data === 'object' ? Number((res.data as { next_before?: unknown }).next_before) : 0
    nextBefore.value = Number.isFinite(nb) && nb > 0 ? nb : 0
  }
  loading.value = false
  busy.value = false
}

function loadMore() {
  if (!nextBefore.value || busy.value) return
  void load(nextBefore.value, true)
}

/* Spec 162 E2: one tap used to wipe up to 500 rows; Clear log now asks
   first (UiConfirm), and only its OK POSTs. */
function onClear() {
  if (!signedIn.value || busy.value) return
  clearError.value = ''
  clearOpen.value = true
}

async function onConfirmClear() {
  if (!signedIn.value || busy.value) return
  busy.value = true
  clearError.value = ''
  const res = await client.clear()
  busy.value = false
  if (!res.ok) {
    clearError.value = eventsErrorKey(res.error)
    return
  }
  clearOpen.value = false
  rows.value = []
  nextBefore.value = 0
  resetSheet()
}

watch(() => session.state, (st) => {
  if (st === 'in') void load()
  else if (st === 'out') {
    rows.value = []
    nextBefore.value = 0
    loadError.value = ''
    clearOpen.value = false
    resetSheet()
  }
}, { immediate: true })

function revealEvent() {
  const hash = decodeURIComponent(String(route.hash || '').replace(/^#/, ''))
  if (!/^[1-9][0-9]*$/.test(hash)) return
  nextTick(() => {
    const el = document.getElementById(hash)
    const scroller = el?.closest<HTMLElement>('.feed-body')
    if (el && scroller) scrollRowToTop(scroller, el)
  })
}
watch(view, () => revealEvent())
watch(() => route.hash, () => revealEvent())
</script>

<style scoped>
.monitoring-events { min-width: 0; max-width: 100%; }
/* SPL-2093: the phone's Clear log, centred over the dock (and the strip
   under it, both in --composer-dock-h), above the keyboard when it is up;
   under the page sheets (z 38/39) and the dock itself */
.events-clear--phone {
  position: fixed;
  inset-inline-start: 50%;
  bottom: calc(var(--composer-dock-h, 0px) + var(--kb-inset, 0px) + 8px);
  z-index: 30;
  transform: translateX(-50%);
  min-height: var(--tap, 44px);
  box-shadow: 0 2px 8px rgb(0 0 0 / .3);
}
:global([dir="rtl"]) .events-clear--phone { transform: translateX(50%); }
.events-clear-room { height: calc(var(--tap, 44px) + 16px); }
.events-error {
  margin: 0;
  color: var(--color-danger);
  overflow-wrap: anywhere;
}
.events-table-wrap {
  max-width: 100%;
  min-width: 0;
  overflow-x: auto;
}
.events-table {
  width: 100%;
  table-layout: fixed;
  border-collapse: collapse;
  font-size: 0.875rem;
}
/* SPL-2120 (owner HUM-10, t1 28559e83 msg 68dd229e): the events alternate a
   lighter and a darker row, on a phone each card; the focused one (#<id>)
   keeps its selected fill over the shade. The filter row is a thead row, so
   the alternate fill stays on the body rows. */
.events-table tbody tr:nth-child(even) { background: var(--color-row-alt); }
.events-table tbody tr.events-row--focus { background: var(--color-selected); }
.events-table th,
.events-table td {
  text-align: start;
  padding: 0.4rem 0.6rem;
  border-bottom: 1px solid var(--color-border);
  overflow-wrap: anywhere;
  vertical-align: top;
}
.events-table th {
  font-size: 0.75rem;
  font-weight: 600;
  color: var(--color-muted);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.events-table code {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
}
/* the code cell: the code, then the error name on a second line */
.events-code { display: flex; flex-direction: column; min-width: 0; }
.events-code__name { color: var(--color-muted); }
.events-table-wrap .btn { margin-top: 0.75rem; }
.events-sort-h {
  display: inline-flex;
  align-items: center;
  gap: 0.25rem;
  max-width: 100%;
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  font-family: inherit;
  font-size: inherit;
  font-weight: inherit;
  line-height: inherit;
  letter-spacing: inherit;
  text-transform: inherit;
  cursor: pointer;
  text-align: start;
}
.events-sort-mark {
  display: inline-block;
  min-width: 0.75em;
  font-size: 0.625rem;
  color: var(--color-fg);
}
.events-filter-h {
  text-transform: none;
  letter-spacing: normal;
  font-weight: 400;
  vertical-align: middle;
}
.events-filter {
  width: 100%;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-bg);
  color: var(--color-fg);
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 0.15rem 0.35rem;
  font-family: inherit;
  font-size: 0.8125rem;
  font-weight: 400;
  line-height: 1.3;
}
/* the phone bar and the sheets mount only while usePhone() is on (<= 820px),
   which is wider than the card breakpoint below */
.events-mbar {
  display: flex;
  gap: 8px;
  padding: 0 12px 8px;
  align-items: center;
  min-width: 0;
}
.events-mbar__btn {
  position: relative;
  z-index: 0;
  flex: none;
  min-height: var(--tap, 44px);
  min-width: var(--tap, 44px);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
}
.events-mbar__btn.btn.ghost,
.events-mbar__btn.btn.ghost:active { border: 0; background: transparent; }
.events-mbar__btn::before {
  content: '';
  position: absolute;
  inset: 5px;
  z-index: -1;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
}
.events-mbar__sorted {
  flex: 1 1 auto;
  min-width: 0;
  font-size: 0.8125rem;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.events-mbar__dot {
  position: absolute;
  top: 8px;
  inset-inline-end: 8px;
  width: 8px;
  height: 8px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
}
.events-sheet-scrim {
  position: fixed;
  inset: 0;
  z-index: 38;
  background: rgb(0 0 0 / .4);
}
.events-sheet {
  position: fixed;
  inset-inline: 0;
  bottom: 0;
  left: 0;
  z-index: 39;
  width: 100%;
  min-width: 0;
  max-width: 100%;
  max-height: 75vh;
  max-height: 75dvh;
  overflow: auto;
  box-sizing: border-box;
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 8px 16px calc(16px + env(safe-area-inset-bottom, 0px));
  background: var(--color-surface);
  border: 1px solid var(--color-border-strong);
  border-bottom: 0;
  border-radius: var(--radius-md) var(--radius-md) 0 0;
  box-shadow: 0 -8px 24px rgb(0 0 0 / .3);
}
.events-sheet__h { display: flex; align-items: center; gap: 8px; }
.events-sheet__h h3 {
  flex: 1 1 auto;
  min-width: 0;
  margin: 0;
  font-size: 1rem;
  font-weight: 600;
  line-height: 1.3;
}
.events-sheet__x {
  min-width: var(--tap, 44px);
  min-height: var(--tap, 44px);
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.events-sheet__f {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
  font-size: 0.8125rem;
  color: var(--color-muted);
}
.events-sheet .events-filter {
  min-height: var(--tap, 44px);
  font-size: 1rem;
  line-height: 1.3;
}
.events-sheet__foot { display: flex; justify-content: flex-end; gap: 8px; }
.events-sheet__foot .btn { min-height: var(--tap, 44px); }
.events-sort-now { margin: 0; font-size: 0.875rem; font-weight: 600; line-height: 1.3; }
.events-sort-opt {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  min-height: var(--tap, 44px);
  width: 100%;
  margin: 0;
  padding: 0 8px;
  border: 0;
  background: transparent;
  color: inherit;
  font-family: inherit;
  font-size: 1rem;
  font-weight: 400;
  line-height: 1.3;
  text-align: start;
  cursor: pointer;
}
.events-table-wrap > .events-mbar + .events-table { margin-top: 0; }
/* SPL-993: on a phone each event is a card - its label beside each value,
   the column headers (still in the DOM for readers) visually hidden - so six
   columns never squeeze into one letter per line or widen the page. */
@media (max-width: 600px) {
  .events-table,
  .events-table tbody,
  .events-table tr,
  .events-table td { display: block; }
  .events-table thead {
    position: absolute;
    width: 1px;
    height: 1px;
    overflow: hidden;
    clip-path: inset(50%);
    white-space: nowrap;
  }
  .events-table tr {
    padding: 0.5rem 0.75rem;
    margin-bottom: 0.5rem;
    border: 1px solid var(--color-border);
    border-radius: var(--radius-md);
  }
  .events-table td {
    display: grid;
    grid-template-columns: 6.5rem minmax(0, 1fr);
    gap: 0.5rem;
    padding: 0.2rem 0;
    border-bottom: 0;
  }
  .events-table td::before {
    content: attr(data-label);
    font-size: 0.75rem;
    font-weight: 600;
    color: var(--color-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
  }
  .events-table-wrap { overflow-x: visible; }
  .events-table-wrap .btn { min-height: var(--tap, 44px); }
}
</style>
