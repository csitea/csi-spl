<!-- spec 143 3.6 (T033, SPL-2789): the Reporting SQL tab. Owner HUM-10
     (t1 af25a1f3, msg 581d5d66): "nothing too fancey, just a simple
     functionality to be able to run sql queries and get up to 2000 rows in
     a generic alternative colouring result set table"; workspace admins
     only, read only. The hub (POST /v1/reporting/sql) is the control: it
     refuses anything but one read of this workspace's tables and answers
     403 to anyone but an admin. Copy / .csv / .json export the rows held
     here (at most 2,000), never a second query (utils/reporting-sql.ts). -->
<template>
  <div class="reporting-sql" data-test="reporting-sql">
    <form class="sql-editor" @submit.prevent="run">
      <label class="sql-label" for="reporting-sql-query">{{ t('reporting.sql.query_label') }}</label>
      <textarea
        id="reporting-sql-query"
        v-model="query"
        class="sql-query"
        data-test="reporting-sql-query"
        rows="6"
        spellcheck="false"
        autocapitalize="off"
        autocomplete="off"
        :placeholder="t('reporting.sql.placeholder')"
        @keydown.enter.ctrl.prevent="run"
        @keydown.enter.meta.prevent="run"
      />
      <div class="sql-actions">
        <button type="submit" class="btn" data-test="reporting-sql-run" :disabled="busy || !query.trim()" :title="t('reporting.sql.run_hint')">
          {{ t('reporting.sql.run') }}
        </button>
        <button type="button" class="btn" data-test="reporting-sql-clear" :disabled="busy" @click="clear">{{ t('reporting.sql.clear') }}</button>
        <span v-if="busy" class="sql-spinner" role="status" data-test="reporting-sql-busy">{{ t('reporting.sql.running') }}</span>
        <span v-else-if="result" class="sql-status" role="status" data-test="reporting-sql-status">
          {{ t('reporting.sql.status', { ms: result.durationMs, n: result.rowCount }) }}
          <span v-if="result.truncated" class="sql-capped" data-test="reporting-sql-capped">{{ t('reporting.sql.capped', { n: capText }) }}</span>
        </span>
      </div>
    </form>

    <p v-if="error" class="sql-error" role="alert" data-test="reporting-sql-error">
      {{ t(error.key) }}<template v-if="error.detail">: <code>{{ error.detail }}</code></template>
    </p>

    <section v-if="result" class="sql-result" :aria-label="t('reporting.sql.result_label')">
      <div class="sql-export" data-test="reporting-sql-export">
        <button type="button" class="btn" data-test="reporting-sql-copy" @click="copy">{{ t('reporting.sql.copy') }}</button>
        <button type="button" class="btn" data-test="reporting-sql-csv" @click="download('csv')">{{ t('reporting.sql.download_csv') }}</button>
        <button type="button" class="btn" data-test="reporting-sql-json" @click="download('json')">{{ t('reporting.sql.download_json') }}</button>
        <span v-if="copied" class="sql-copied" role="status" data-test="reporting-sql-copied">{{ t(copied) }}</span>
      </div>
      <p v-if="!result.columns.length" class="muted" data-test="reporting-sql-empty">{{ t('reporting.sql.no_columns') }}</p>
      <div v-else class="sql-table-wrap">
        <table class="sql-table" data-test="reporting-sql-table">
          <thead>
            <tr>
              <th v-for="(c, i) in result.columns" :key="i" scope="col" :title="c.type">{{ c.name }}</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(row, r) in result.rows" :key="r" :class="r % 2 === 0 ? 'row--even' : 'row--odd'">
              <td v-for="(v, i) in row" :key="i" :class="{ 'sql-null': v === null }">{{ v === null ? NULL_TEXT : v }}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { SQL_ROW_CAP, sqlErrorKey, sqlExportName, sqlResultOf, sqlToCsv, sqlToJson, sqlToTsv } from '~/utils/reporting-sql'
import type { SqlResult } from '~/utils/reporting-sql'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { saveBlob } from '~/utils/save-blob.mjs'

type SqlApi = { reportingSql: (query: string) => Promise<unknown> }

/* SQL's own word for a missing value, the same in every language */
const NULL_TEXT = 'NULL'

const { t } = useI18n({ useScope: 'global' })
const query = ref('')
const busy = ref(false)
const result = ref<SqlResult | null>(null)
const error = ref<{ key: string, detail: string } | null>(null)
const copied = ref('')
const capText = String(SQL_ROW_CAP)
let copiedTimer: ReturnType<typeof setTimeout> | undefined

async function run() {
  const q = query.value.trim()
  if (!q || busy.value) return
  busy.value = true
  error.value = null
  copied.value = ''
  try {
    result.value = sqlResultOf(await (useSpoolApi() as unknown as SqlApi).reportingSql(q))
  } catch (e) {
    const err = e as { token?: string, detail?: string, status?: number }
    result.value = null
    error.value = { key: sqlErrorKey(err?.token), detail: String(err?.detail || '') }
  } finally {
    busy.value = false
  }
}

function clear() {
  query.value = ''
  result.value = null
  error.value = null
  copied.value = ''
}

async function copy() {
  if (!result.value) return
  const ok = await writeClipboard(sqlToTsv(result.value))
  copied.value = ok ? 'reporting.sql.copied' : 'reporting.sql.copy_failed'
  clearTimeout(copiedTimer)
  copiedTimer = setTimeout(() => { copied.value = '' }, 2500)
}

function download(ext: 'csv' | 'json') {
  if (!result.value) return
  const text = ext === 'csv' ? sqlToCsv(result.value) : sqlToJson(result.value)
  const type = ext === 'csv' ? 'text/csv;charset=utf-8' : 'application/json'
  saveBlob(new Blob([text], { type }), sqlExportName(ext))
}

onBeforeUnmount(() => clearTimeout(copiedTimer))
</script>

<style scoped>
.reporting-sql { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.sql-editor { display: flex; flex-direction: column; gap: 8px; }
.sql-label { font-weight: 600; }
.sql-query {
  width: 100%;
  min-height: 120px;
  resize: vertical;
  font-family: var(--font-mono);
  font-size: 0.875rem;
  padding: 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
  box-sizing: border-box;
}
.sql-actions, .sql-export { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.sql-spinner, .sql-status, .sql-copied { color: var(--color-muted); font-size: 0.875rem; }
.sql-capped {
  margin-inline-start: 6px;
  padding: 0 6px;
  border: 1px solid var(--color-warn);
  border-radius: var(--radius-pill);
  color: var(--color-warn);
  font-size: 0.75rem;
  white-space: nowrap;
}
.sql-error { color: var(--color-danger); margin: 0; overflow-wrap: anywhere; }
.sql-result { display: flex; flex-direction: column; gap: 8px; min-width: 0; }
.sql-table-wrap { overflow: auto; max-width: 100%; max-height: 70vh; border: 1px solid var(--color-border); }
.sql-table { border-collapse: collapse; font-size: 0.8125rem; font-variant-numeric: tabular-nums; }
.sql-table th, .sql-table td { padding: 4px 8px; text-align: start; vertical-align: top; white-space: pre; border-bottom: 1px solid var(--color-border); }
.sql-table thead th { position: sticky; top: 0; z-index: 1; background: var(--color-bg); font-weight: 600; }
.sql-table .row--odd { background: var(--color-row-alt); }
.sql-null { color: var(--color-muted); font-style: italic; }
</style>
