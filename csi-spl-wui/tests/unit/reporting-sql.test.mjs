// Spec 143 3.6 (T033, SPL-2789): the Reporting SQL tab. The util under the
// page (src/utils/reporting-sql.ts) and the page's wiring. GATE: Copy writes
// TSV with a header, Download .csv a valid RFC 4180 file with a header,
// Download .json a valid JSON array, each of the returned rows. RED
// CONTROL: an answer of more than 2,000 rows (a truncated one) exports
// exactly 2,000 rows from all three, never more.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { importTs } from './lib/load-ts.mjs'
import { writeClipboard } from '../../src/utils/clipboard.mjs'
const { saveBlob } = await importTs('src/utils/save-blob.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const {
  SQL_ROW_CAP, sqlResultOf, sqlToTsv, sqlToCsv, sqlToJson, sqlKeys, sqlExportName, sqlErrorKey, SQL_ERROR_TOKENS, mockReportingSql,
} = await importTs('src/utils/reporting-sql.ts')

/** A hub body of n rows: an id, a text with a comma, quote and line break, a NULL. */
function body(n, truncated = false) {
  return {
    columns: [{ name: 'id', type: 'integer' }, { name: 'note', type: 'text' }, { name: 'gone', type: 'text' }],
    rows: Array.from({ length: n }, (_, i) => [String(i + 1), `a, "b"\nc\t${i}`, null]),
    row_count: n, truncated, duration_ms: 12,
  }
}

/** RFC 4180 records of a CSV text (quoted fields, doubled quotes, CRLF). */
function parseCsv(text) {
  const out = []
  let row = []
  let f = ''
  let q = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (q) {
      if (c === '"' && text[i + 1] === '"') { f += '"'; i++ } else if (c === '"') q = false
      else f += c
    } else if (c === '"') {
      assert.equal(f, '', 'a quote opens a field only at its start')
      q = true
    } else if (c === ',') { row.push(f); f = '' } else if (c === '\r' && text[i + 1] === '\n') {
      row.push(f); out.push(row); row = []; f = ''; i++
    } else {
      assert.ok(c !== '\n' && c !== '\r', 'a bare line break outside quotes is malformed')
      f += c
    }
  }
  assert.equal(q, false, 'an unclosed quote is malformed')
  assert.equal(row.length + f.length, 0, 'the file ends with CRLF')
  return out
}

/** saveBlob with seams: the saved file's name and text. */
async function saved(text, name, type) {
  let blob
  const a = { click() {}, remove() {} }
  saveBlob(new Blob([text], { type }), name, {
    doc: { createElement: () => a, body: { appendChild() {} } },
    url: { createObjectURL: (b) => { blob = b; return 'blob:x' }, revokeObjectURL() {} },
    later: () => {},
  })
  return { name: a.download, text: await blob.text(), type: blob.type }
}

describe('T033 the result set', () => {
  it('sqlResultOf: text or null cells, the cap, truncated', () => {
    const r = sqlResultOf(body(3, false))
    assert.equal(r.rowCount, 3)
    assert.equal(r.truncated, false)
    assert.equal(r.durationMs, 12)
    assert.deepEqual(r.rows[0], ['1', 'a, "b"\nc\t0', null])
    assert.deepEqual(sqlResultOf({}), { columns: [], rows: [], rowCount: 0, truncated: false, durationMs: 0 })
    const big = sqlResultOf(body(2500))
    assert.equal(big.rows.length, SQL_ROW_CAP)
    assert.equal(big.truncated, true, 'more rows than the cap is truncated even if the body says not')
    assert.equal(SQL_ROW_CAP, 2000)
  })
})

describe('T033 Copy (clipboard, TSV)', () => {
  it('GATE: header + each row, tab-separated; a tab or line break in a value is a space; NULL empty', async () => {
    let got = ''
    const ok = await writeClipboard(sqlToTsv(sqlResultOf(body(2))), { nav: { clipboard: { writeText: async (t) => { got = t } } } })
    assert.equal(ok, true)
    assert.deepEqual(got.split('\n'), ['id\tnote\tgone', '1\ta, "b" c 0\t', '2\ta, "b" c 1\t'])
  })
  it('RED CONTROL: a truncated answer copies exactly 2,000 rows', () => {
    const lines = sqlToTsv(sqlResultOf(body(2600, true))).split('\n')
    assert.equal(lines.length, 1 + SQL_ROW_CAP)
    assert.equal(lines.at(-1).split('\t')[0], '2000')
  })
})

