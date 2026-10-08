<!-- CLE-77799 (owner topic 1fc29f99: "the admin should be able to see ... the
     main event log activities for this person, when he has logged in, and
     logged out etc." + "use some nice alternating color tables ... default
     order newer on the top" + "the similar way how the filtering and sorting
     work for the issues table"): the admin-only per-person Activity log.

     A zebra table in the Release Log's look (t1 06c39172), newest-first, with a header-click sort and a per-column
     Event filter (the Issues table's interaction), and a masked-IP column.
     Slice 1 shows the act-as trail (GET /v1/audit/clones, real data); slices 2
     and 3 add membership and auth events into the same rows. audit.read only;
     the hub is the authority. -->
<template>
  <UiDialog :open="open" size="xl" :title="t('activity.title')" @update:open="emit('update:open', $event)">
    <div class="act" :class="{ 'act--phone': narrow }" data-test="person-activity">
      <div class="act__bar">
        <label class="act__filter">
          <span class="act__label">{{ t('activity.col.event') }}</span>
          <select v-model="kindF" class="act__select" data-test="activity-filter-kind">
            <option value="">{{ t('activity.filter_all') }}</option>
            <option v-for="k in kindsPresent" :key="k" :value="k">{{ t('activity.kinds.' + k) }}</option>
          </select>
        </label>
        <button v-if="kindF" type="button" class="btn ghost act__action" data-test="activity-filter-clear" @click="kindF = ''">
          <UiIcon name="x" :size="16" /> {{ t('activity.filter_clear') }}
        </button>
      </div>

      <p v-if="loading" class="muted act__msg" data-test="activity-loading">{{ t('activity.loading') }}</p>
      <p v-else-if="error" class="act__msg act__error" role="alert" data-test="activity-error">{{ error }}</p>
      <p v-else-if="shown.length === 0" class="muted act__msg" data-test="activity-empty">{{ t('activity.none') }}</p>

      <div v-else class="act-card act-table-wrap" data-test="activity-card">
        <table class="act-table" data-test="activity-table">
          <thead v-if="!narrow">
            <tr>
              <th v-for="c in COLUMNS" :key="c.col" scope="col" :class="'act-table__' + c.col" :aria-sort="ariaSort(c.col)">
                <button v-if="c.sortable" type="button" class="act-sort" :data-testid="'activity-sort-' + c.col" @click="toggleSort(c.col)">
                  {{ t('activity.col.' + c.col) }}<span class="act-sort__mark">{{ sortMark(c.col) }}</span>
                </button>
                <span v-else>{{ t('activity.col.' + c.col) }}</span>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(r, i) in shown" :key="i" class="act-row" data-test="activity-row" :data-kind="r.kind">
              <!-- a phone: one cell, the event and its time on one line, the details below, who and IP muted under them -->
              <td v-if="narrow" class="act-row__cell">
                <span class="act-row__line">
                  <span class="act-chip" :class="'is-' + tone(r.kind)" data-test="activity-row-event">{{ t('activity.kinds.' + r.kind) }}</span>
                  <time v-if="r.at" class="act-row__time" :datetime="r.at" :title="fullTime(r.at)" data-test="activity-row-time">{{ isoDateTime(r.at) }}</time>
                </span>
                <span v-if="r.detail" class="act-row__detail">{{ r.detail }}</span>
                <span v-if="r.actor || r.ip" class="act-row__sub">
                  <span v-if="r.actor">{{ names.label(r.actor, 'box-wui') }}</span>
                  <code v-if="r.ip" dir="ltr">{{ r.ip }}</code>
                </span>
              </td>
              <template v-else>
                <td class="act-table__at">
                  <time v-if="r.at" :datetime="r.at" :title="fullTime(r.at)" data-test="activity-row-time">{{ isoDateTime(r.at) }}</time>
                </td>
                <td class="act-table__event"><span class="act-chip" :class="'is-' + tone(r.kind)" data-test="activity-row-event">{{ t('activity.kinds.' + r.kind) }}</span></td>
                <td class="act-table__detail">{{ r.detail }}</td>
                <td class="act-table__by">{{ r.actor ? names.label(r.actor, 'box-wui') : '' }}</td>
                <td class="act-table__ip"><code v-if="r.ip" dir="ltr">{{ r.ip }}</code></td>
              </template>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { cloneActivityRows, filterActivity, memberActivityRows, sortActivity } from '~/utils/activity-log.mjs'
import { userErrorKey } from '~/utils/tenant-users.mjs'
import { browserTimeZone, isoDateTime, isoDateTimeSec, viewerTimeZone } from '~/utils/date-iso.mjs'
import { createLatest } from '~/utils/latest-only.mjs'

const props = defineProps<{ open: boolean, humanId: string }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()

const api = useSpoolApi()
const names = useHumanNames()
const { t } = useI18n({ useScope: 'global' })

const COLUMNS = [
  { col: 'at', sortable: true },
  { col: 'event', sortable: true },
  { col: 'detail', sortable: false },
  { col: 'by', sortable: false },
  { col: 'ip', sortable: false },
] as const

const rows = ref<Array<{ at: string, kind: string, detail: string, actor: string, ip: string }>>([])
const loading = ref(false)
const error = ref('')
const kindF = ref('')
/* the sort column maps to a row field: Event sorts on kind. Default newest-first. */
const sortCol = ref<'at' | 'kind'>('at')
const sortDir = ref<'asc' | 'desc'>('desc')

const kindsPresent = computed(() => [...new Set(rows.value.map((r) => r.kind))])
const shown = computed(() => sortActivity(filterActivity(rows.value, kindF.value), sortCol.value, sortDir.value))

function colField(col: string) {
  return col === 'event' ? 'kind' : col === 'at' ? 'at' : ''
}
function ariaSort(col: string) {
  const f = colField(col)
  if (!f || f !== sortCol.value) return 'none'
  return sortDir.value === 'asc' ? 'ascending' : 'descending'
}
function sortMark(col: string) {
  const f = colField(col)
  if (!f || f !== sortCol.value) return ''
  return sortDir.value === 'asc' ? '▲' : '▼'
}
function toggleSort(col: string) {
  const f = colField(col) as 'at' | 'kind' | ''
  if (!f) return
  if (sortCol.value === f) sortDir.value = sortDir.value === 'asc' ? 'desc' : 'asc'
  else { sortCol.value = f; sortDir.value = 'desc' }
}
/* the one-panel shell (<= 820 px), as the Release Log: no header row, one cell per event */
const narrow = useMobileStack().isMobile
/* to the second with the zone on hover, as the Release Log's times */
const fullTime = (at: string) => [isoDateTimeSec(at), viewerTimeZone() || browserTimeZone()].filter(Boolean).join(' ')
/* the event chip's tone: a sign-in ok, a removal or an expiry warn, the rest plain */
function tone(kind: string) {
  if (kind === 'sign_in' || kind === 'invite_accepted') return 'ok'
  if (kind === 'removed' || kind === 'session_expiry') return 'warn'
  return 'plain'
}

/* Re-opened for another person while a read is in flight: only the newest
   load writes rows / error and clears `loading`. */
const latest = createLatest()
async function load() {
  const mine = latest.next()
  loading.value = true
  error.value = ''
  try {
    /* two sources, merged: the act-as trail (GET /v1/audit/clones, CLE-77797,
       filtered to this person) and the member's own audit rows — membership +
       auth events (GET /v1/members/<id>/activity). Sort happens in `shown`. */
    const [clones, events] = await Promise.all([api.auditClones(), api.memberActivity(props.humanId)])
    if (!latest.isLatest(mine)) return
    rows.value = [...cloneActivityRows(clones, props.humanId), ...memberActivityRows(events)]
  } catch (e) {
    if (!latest.isLatest(mine)) return
    error.value = t(userErrorKey(e))
  } finally {
    if (latest.isLatest(mine)) loading.value = false
  }
}

/* fetch when the dialog opens (and when it opens for a different person);
   only the newest read may write rows, so a slow answer for the person shown
   before cannot replace this one's. */
watch(() => [props.open, props.humanId] as const, ([open]) => { if (open) void load() }, { immediate: true })
</script>

<style scoped>
/* The Release Log's look (owner, t1 06c39172: "the same standards as the
   Release Log", ReleaseNotesDialog.vue): theme tokens only, rem font sizes,
   the body inset like a feed, the table one bordered card with an uppercase
   header band, the columns sized from the header row. */
.act { display: flex; flex-direction: column; gap: var(--spacing-sm); min-width: 0; padding: 0.75rem 1.5rem 1.5rem; }
.act__msg { margin: 0; }
.act__error { color: var(--color-danger); overflow-wrap: anywhere; }
.act__bar { display: flex; align-items: flex-end; gap: 0.5rem 0.75rem; flex-wrap: wrap; }
.act__filter { display: flex; flex-direction: column; gap: 0.25rem; }
.act__label { font-size: 0.8125rem; font-weight: 600; color: var(--color-muted); text-transform: uppercase; letter-spacing: 0.04em; }
.act__select {
  font: inherit; font-size: 0.875rem; padding: 0.3125rem 0.625rem; min-width: 12rem;
  color: var(--color-fg); background: var(--color-surface);
  border: 1px solid var(--color-border-strong); border-radius: var(--radius-sm);
}
.act__action { display: inline-flex; align-items: center; gap: 0.4rem; font-size: 0.875rem; }
.act-card { background: var(--color-surface); border: 1px solid var(--color-border); border-radius: var(--radius-md); min-width: 0; }

/* the table: a header band, fixed narrow columns, the details take the rest */
.act-table-wrap { overflow: clip; }
.act-table { width: 100%; border-collapse: collapse; table-layout: fixed; font-size: 0.9375rem; }
.act-table thead .act-table__at { width: 10rem; }
.act-table thead .act-table__event { width: 11rem; }
.act-table thead .act-table__by { width: 11rem; }
.act-table thead .act-table__ip { width: 9rem; }
.act-table th, .act-table td { padding: 0.5rem 0.75rem; text-align: start; vertical-align: top; }
.act-table thead th {
  position: sticky; top: 0; z-index: 1;
  font-size: 0.8125rem; font-weight: 600; color: var(--color-muted);
  text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap;
  background: var(--color-bg-2); border-bottom: 1px solid var(--color-border-strong);
}
.act-sort {
  display: inline-flex; align-items: center; gap: 0.25rem;
  background: none; border: 0; padding: 0; cursor: pointer;
  color: inherit; font: inherit; text-transform: inherit; letter-spacing: inherit;
}
.act-sort:hover { color: var(--color-fg); }
.act-sort__mark { font-size: 0.6875rem; }
.act-row td { border-bottom: 1px solid var(--color-border); }
.act-row:last-child td { border-bottom: 0; }
/* alternating rows (owner, topic 1fc29f99), in theme tokens */
.act-row:nth-child(even) td { background: var(--color-bg-2); }
.act-row:hover td { background: var(--color-surface-hover); }
.act-table td.act-table__at { white-space: nowrap; color: var(--color-muted); font-size: 0.875rem; font-variant-numeric: tabular-nums; }
.act-table__detail { overflow-wrap: anywhere; min-width: 0; }
.act-table td.act-table__by { overflow-wrap: anywhere; }
.act-table__ip, .act-row__sub { white-space: nowrap; }
.act-table__ip code, .act-row__sub code { font-family: var(--font-mono); font-size: 0.8125rem; padding: 0.0625rem 0.375rem; border-radius: var(--radius-sm); background: var(--color-bg-2); border: 1px solid var(--color-border); color: var(--color-fg); }
.act-chip { display: inline-block; font-size: 0.75rem; font-weight: 600; padding: 0.0625rem 0.5rem; border-radius: var(--radius-pill); border: 1px solid var(--color-border-strong); color: var(--color-muted); white-space: nowrap; }
.act-chip.is-ok { color: var(--color-ok); border-color: currentColor; }
.act-chip.is-warn { color: var(--color-warn); border-color: currentColor; }

/* a phone (the one-panel shell, as the Release Log): no header row; an event
   is one line, its chip and its time, the details below, who and IP muted */
.act--phone { padding: 0.375rem 0.5rem 0.75rem; gap: 0.375rem; }
.act--phone .act__filter { flex: 1 1 auto; }
.act--phone .act__select { min-width: 0; width: 100%; }
.act--phone .act-table td.act-row__cell { padding: 0.4375rem 0.75rem; }
.act-row__line { display: flex; align-items: baseline; justify-content: space-between; gap: 0.5rem; min-width: 0; }
.act-row__time { flex: none; font-size: 0.8125rem; color: var(--color-muted); font-variant-numeric: tabular-nums; }
.act-row__detail { display: block; margin-top: 0.125rem; overflow-wrap: anywhere; }
.act-row__sub { display: flex; align-items: baseline; gap: 0.5rem; min-width: 0; margin-top: 0.125rem; font-size: 0.75rem; color: var(--color-muted); }
.act-row__sub code { font-size: 0.75rem; }
@media (pointer: coarse) {
  .act__action { min-height: var(--tap, 44px); }
}
</style>
