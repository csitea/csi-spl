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
     seconds and the viewer's offset (E7), and Clear log asks first (E2).

     Spec 162 B7 (E5): a box per row and a page box, Gmail-style, with the
     Issues list's pure selection (utils/issues-bulk.ts). The selection holds
     row ids, survives sort and filter, and drops ids no longer held. With a
     row checked EventsBulkBar takes the head actions' place; Delete selected
     asks first, one POST /delete per 200 ids (utils/event-delete.ts). -->
<template>
  <div class="monitoring-events" data-test="events-page">
    <!-- a desktop's Clear log sits in the Monitoring header row, top right,
         where the old /events page had it (SPL-2093 keeps the phone's at the
         bottom centre, below); client only: the prerendered tab has no rows -->
    <ClientOnly>
      <Teleport to="#monitoring-head-actions" defer>
        <LazyEventsBulkBar
          v-if="signedIn && !phone && bulkOn"
          :count="selected.length"
          :page-state="bulkPage"
          :busy="busy"
          @toggle-page="togglePage"
          @delete="onDeleteSelected"
          @clear="clearSelection"
        />
        <button
          v-else-if="signedIn && !phone && filtersOn"
          type="button"
          class="btn ghost"
          data-test="events-filter-clear"
          @click="clearFilters"
        >{{ t('issues.filter_clear') }}</button>
        <button
          v-if="signedIn && rows.length && !phone && !bulkOn"
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
        <LazyEventsBulkBar
          v-if="phone && bulkOn"
          :count="selected.length"
          :page-state="bulkPage"
          :busy="busy"
          @toggle-page="togglePage"
          @delete="onDeleteSelected"
          @clear="clearSelection"
        />
        <SheetPhoneBar
          v-if="phone"
          ref="phoneBar"
          :columns="sheetColumns"
          :sort="sort"
          :filters="filters"
          prefix="events"
          :sort-words="sortWords"
          :filters-on="filtersOn"
          @sort="onHeaderSort"
          @filter="onFilter"
          @clear="clearFilters"
        />
        <table class="events-table" data-test="events-table">
          <SheetHead :columns="sheetColumns" :sort="sort" :filters="filters" :phone="phone" prefix="events" @sort="onHeaderSort" @filter="onFilter">
            <template #lead>
              <th scope="col" class="events-check-h">
                <input
                  ref="pageBoxEl"
                  type="checkbox"
                  class="events-check__box"
                  data-test="events-select-page"
                  :checked="bulkPage === 'all'"
                  :aria-label="t('events.select_page')"
                  :title="t('events.select_page')"
                  @click="togglePage"
                >
              </th>
            </template>
            <template #lead-filter>
              <th class="events-check-h" />
            </template>
          </SheetHead>
          <tbody>
            <tr v-for="r in view" :id="r.id > 0 ? String(r.id) : undefined" :key="r.id" data-test="events-row" :class="{ 'events-row--focus': route.hash === '#' + r.id }">
              <td class="events-check" :data-label="t('events.col_select')">
                <input
                  type="checkbox"
                  class="events-check__box"
                  data-test="events-row-check"
                  :checked="selSet.has(String(r.id))"
                  :aria-label="t('events.select_row', { id: r.error_id || String(r.id) })"
                  @click="onCheck(r, $event)"
                >
              </td>
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
    <PhoneDockButton
      v-if="phone && signedIn && rows.length && !bulkOn"
      data-test="events-clear"
      :disabled="busy"
      @click="onClear"
    >{{ t('events.clear') }}</PhoneDockButton>
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
    <UiConfirm
      v-if="deleteOpen"
      :open="deleteOpen"
      :title="t('events.delete_confirm_title', { n: selected.length })"
      testid="events-delete-confirm"
      :confirm-label="t('events.delete_selected')"
      :busy-label="t('events.delete_selected')"
      :busy="busy"
      :error="deleteError ? t(deleteError) : ''"
      @update:open="deleteOpen = $event"
      @confirm="onConfirmDelete"
    >
      <p>{{ t('events.delete_confirm_body') }}</p>
    </UiConfirm>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { createEventsClient, eventsErrorKey } from '~/utils/event-log.mjs'