describe('T033 Download .csv', () => {
  it('GATE: a valid RFC 4180 file with its header, the values back as they were', async () => {
    const f = await saved(sqlToCsv(sqlResultOf(body(2))), sqlExportName('csv', new Date('2026-10-22T14:30:05Z')), 'text/csv;charset=utf-8')
    assert.equal(f.name, '20261022-143005-query-result.csv')
    assert.match(f.type, /^text\/csv/)
    assert.deepEqual(parseCsv(f.text), [['id', 'note', 'gone'], ['1', 'a, "b"\nc\t0', ''], ['2', 'a, "b"\nc\t1', '']])
  })
  it('RED CONTROL: a truncated answer downloads exactly 2,000 rows', () => {
    const recs = parseCsv(sqlToCsv(sqlResultOf(body(2001, true))))
    assert.equal(recs.length, 1 + SQL_ROW_CAP)
    assert.equal(recs.at(-1)[0], '2000')
  })
})

describe('T033 Download .json', () => {
  it('GATE: a valid JSON array of objects, NULL as null', async () => {
    const f = await saved(sqlToJson(sqlResultOf(body(2))), sqlExportName('json', new Date('2026-10-22T14:30:05Z')), 'application/json')
    assert.equal(f.name, '20261022-143005-query-result.json')
    assert.deepEqual(JSON.parse(f.text), [{ id: '1', note: 'a, "b"\nc\t0', gone: null }, { id: '2', note: 'a, "b"\nc\t1', gone: null }])
  })
  it('RED CONTROL: a truncated answer exports exactly 2,000 objects', () => {
    const arr = JSON.parse(sqlToJson(sqlResultOf(body(4000, true))))
    assert.equal(arr.length, SQL_ROW_CAP)
    assert.equal(arr.at(-1).id, '2000')
  })
  it('a repeated column name keeps every value (_2, _3)', () => {
    assert.deepEqual(sqlKeys([{ name: 'n' }, { name: 'n' }, { name: 'm' }, { name: 'n' }]), ['n', 'n_2', 'm', 'n_3'])
  })
})

describe('T033 errors and the mock hub', () => {
  it('each hub refusal token has its own key, anything else the generic one', () => {
    for (const tk of SQL_ERROR_TOKENS) assert.equal(sqlErrorKey(tk), 'reporting.sql.error.' + tk)
    assert.equal(sqlErrorKey('nope'), 'reporting.sql.error.other')
    assert.equal(sqlErrorKey(undefined), 'reporting.sql.error.other')
    const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
    for (const tk of [...SQL_ERROR_TOKENS, 'other']) assert.equal(typeof en.reporting.sql.error[tk], 'string', tk)
  })
  it('the mock refuses a write and two statements as the hub does, and caps a series', () => {
    assert.throws(() => mockReportingSql('DELETE FROM messages'), (e) => e.token === 'read_only_violation' && e.status === 400)
    assert.throws(() => mockReportingSql('SELECT 1; DROP TABLE x'), (e) => e.token === 'single_statement_only')
    const r = sqlResultOf(mockReportingSql('SELECT * FROM generate_series(1, 2500)'))
    assert.equal(r.rows.length, 2000)
    assert.equal(r.truncated, true)
    assert.equal(sqlResultOf(mockReportingSql('select * from channels;')).rowCount, 3)
  })
})

describe('T033 pages/reporting/sql.vue', () => {
  const page = readFileSync(join(WUI, 'src/pages/reporting/sql.vue'), 'utf8')
  it('the editor: a monospaced textarea, Run with Ctrl/Cmd+Enter, Clear, the status and the cap badge', () => {
    assert.match(page, /<textarea[\s\S]*data-test="reporting-sql-query"/)
    assert.match(page, /font-family: var\(--font-mono\)/)
    assert.match(page, /@keydown\.enter\.ctrl\.prevent="run"/)
    assert.match(page, /@keydown\.enter\.meta\.prevent="run"/)
    assert.match(page, /data-test="reporting-sql-clear"/)
    assert.match(page, /v-if="result\.truncated"[^>]*data-test="reporting-sql-capped"/)
  })
  it('the table: zebra rows, a sticky header, NULL set apart', () => {
    assert.match(page, /r % 2 === 0 \? 'row--even' : 'row--odd'/)
    assert.match(page, /thead th \{ position: sticky; top: 0;/)
    assert.match(page, /\.sql-table \.row--odd \{ background: var\(--color-row-alt\); \}/)
    assert.match(page, /'sql-null': v === null/)
  })
  it('the three exports read the rows held, never a second query', () => {
    assert.match(page, /writeClipboard\(sqlToTsv\(result\.value\)\)/)
    assert.match(page, /ext === 'csv' \? sqlToCsv\(result\.value\) : sqlToJson\(result\.value\)/)
    assert.match(page, /saveBlob\(new Blob\(\[text\], \{ type \}\), sqlExportName\(ext\)\)/)
    assert.equal((page.match(/reportingSql\(/g) || []).length, 1, 'one call to the hub: Run')
  })
})
