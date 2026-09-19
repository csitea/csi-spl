// The error channel ported from the donor WUI: errorJournal.mjs (capture +
// redaction + reference ids), debugAudience.mjs (the fail-shut gate) and the
// wiring that feeds and shows them. The pure modules are EXECUTED, not grepped.
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  ERROR_ID_RE,
  buildErrorRecord,
  clearErrors,
  extractErrorId,
  formatRecords,
  getErrors,
  groupByOrigin,
  newClientErrorId,
  noteError,
  redactPath,
  redactText,
  redactUrl,
  resetErrorJournal,
  shouldCollapseOnRouteChange,
  summariseRecord,
  ERROR_JOURNAL_LIMIT,
} from '../../src/composables/errorJournal.mjs'
import {
  canSeeDebugPanel,
  debugPanelVisibleFor,
  diagnosticsGranted,
} from '../../src/composables/debugAudience.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const CLIENT = { isClient: true }

describe('errorJournal: redaction happens at capture', () => {
  it('drops the whole query string of a URL (view token, OAuth code/state)', () => {
    const u = redactUrl('https://t1.example.test/v1/view/threads?view_token=abc&code=xyz')
    assert.equal(u.origin, 'https://t1.example.test')
    assert.equal(u.path, '/v1/view/threads')
  })

  it('scrubs secrets, JWTs, bearer tokens and e-mail from free text', () => {
    const s = redactText('token=supersecretvalue Bearer abcdefghijkl eyJhbGciOi.eyJzdWIiOiIx.sig mail a.b@example.test')
    assert.equal(/supersecretvalue|abcdefghijkl|eyJhbGciOi|a\.b@example\.test/.test(s), false, s)
  })

  it('keeps route structure but still redacts a UUID-shaped segment', () => {
    assert.equal(redactPath('/v1/view/threads'), '/v1/view/threads')
    const p = redactPath('/t/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')
    assert.ok(p.startsWith('/t/'), p)
    assert.equal(p.includes('bbbbbbbb-bbbb'), false, p)
  })

  it('never throws on hostile input', () => {
    const bad = { toString() { throw new Error('boom') } }
    assert.equal(redactText(bad), '')
    assert.deepEqual(redactUrl(bad), { origin: '', path: '' })
    assert.equal(buildErrorRecord(null), null)
  })
})

describe('errorJournal: reference ids', () => {
  it('mints ERR-CLIENT-YYYYMMDD-HHMMSS-XXXX in UTC', () => {
    const id = newClientErrorId(new Date('2026-09-19T08:05:07Z'))
    assert.match(id, /^ERR-CLIENT-20260919-080507-[0-9A-F]{4}$/)
    assert.equal(ERROR_ID_RE.test(id), true)
  })

  it('admits a server id only when it is exactly an id', () => {
    assert.equal(extractErrorId({ data: { error: { error_id: 'ERR-20260919-080507-9B2F' } } }), 'ERR-20260919-080507-9B2F')
    assert.equal(extractErrorId({ data: { error: { error_id: 'ERR-20260919-080507-9B2F user@example.test' } } }), '')
    assert.equal(extractErrorId('not an id'), '')
  })
})