import { deleteEventIds, eventsDeleteErrorKey } from '~/utils/event-delete'
import { keepShown, pageState, rangeSelect, toggleAll, toggleKey } from '~/utils/issues-bulk'
import { isoDateTimeOffset } from '~/utils/date-iso-offset.mjs'
import { formatIsoTs } from '~/utils/channel-feed.mjs'
import { scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { eventRowsOf } from '~/utils/event-rows.mjs'
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
/* SPL-5276: the head and the phone's bar and sheets are the column sheet's
   (components/SheetHead.vue, SheetPhoneBar.vue), shared with Lanes */
const phoneBar = ref<{ close: () => void } | null>(null)
const sheetColumns = computed(() => EVENT_COLUMNS.map((c) => ({
  col: c.col,
  label: t(c.key),
  kind: c.kind as 'text' | 'choice',
  choices: c.kind === 'choice' ? choicesFor(c.col).map((v) => ({ value: v, label: v })) : undefined,
})))

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

function onHeaderSort(col: string) {
  sort.value = nextEventSort(col, sort.value)
}
function onFilter(col: string, value: string) {
  filters.value = { ...filters.value, [col]: value }
}
function clearFilters() {
  filters.value = emptyEventFilters()
}
function resetSheet() {
  sort.value = emptyEventSort()
  clearFilters()
  if (phoneBar.value) phoneBar.value.close()
}
function choicesFor(field: string): string[] {
  return presentValues(rows.value, field)
}

/* Spec 162 B7 (E5): the selection is row ids as text, in the order checked.
   Sort and filter keep it; a row the page no longer holds leaves it. */
const selected = ref<string[]>([])
const selSet = computed(() => new Set(selected.value))
const bulkOn = computed(() => selected.value.length > 0)
const viewIds = computed(() => view.value.map((r) => String(r.id)))
const bulkPage = computed(() => pageState(selected.value, viewIds.value))
const pageBoxEl = ref<HTMLInputElement | null>(null)
const deleteOpen = ref(false)
const deleteError = ref('')
let checkAnchor = ''
watchEffect(() => { if (pageBoxEl.value) pageBoxEl.value.indeterminate = bulkPage.value === 'some' })
watch(rows, (list) => {
  const next = keepShown(selected.value, list.map((r) => String(r.id)))
  if (next !== selected.value) selected.value = next
})

/* a shift-click checks (or unchecks) the run from the last row clicked, in
   the order shown */
function onCheck(r: EventRow, ev: MouseEvent) {
  const id = String(r.id)
  const on = !selSet.value.has(id)
  selected.value = ev.shiftKey && checkAnchor
    ? rangeSelect(selected.value, viewIds.value, checkAnchor, id, on)
    : toggleKey(selected.value, id, on)
  checkAnchor = id
}
function togglePage() {
  selected.value = toggleAll(selected.value, viewIds.value)
}
function clearSelection() {
  selected.value = []
  checkAnchor = ''
}

function onDeleteSelected() {
  if (!signedIn.value || busy.value || !bulkOn.value) return
  deleteError.value = ''
  deleteOpen.value = true
}

/* the rows leave on the hub's answer; a failure is a sentence in the
   confirm and its rows stay */
async function onConfirmDelete() {
  if (!signedIn.value || busy.value || !bulkOn.value) return
  busy.value = true
  deleteError.value = ''
  const res = await deleteEventIds(client, selected.value)
  busy.value = false
  if (res.done.length) {
    const gone = new Set(res.done)
    rows.value = rows.value.filter((r) => !gone.has(r.id))
  }
  if (!res.ok) {
    deleteError.value = eventsDeleteErrorKey(res.error)
    return
  }
  deleteOpen.value = false
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
    deleteOpen.value = false
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
/* SPL-2093: the phone's Clear log is components/PhoneDockButton.vue */
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
.events-table :deep(th),
.events-table td {
  text-align: start;
  padding: 0.4rem 0.6rem;
  border-bottom: 1px solid var(--color-border);
  overflow-wrap: anywhere;
  vertical-align: top;
}
/* the names and filter row are SheetHead.vue's cells: :deep reaches them */
.events-table :deep(th) {
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
/* spec 162 B7: the box column, before When */
.events-table :deep(.events-check-h),
.events-table td.events-check { width: 2.25rem; }
.events-check__box {
  width: 18px;
  height: 18px;
  margin: 0;
  accent-color: var(--color-accent);
  cursor: pointer;
}
.events-table-wrap .btn { margin-top: 0.75rem; }
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
  /* the card's box row spans the card; a bigger box for a thumb */
  .events-table td.events-check { width: auto; align-items: center; }
  .events-check__box { width: 24px; height: 24px; }
}
</style>
