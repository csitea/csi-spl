// csi-spl-wui/src/utils/reporting-sql.ts
//
// Spec 143 3.6 (T033, SPL-2789): the Reporting SQL tab's result set and its
// three exports. Owner HUM-10 (t1 af25a1f3, msg 9c32201b): "export of the
// result? and add copy to clipboard button as well" = Copy (TSV), Download
// .csv, Download .json. Every export reads only the rows the hub returned,
// at most SQL_ROW_CAP (2,000): a truncated result is exported as its 2,000
// rows, never re-queried.

/** The hub's cap (spec 143 B6); the page never holds more. */
export const SQL_ROW_CAP = 2000

export type SqlColumn = { name: string, type: string }
export type SqlCell = string | null
export type SqlResult = {
  columns: SqlColumn[]
  rows: SqlCell[][]
  rowCount: number
  truncated: boolean
  durationMs: number
}

/** The hub body as a result: strings or null in each cell, the rows cut
 *  to SQL_ROW_CAP (a longer answer sets truncated). */
export function sqlResultOf(body: unknown): SqlResult {
  const b = (body && typeof body === 'object' ? body : {}) as Record<string, unknown>
  const columns = (Array.isArray(b.columns) ? b.columns : []).map((c: unknown) => {
    const o = (c && typeof c === 'object' ? c : {}) as Record<string, unknown>
    return { name: String(o.name ?? ''), type: String(o.type ?? '') }
  })
  const all = Array.isArray(b.rows) ? b.rows : []
  const rows = all.slice(0, SQL_ROW_CAP).map((r: unknown) => columns.map((_, i) => {
    const v = Array.isArray(r) ? r[i] : undefined
    return v === null || v === undefined ? null : String(v)
  }))
  return {
    columns,
    rows,
    rowCount: rows.length,
    truncated: b.truncated === true || all.length > SQL_ROW_CAP,
    durationMs: Number.isFinite(Number(b.duration_ms)) ? Number(b.duration_ms) : 0,
  }
}

/** Tab-separated text with a header row, for a spreadsheet paste: a tab or
 *  a line break inside a value becomes a space, NULL an empty cell. */
export function sqlToTsv(r: SqlResult): string {
  const cell = (v: SqlCell) => (v === null ? '' : v.replace(/[\t\r\n]+/g, ' '))
  const lines = [r.columns.map((c) => cell(c.name)), ...r.rows.slice(0, SQL_ROW_CAP).map((row) => row.map(cell))]
  return lines.map((l) => l.join('\t')).join('\n')
}

/** RFC 4180 CSV: a header row, CRLF line ends, a field with a comma, a
 *  quote or a line break quoted and its quotes doubled, NULL empty. */
export function sqlToCsv(r: SqlResult): string {
  const cell = (v: SqlCell) => {
    if (v === null) return ''
    return /[",\r\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v
  }
  const lines = [r.columns.map((c) => cell(c.name)), ...r.rows.slice(0, SQL_ROW_CAP).map((row) => row.map(cell))]
  return lines.map((l) => l.join(',')).join('\r\n') + '\r\n'
}

/** The column names as object keys: a repeated name gets _2, _3, ... */
export function sqlKeys(columns: SqlColumn[]): string[] {
  const seen = new Map<string, number>()
  return columns.map((c) => {
    const n = (seen.get(c.name) ?? 0) + 1
    seen.set(c.name, n)
    return n === 1 ? c.name : `${c.name}_${n}`
  })
}

/** A pretty-printed JSON array of objects, one per row, NULL as null. */
export function sqlToJson(r: SqlResult): string {
  const keys = sqlKeys(r.columns)
  const objs = r.rows.slice(0, SQL_ROW_CAP).map((row) => Object.fromEntries(keys.map((k, i) => [k, row[i] ?? null])))
  return JSON.stringify(objs, null, 2) + '\n'
}

/** `<timestamp>-query-result.<ext>` in UTC, e.g. 20261022-143005-query-result.csv. */
export function sqlExportName(ext: 'csv' | 'json', at: Date = new Date()): string {
  const stamp = at.toISOString().slice(0, 19).replace(/[-:]/g, '').replace('T', '-')
  return `${stamp}-query-result.${ext}`
}

/** The i18n key for a hub refusal token (spec 143 3.7), else the generic one. */
export const SQL_ERROR_TOKENS = Object.freeze([
  'read_only_violation', 'single_statement_only', 'forbidden_function', 'forbidden_relation', 'syntax_error',
  'query_error', 'bad_query', 'result_too_large', 'admin_required', 'query_timeout',
])
export function sqlErrorKey(token: string | undefined): string {
  return SQL_ERROR_TOKENS.includes(String(token)) ? `reporting.sql.error.${token}` : 'reporting.sql.error.other'
}

/** The mock hub (lde, e2e): a write or a semicolon is refused as the hub
 *  would; `n` rows of generate_series(1, n) answer in the shape of a
 *  real result, and anything else answers three channel rows. */
export function mockReportingSql(query: string): SqlResultBody {
  const q = String(query || '').trim().replace(/;\s*$/, '')
  if (/;/.test(q)) throw mockSqlError('single_statement_only', 'one statement only')
  if (!/^\(*\s*(select|with|values|table)\b/i.test(q)) throw mockSqlError('read_only_violation', 'the SQL tab is read only')
  const series = /generate_series\(\s*1\s*,\s*(\d+)\s*\)/i.exec(q)
  if (series) {
    const n = Number(series[1])
    const rows = Array.from({ length: Math.min(n, SQL_ROW_CAP) }, (_, i) => [String(i + 1), i % 7 === 3 ? null : `row ${i + 1}`])
    return { columns: [{ name: 'n', type: 'integer' }, { name: 'label', type: 'text' }], rows, row_count: rows.length, truncated: n > SQL_ROW_CAP, duration_ms: 7 }
  }
  const rows = [
    ['lobby', 'Lobby', '2026-09-18 10:00:00+00'],
    ['tasks', 'Tasks, "open"', '2026-09-18 10:05:00+00'],
    ['alerts', null, '2026-09-18 10:07:00+00'],
  ]
  return { columns: [{ name: 'channel_id', type: 'text' }, { name: 'name', type: 'text' }, { name: 'created_at', type: 'timestamp with time zone' }], rows, row_count: 3, truncated: false, duration_ms: 3 }
}

export type SqlResultBody = { columns: SqlColumn[], rows: SqlCell[][], row_count: number, truncated: boolean, duration_ms: number }

function mockSqlError(token: string, detail: string): Error & { status: number, token: string, detail: string } {
  return Object.assign(new Error(`spool 400 ${token}`), { status: 400, token, detail })
}