describe('errorJournal: the buffer', () => {
  beforeEach(() => resetErrorJournal())

  it('is a no-op on the server (nothing baked into a static page)', () => {
    assert.equal(noteError({ source: 'x', message: 'm' }, { isClient: false }), null)
    assert.equal(getErrors().length, 0)
  })

  it('ignores a cancelled request', () => {
    const abort = Object.assign(new Error('aborted'), { name: 'AbortError' })
    assert.equal(noteError({ source: 'viewer', error: abort }, CLIENT), null)
  })

  it('records, caps at the ring size, and clears', () => {
    for (let i = 0; i < ERROR_JOURNAL_LIMIT + 5; i++) noteError({ source: 'viewer', message: `m${i}` }, CLIENT)
    const all = getErrors()
    assert.equal(all.length, ERROR_JOURNAL_LIMIT)
    assert.equal(all.at(-1).message, `m${ERROR_JOURNAL_LIMIT + 4}`)
    assert.equal(ERROR_ID_RE.test(all[0].errorId), true)
    clearErrors()
    assert.equal(getErrors().length, 0)
  })

  it('stamps the resolved id on the error so the notice shows the same one', () => {
    const err = new Error('hub down')
    const rec = noteError({ source: 'viewer', error: err }, CLIENT)
    assert.equal(extractErrorId(err), rec.errorId)
  })

  it('the one-line summary leads with the reference id', () => {
    const rec = noteError({ source: 'viewer', method: 'get', url: '/v1/view/threads', status: 502 }, CLIENT)
    assert.ok(summariseRecord(rec).startsWith(rec.errorId))
    assert.ok(formatRecords([rec], { version: 'v0.1.0', page: '/' }).startsWith('spool WUI diagnostics'))
  })

  it('groups by origin page and collapses only for stale foreign records', () => {
    const now = Date.parse('2026-09-19T10:00:00Z')
    const recs = [
      { route: '/', at: '2026-09-19T09:00:00Z' },
      { route: '/lobby', at: '2026-09-19T09:00:00Z' },
    ]
    const g = groupByOrigin(recs, '/lobby')
    assert.equal(g.here.length, 1)
    assert.equal(g.elsewhere.length, 1)
    assert.equal(shouldCollapseOnRouteChange(recs, '/channel/general', now), true)
    assert.equal(shouldCollapseOnRouteChange(recs, '/lobby', now), false)
  })
})

describe('debugAudience: the gate fails shut', () => {
  it('only the literal boolean true grants', () => {
    assert.equal(diagnosticsGranted({ diagnostics_enabled: true }), true)
    for (const v of [undefined, null, 'true', 1, false]) {
      assert.equal(diagnosticsGranted({ diagnostics_enabled: v }), false, String(v))
    }
    assert.equal(diagnosticsGranted(null), false)
    assert.equal(debugPanelVisibleFor({ hum: 'HUM-1' }), false)
  })

  it('role predicate is exact-match and rejects empty sets', () => {
    assert.equal(canSeeDebugPanel(['operator'], ['operator']), true)
    assert.equal(canSeeDebugPanel(['Operator'], ['operator']), false)
    assert.equal(canSeeDebugPanel([], ['operator']), false)
    assert.equal(canSeeDebugPanel(['operator'], []), false)
  })
})

describe('wiring', () => {
  it('the panel gate reads the session claims, never a query/cookie/storage flag', () => {
    const src = read('src/composables/useErrorJournal.ts')
    assert.ok(src.includes('debugPanelVisibleFor(session.claims'))
    assert.equal(/localStorage|sessionStorage|document\.cookie|route\.query/.test(src), false)
  })

  it('the panel is a v-if, client-only and last in the layout', () => {
    assert.ok(read('src/components/common/DebugPanel.vue').includes('v-if="visible"'))
    const layout = read('src/layouts/default.vue')
    assert.ok(/<ClientOnly>\s*<DebugPanel \/>\s*<\/ClientOnly>\s*<\/div>\s*<\/template>/.test(layout))
  })

  it('the journal plugin is client-only and only observes', () => {
    const src = read('src/plugins/error-journal.client.ts')
    assert.ok(src.includes('import.meta.client'))
    assert.equal(/preventDefault|stopPropagation|throw /.test(src.replace(/\/\/.*$/gm, '')), false)
  })

  it('viewer, thread, lobby, channel and live pane errors go through ErrorNotice', () => {
    for (const rel of [
      'src/pages/index.vue',
      'src/pages/t/[task_id].vue',
      'src/pages/lobby.vue',
      'src/components/MessageFeed.vue',
      'src/components/LiveThreadPane.vue',
    ]) {
      assert.ok(read(rel).includes('<ErrorNotice'), rel)
    }
  })

  it('prerendered pages read their query through useSettledQuery', () => {
    const login = read('src/pages/login.vue')
    for (const k of ['redirect', 'tenant', 'auth_error']) {
      assert.ok(login.includes(`useSettledQuery('${k}')`), k)
    }
    assert.equal(/route\.query\.(redirect|tenant|auth_error)/.test(login), false)
    const index = read('src/pages/index.vue')
    assert.ok(index.includes("useSettledQuery('thread')"))
    assert.equal(index.includes('route.query.thread'), false)
  })
})
