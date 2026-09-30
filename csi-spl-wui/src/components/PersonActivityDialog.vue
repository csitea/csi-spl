<!-- CLE-77799 (owner topic 1fc29f99: "the admin should be able to see ... the
     main event log activities for this person, when he has logged in, and
     logged out etc." + "use some nice alternating color tables ... default
     order newer on the top" + "the similar way how the filtering and sorting
     work for the issues table"): the admin-only per-person Activity log.

     A zebra table, newest-first, with a header-click sort and a per-column
     Event filter (the Issues table's interaction), and a masked-IP column.
     Slice 1 shows the act-as trail (GET /v1/audit/clones, real data); slices 2
     and 3 add membership and auth events into the same rows. audit.read only;
     the hub is the authority. -->
<template>
  <UiDialog :open="open" size="lg" :title="t('activity.title')" @update:open="emit('update:open', $event)">
    <div class="activity" data-test="person-activity">
      <div class="activity__bar">
        <label class="activity__filter">
          <span class="muted">{{ t('activity.col.event') }}</span>
          <select v-model="kindF" class="activity__select" data-test="activity-filter-kind">
            <option value="">{{ t('activity.filter_all') }}</option>
            <option v-for="k in kindsPresent" :key="k" :value="k">{{ t('activity.kinds.' + k) }}</option>
          </select>
        </label>
        <button v-if="kindF" type="button" class="btn ghost activity__clear" data-test="activity-filter-clear" @click="kindF = ''">
          {{ t('activity.filter_clear') }}
        </button>
      </div>

      <p v-if="loading" class="muted activity__note" data-test="activity-loading">{{ t('activity.loading') }}</p>
      <p v-else-if="error" class="activity__error" role="alert" data-test="activity-error">{{ error }}</p>
      <p v-else-if="shown.length === 0" class="muted activity__note" data-test="activity-empty">{{ t('activity.none') }}</p>

      <table v-else class="activity-table" data-test="activity-table">
        <thead>
          <tr>
            <th v-for="c in COLUMNS" :key="c.col" scope="col" :aria-sort="ariaSort(c.col)">
              <button v-if="c.sortable" type="button" class="activity-sort" :data-testid="'activity-sort-' + c.col" @click="toggleSort(c.col)">
                {{ t('activity.col.' + c.col) }}<span class="activity-sort__mark">{{ sortMark(c.col) }}</span>
              </button>
              <span v-else>{{ t('activity.col.' + c.col) }}</span>
            </th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="(r, i) in shown" :key="i" class="activity-row" data-test="activity-row">
            <td class="activity-when">{{ when(r.at) }}</td>
            <td>{{ t('activity.kinds.' + r.kind) }}</td>
            <td class="activity-detail">{{ r.detail || '—' }}</td>
            <td>{{ r.actor ? names.label(r.actor, 'box-wui') : '—' }}</td>
            <td class="activity-ip">{{ r.ip || '—' }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useHumanNames } from '~/composables/useHumanNames'
import { cloneActivityRows, filterActivity, sortActivity } from '~/utils/activity-log.mjs'
import { userErrorKey } from '~/utils/tenant-users.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

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
function when(iso: string) {
  return isoDateTime(iso) || '—'
}

async function load() {
  loading.value = true
  error.value = ''
  try {
    const clones = await api.auditClones()
    rows.value = cloneActivityRows(clones, props.humanId)
  } catch (e) {
    error.value = t(userErrorKey(e))
  } finally {
    loading.value = false
  }
}

/* fetch when the dialog opens (and when it opens for a different person). */
watch(() => [props.open, props.humanId] as const, ([open]) => { if (open) void load() }, { immediate: true })
</script>

<style scoped>
.activity { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.activity__bar { display: flex; align-items: flex-end; gap: 10px; flex-wrap: wrap; }
.activity__filter { display: flex; flex-direction: column; gap: 2px; font-size: 0.8rem; }
.activity__select {
  font: inherit; font-size: 0.85rem; padding: 4px 8px;
  color: var(--color-fg); background: var(--color-surface);
  border: 1px solid var(--color-border); border-radius: var(--radius-sm);
}
.activity__clear { align-self: flex-end; }
.activity__note { margin: 8px 0; }
.activity__error { margin: 8px 0; color: var(--color-danger); overflow-wrap: anywhere; }
.activity-table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
.activity-table th, .activity-table td {
  text-align: start; padding: 6px 10px; vertical-align: top;
  border-bottom: 1px solid var(--color-border); overflow-wrap: anywhere;
}
.activity-table thead th { color: var(--color-muted); font-weight: 600; white-space: nowrap; }
/* zebra rows in theme tokens, readable in light + dark */
.activity-table tbody tr:nth-child(odd) td { background: var(--color-bg); }
.activity-table tbody tr:nth-child(even) td { background: var(--color-surface); }
.activity-row:hover td { background: var(--color-surface-hover); }
.activity-when { white-space: nowrap; }
.activity-ip { white-space: nowrap; font-variant-numeric: tabular-nums; }
.activity-sort {
  display: inline-flex; align-items: center; gap: 4px;
  background: none; border: 0; padding: 0; cursor: pointer;
  color: inherit; font: inherit; font-weight: 600;
}
.activity-sort__mark { font-size: 0.7rem; }
</style>
