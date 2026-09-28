// SPL-1132: the Issues sheet column widths per person. The WUI keeps exactly
// what the hub admits (auth.IsIssueColumns, rdb 0076), the save is optimistic
// with a rollback, and the auth client sends only the one key.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  ISSUE_COLUMNS, ISSUE_COLUMN_MIN, ISSUE_COLUMN_MAX, parseIssueColumns, sameIssueColumns, applyIssueColumns,
} from '../../src/utils/issue-columns-pref.mjs'
import { SHEET_COLUMNS } from '../../src/utils/issues-view.mjs'
import { createAuthClient } from '../../src/utils/auth-client.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('issues_columns values', () => {
  it('the hub (auth.IssueColumns + bounds) and the sheet name the same columns', () => {
    assert.deepEqual([...ISSUE_COLUMNS], [...SHEET_COLUMNS])
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/issue_columns.go')
    const list = go.match(/var IssueColumns = \[\]string\{([^}]*)\}/)
    assert.ok(list, 'auth.IssueColumns not found')
    assert.deepEqual(list[1].split(',').map((s) => s.trim().replace(/"/g, '')), [...ISSUE_COLUMNS])
    assert.match(go, new RegExp(`IssueColumnMin = ${ISSUE_COLUMN_MIN}\\b`))
    assert.match(go, new RegExp(`IssueColumnMax = ${ISSUE_COLUMN_MAX}\\b`))
    assert.match(read('../csi-spl-rdb/src/sql/postgres/spool-hub/0076_human_issues_columns.sql'), /jsonb_typeof\(issues_columns\) = 'object'/)
  })
  it('parse keeps known columns as whole px inside the bounds, drops junk', () => {
    for (const raw of [null, undefined, '', 7, [], 'key']) assert.deepEqual(parseIssueColumns(raw), {})
    assert.deepEqual(parseIssueColumns({ key: 96.4, title: '420', epic: 100, status: 'wide', label: null }), { key: 96, title: 420 })
    assert.deepEqual(parseIssueColumns({ key: 1, deadline: 99999 }), { key: ISSUE_COLUMN_MIN, deadline: ISSUE_COLUMN_MAX })
    assert.ok(sameIssueColumns({ key: 96 }, { key: 96.2 }))
    assert.ok(!sameIssueColumns({ key: 96 }, { key: 96, title: 300 }))
    assert.ok(sameIssueColumns(null, {}))
  })
})

describe('applyIssueColumns', () => {
  const rig = (ok) => {
    const seen = { applied: [], saved: [] }
    return {
      seen,
      io: (current) => ({
        current,
        apply: (v) => seen.applied.push(v),
        save: async (v) => { seen.saved.push(v); if (ok === 'throw') throw new Error('net'); return { ok } },
      }),
    }
  }
  it('mirrors, saves, keeps on 200', async () => {
    const r = rig(true)
    const out = await applyIssueColumns({ key: 120 }, r.io(null))
    assert.deepEqual(out, { ok: true, value: { key: 120 } })
    assert.deepEqual(r.seen.applied, [{ key: 120 }])
    assert.deepEqual(r.seen.saved, [{ key: 120 }])
  })
  it('an empty map is stored as null (the automatic layout)', async () => {
    const r = rig(true)
    await applyIssueColumns({}, r.io({ key: 120 }))
    assert.deepEqual(r.seen.saved, [null])
    assert.deepEqual(r.seen.applied, [null])
  })
  it('a refusal or a network error puts the old widths back', async () => {
    for (const ok of [false, 'throw']) {
      const r = rig(ok)
      const out = await applyIssueColumns({ key: 200 }, r.io({ key: 120 }))
      assert.equal(out.ok, false)
      assert.deepEqual(r.seen.applied, [{ key: 200 }, { key: 120 }])
    }
  })
  it('the same widths save nothing', async () => {
    const r = rig(true)
    await applyIssueColumns({ key: 120 }, r.io({ key: 120 }))
    assert.equal(r.seen.saved.length, 0)
  })
})

describe('the wire', () => {
  it('saveIssueColumns PUTs only issues_columns; {} and null send null', async () => {
    const sent = []
    const fetchFn = async (url, init) => {
      sent.push({ url: String(url), method: init?.method, body: JSON.parse(init?.body || '{}') })
      return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } })
    }
    const c = createAuthClient({ fetchFn, base: 'https://hub.example.com/api/v1/auth' })
    await c.saveIssueColumns({ key: 96 })
    await c.saveIssueColumns({})
    await c.saveIssueColumns(null)
    assert.deepEqual(sent.map((s) => s.body), [{ issues_columns: { key: 96 } }, { issues_columns: null }, { issues_columns: null }])
    assert.ok(sent.every((s) => s.method === 'PUT' && s.url.endsWith('/preferences')))
  })
  it('the session carries the claim and the store mirrors it', () => {
    const ts = read('src/stores/session.ts')
    assert.match(ts, /issues_columns\?: Record<string, number> \| null/)
    assert.match(ts, /function setIssuesColumns\(/)
  })
})
