<!-- Tenant settings -> Performance (spec 066 section 6 (b), owner Q8: "Okay
     add the whole admin page now."): this workspace's anonymous timings from
     GET /v1/admin/perf/summary, per (metric, device, view) n, p50, p75, p95,
     slowest first by p75. The window is 7 or 30 days; a second build turns
     the table into a build A / B compare. n stands beside every percentile
     and p95 shows from n = 50 (section 8). tenant.settings. -->
<template>
  <SettingsSection id="tenant-performance" :title="t('tenant_settings.performance_title')" data-test="tenant-settings-performance">
    <p class="muted pf-hint">{{ t('tenant_settings.performance_hint') }}</p>
    <form class="pf-form" data-test="tenant-perf-form" @submit.prevent="load">
      <label class="pf-field">
        <span>{{ t('tenant_settings.performance_window') }}</span>
        <select v-model.number="days" data-test="tenant-perf-days" @change="load">
          <option v-for="d in PERF_DAYS_OPTIONS" :key="d" :value="d">{{ t('tenant_settings.performance_days', { n: d }) }}</option>
        </select>
      </label>
      <label class="pf-field">
        <span>{{ t('tenant_settings.performance_build') }}</span>
        <input v-model="build" type="text" maxlength="40" spellcheck="false" autocomplete="off" data-test="tenant-perf-build">
      </label>
      <label class="pf-field">
        <span>{{ t('tenant_settings.performance_build_b') }}</span>
        <input v-model="buildB" type="text" maxlength="40" spellcheck="false" autocomplete="off" data-test="tenant-perf-build-b">
      </label>
      <button type="submit" class="btn" :disabled="loading" data-test="tenant-perf-apply">{{ t('tenant_settings.performance_apply') }}</button>
    </form>
    <p class="muted pf-hint">{{ t('tenant_settings.performance_build_hint') }}</p>

    <p v-if="loading" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="loadError" class="pf-error" role="alert" data-test="tenant-perf-error">{{ loadError }}</p>
    <p v-else-if="summary && summary.off" class="muted" data-test="tenant-perf-off">{{ t('tenant_settings.performance_off') }}</p>
    <p v-else-if="!rows.length" class="muted" data-test="tenant-perf-empty">{{ t('tenant_settings.performance_empty') }}</p>
    <div v-else class="pf-table-wrap">
      <table class="pf-table" data-test="tenant-perf-table" :data-compare="compare ? '1' : '0'">
        <thead>
          <tr>
            <th scope="col">{{ t('tenant_settings.performance_col_metric') }}</th>
            <th scope="col">{{ t('tenant_settings.performance_col_device') }}</th>
            <th scope="col">{{ t('tenant_settings.performance_col_view') }}</th>
            <th scope="col" class="pf-num">n</th>
            <th scope="col" class="pf-num">p50</th>
            <th scope="col" class="pf-num">p75</th>
            <th v-if="!compare" scope="col" class="pf-num">p95</th>
            <th v-if="!compare" scope="col" class="pf-num">{{ t('tenant_settings.performance_col_failed') }}</th>
            <th v-if="compare" scope="col" class="pf-num">n B</th>
            <th v-if="compare" scope="col" class="pf-num">p75 B</th>
            <th v-if="compare" scope="col" class="pf-num">{{ t('tenant_settings.performance_col_change') }}</th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="r in rows" :key="r.key" data-test="tenant-perf-row" :data-metric="r.row.metric" :data-device="r.row.device" :data-view="r.row.view">
            <td class="pf-metric" data-test="tenant-perf-metric">{{ t('tenant_settings.performance_metric_' + r.row.metric) }}</td>
            <td :data-label="t('tenant_settings.performance_col_device')">{{ t('tenant_settings.performance_device_' + r.row.device) }}</td>
            <td :data-label="t('tenant_settings.performance_col_view')">{{ t('tenant_settings.performance_view_' + (r.row.view || 'any')) }}</td>
            <td class="pf-num" data-label="n" data-test="tenant-perf-n">{{ r.a ? r.a.n : '—' }}</td>
            <td class="pf-num" data-label="p50">{{ ms(r.a && r.a.p50) }}</td>
            <td class="pf-num" data-label="p75" data-test="tenant-perf-p75">{{ ms(r.a && r.a.p75) }}</td>
            <td v-if="!compare" class="pf-num" data-label="p95" data-test="tenant-perf-p95">{{ ms(r.a && r.a.p95) }}</td>
            <td v-if="!compare" class="pf-num" :data-label="t('tenant_settings.performance_col_failed')">{{ r.a ? r.a.failed : '—' }}</td>
            <td v-if="compare" class="pf-num" data-label="n B">{{ r.b ? r.b.n : '—' }}</td>
            <td v-if="compare" class="pf-num" data-label="p75 B" data-test="tenant-perf-p75-b">{{ ms(r.b && r.b.p75) }}</td>
            <td v-if="compare" class="pf-num" :class="deltaClass(r.delta)" :data-label="t('tenant_settings.performance_col_change')" data-test="tenant-perf-change">{{ deltaText(r.delta) }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSessionStore } from '~/stores/session'
import { tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import { normalizePerfSummary, perfBuildOf, perfCompareRows, perfMs, perfRowKey, PERF_DAYS_OPTIONS } from '~/utils/perf-summary.mjs'

interface PerfRow { metric: string, device: string, view: string, n: number, p50: number | null, p75: number | null, p95: number | null, failed: number }
interface PerfSummary { off: boolean, days: number, build: string, buildB: string, rows: PerfRow[], rowsB: PerfRow[] }
interface PerfLine { key: string, row: PerfRow, a: PerfRow | null, b: PerfRow | null, delta: number | null }

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const session = useSessionStore()

const days = ref(7)
const build = ref('')
const buildB = ref('')
const summary = ref<PerfSummary | null>(null)
const loading = ref(true)
const loadError = ref('')

const compare = computed(() => !!summary.value && summary.value.buildB !== '')
const rows = computed<PerfLine[]>(() => {
  const s = summary.value
  if (!s) return []
  if (!compare.value) return s.rows.map((r) => ({ key: perfRowKey(r), row: r, a: r, b: null, delta: null }))
  const joined = perfCompareRows(s.rows, s.rowsB) as Array<Omit<PerfLine, 'row'>>
  return joined.map((c) => ({ ...c, row: (c.a || c.b) as PerfRow }))
})

function ms(v: number | null | undefined): string {
  return perfMs(v) || '—'
}

function deltaText(d: number | null): string {
  if (d === null) return '—'
  return d > 0 ? `+${d}` : String(d)
}

function deltaClass(d: number | null): string {
  if (d === null || d === 0) return ''
  return d < 0 ? 'pf-faster' : 'pf-slower'
}

let seq = 0
async function load() {
  const mine = ++seq
  loading.value = true
  try {
    const body = await api.getPerfSummary({ days: days.value, build: perfBuildOf(build.value), buildB: perfBuildOf(buildB.value) })
    if (mine !== seq) return
    summary.value = normalizePerfSummary(body) as PerfSummary
    loadError.value = ''
  } catch (e) {
    if (mine !== seq) return
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    if (mine === seq) loading.value = false
  }
}

watch(() => session.state, (st) => {
  if (st === 'in' || api.mock) void load()
}, { immediate: true })
</script>

<style scoped>
.pf-hint { margin: 0 0 10px; }
.pf-form { display: flex; flex-wrap: wrap; align-items: flex-end; gap: 12px; margin-bottom: 6px; }
.pf-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.pf-field input, .pf-field select {
  width: 11em;
  max-width: 100%;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.pf-table-wrap { overflow-x: auto; max-width: 100%; }
.pf-table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
.pf-table th, .pf-table td { padding: 6px 8px; text-align: start; border-bottom: 1px solid var(--color-border); vertical-align: middle; }
.pf-table th { font-weight: 600; color: var(--color-muted); font-size: 0.8125rem; }
.pf-num { text-align: end; font-variant-numeric: tabular-nums; }
.pf-metric { overflow-wrap: anywhere; }
.pf-faster { color: var(--color-ok); }
.pf-slower { color: var(--color-danger); }
.pf-error { margin: 8px 0 0; color: var(--color-danger); overflow-wrap: anywhere; }
/* phones: one card per group instead of a wide table */
@media (max-width: 820px) {
  .pf-field { flex: 1 1 100%; }
  .pf-field input, .pf-field select { width: 100%; min-height: var(--tap, 44px); }
  .pf-form .btn { min-height: var(--tap, 44px); }
  .pf-table thead { display: none; }
  .pf-table, .pf-table tbody, .pf-table tr { display: block; width: 100%; }
  .pf-table tr { display: flex; flex-wrap: wrap; gap: 2px 12px; border-bottom: 1px solid var(--color-border); padding: 8px 0; }
  .pf-table td { display: block; border: 0; padding: 0; text-align: start; }
  .pf-table td.pf-metric { flex: 1 1 100%; font-weight: 600; }
  .pf-table td[data-label]::before { content: attr(data-label) ' '; color: var(--color-muted); }
}
</style>
