// spec 075 repo-edit T12: the status chip of spec §3 (one test per status),
// "My edits" (own + own agents' edits, retry) and the conflict view (§8:
// theirs / mine, saved again with base = head). The edits answers are read
// leniently; the mock hub steps its worker once per edits read; every new
// string is in all 19 locales; the three views load lazily on the docs page.
//
// Run: node tests/unit/repo-edit-status.test.mjs
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { EDIT_STATUSES, chipOf, conflictOf, editActionErrorOf, editOf, editsOf, headerEdit, ifMatchOf, isPending } from '../../src/utils/repo-edit.mjs'
import { MOCK_AGENT_EDIT, MOCK_AUTHOR, MOCK_CONFLICT, MOCK_FAIL, mockAuthorNotice, mockDocBase, mockDocs, mockRepoConflict, mockRepoEdits, mockRepoReset, mockRepoRetry, mockRepoSave } from '../../src/utils/docs-mock.mjs'

const read = (p) => readFileSync(new URL('../../' + p, import.meta.url), 'utf8')
const SHA = 'abcdef0123456789abcdef0123456789abcdef01'
const DOC = 'csi-spl-doc/doc/md/csi-spl.feature.md'
const row = (status, extra = {}) => ({ edit_id: 'e-' + status, path: DOC, status, human_id: 'HUM-1', actor_kind: 'member', agent_id: '', commit_sha: '', merged_with: '', last_error: '', created_at: '', ...extra })

describe('chipOf: one chip per status (spec §3)', () => {
  it('queued: Saved · pushing, no action', () => {
    assert.deepEqual(chipOf(row('queued')), { status: 'queued', key: 'docs.repoEdit.chip.pushing', sha7: '', merged7: '', action: '' })
  })
  it('pushing: the same Saved · pushing', () => {
    assert.equal(chipOf(row('pushing')).key, 'docs.repoEdit.chip.pushing')
    assert.equal(chipOf(row('pushing')).action, '')
  })
  it('pushed: Pushed · <sha7>, and the merge head when there was one', () => {
    assert.deepEqual(chipOf(row('pushed', { commit_sha: SHA, merged_with: '1234567890' })), { status: 'pushed', key: 'docs.repoEdit.chip.pushed', sha7: 'abcdef0', merged7: '1234567', action: '' })
  })
  it('published: no chip', () => assert.equal(chipOf(row('published')), null))
  it('conflict: Conflict · resolve', () => {
    const c = chipOf(row('conflict'))
    assert.equal(c.key, 'docs.repoEdit.chip.conflict')
    assert.equal(c.action, 'resolve')
  })
  it('failed: Not pushed · retry', () => {
    const c = chipOf(row('failed'))
    assert.equal(c.key, 'docs.repoEdit.chip.failed')
    assert.equal(c.action, 'retry')
  })
  it('superseded: no chip', () => assert.equal(chipOf(row('superseded')), null))
  it('CONTROL every status of the data model is covered; no edit, no chip', () => {
    assert.deepEqual(EDIT_STATUSES, ['queued', 'pushing', 'pushed', 'published', 'conflict', 'failed', 'superseded'])
    for (const v of [null, undefined, {}, row('nope')]) assert.equal(chipOf(v), null)
  })
  it('only queued and pushing keep the chip polling', () => {
    assert.deepEqual(EDIT_STATUSES.filter((s) => isPending(row(s))), ['queued', 'pushing'])
    assert.equal(isPending(null), false)
  })
})

describe('editOf / editsOf', () => {
  it('reads the hub view of an edit', () => {
    const e = editOf({ edit_id: 'x', path: DOC, status: 'pushed', human_id: 'HUM-1', actor_kind: 'agent', agent_id: 'c-101', commit_sha: SHA.toUpperCase(), last_error: '', created_at: '2026-10-07T08:00:00Z', tries: 3 })
    assert.equal(e.actor_kind, 'agent')
    assert.equal(e.agent_id, 'c-101')
    assert.equal(e.commit_sha, SHA)
  })
  it('CONTROL a row without id, with a bad path or status, is dropped; a bad sha is empty', () => {
    assert.deepEqual(editsOf({ edits: [{ path: DOC, status: 'queued' }, { edit_id: 'a', path: '../x.md', status: 'queued' }, { edit_id: 'b', path: DOC, status: 'gone' }, null] }), [])
    assert.equal(editOf({ edit_id: 'c', path: DOC, status: 'pushed', commit_sha: 'zz' }).commit_sha, '')
    assert.deepEqual(editsOf(null), [])
  })
})

describe('headerEdit: the edit the doc header shows', () => {
  it('the newest row of the path that is not superseded', () => {
    const rows = [row('superseded', { edit_id: 's' }), row('pushed', { edit_id: 'p' }), row('queued', { edit_id: 'q' })]
    assert.equal(headerEdit(rows, DOC, 'HUM-1', null).edit_id, 'p')
  })
  it('the save this page just made comes first until the rows have it', () => {
    const last = { edit_id: 'new', path: DOC, status: 'queued' }
    assert.equal(headerEdit([row('pushed')], DOC, 'HUM-1', last).edit_id, 'new')
    assert.equal(headerEdit([row('pushing', { edit_id: 'new' })], DOC, 'HUM-1', last).status, 'pushing')
  })
  it('CONTROL another member\'s conflict is theirs alone; another path is not this doc', () => {
    assert.equal(headerEdit([row('conflict', { human_id: 'HUM-2' }), row('pushed')], DOC, 'HUM-1', null).status, 'pushed')
    assert.equal(headerEdit([row('conflict', { human_id: 'HUM-2' })], DOC, '', null).status, 'conflict')
    assert.equal(headerEdit([row('pushed', { path: 'README.md' })], DOC, 'HUM-1', null), null)
    assert.equal(headerEdit(undefined, DOC, 'HUM-1', null), null)
  })
})

describe('conflictOf and the resolution base', () => {
  it('reads theirs / mine and saves again with If-Match = head_blob', () => {
    const c = conflictOf({ edit_id: 'x', path: DOC, base: 'b', theirs: 't', mine: 'm', head_blob: SHA, head_commit: SHA, reason: 'r' })
    assert.equal(c.theirs, 't')
    assert.equal(c.mine, 'm')
    assert.equal(ifMatchOf(c.head_blob), `"${SHA}"`)
  })
  it('CONTROL a body that is not a conflict is null; a bad head blob sends no If-Match', () => {
    for (const b of [null, {}, { edit_id: 'x', path: '../a.md' }]) assert.equal(conflictOf(b), null)
    assert.equal(conflictOf({ edit_id: 'x', path: DOC, head_blob: 'zz' }).head_blob, '')
  })
})

describe('editActionErrorOf', () => {
  it('each refusal says why', () => {
    assert.equal(editActionErrorOf(409, { error: 'not_failed' }).key, 'docs.repoEdit.err.not_failed')
    assert.equal(editActionErrorOf(409, { error: 'not_conflict' }).key, 'docs.repoEdit.err.not_conflict')
    assert.equal(editActionErrorOf(403, { error: 'forbidden' }).key, 'docs.repoEdit.err.not_yours')
    assert.equal(editActionErrorOf(404, null).key, 'docs.repoEdit.err.no_edit')
    for (const s of [0, 500]) assert.equal(editActionErrorOf(s, null).key, 'docs.repoEdit.err.failed')
  })
})

describe('the mock hub: worker, retry, conflict', () => {
  beforeEach(() => {
    mockRepoReset()
    mockAuthorNotice({ git_name: MOCK_AUTHOR.git_name, git_email: MOCK_AUTHOR.git_email })
  })
  const base = () => ifMatchOf(mockDocBase(DOC))
  const statuses = (q) => editsOf(mockRepoEdits(q).body).map((e) => e.status)
  it('queued -> pushing -> pushed with a commit, one step per read', () => {
    assert.equal(mockRepoSave(DOC, '# a\n', base()).status, 200)
    assert.deepEqual(statuses({ path: DOC }), ['pushing'])
    const [e] = editsOf(mockRepoEdits({ path: DOC }).body)
    assert.equal(e.status, 'pushed')
    assert.match(e.commit_sha, /^[0-9a-f]{40}$/)
  })
  it('My edits holds the member\'s edits and their agent\'s, newest first', () => {
    mockRepoSave(DOC, '# a\n', base())
    const rows = editsOf(mockRepoEdits({ mine: true }).body)
    assert.deepEqual(rows.map((e) => [e.actor_kind, e.status]), [['member', 'pushing'], ['agent', 'failed']])
    assert.equal(rows[1].edit_id, MOCK_AGENT_EDIT)
    assert.equal(mockRepoEdits({}).status, 400)
  })
  it('a failed edit is retried: back to the queue, then pushed', () => {
    mockRepoSave(DOC, '# ' + MOCK_FAIL + '\n', base())
    mockRepoEdits({ path: DOC })
    const [e] = editsOf(mockRepoEdits({ path: DOC }).body)
    assert.equal(e.status, 'failed')
    assert.ok(e.last_error)
    assert.equal(mockRepoRetry(e.edit_id).status, 202)
    assert.deepEqual(statuses({ path: DOC }), ['pushing'])
    assert.deepEqual(statuses({ path: DOC }), ['pushed'])
  })
  it('CONTROL only a failed edit is retried; an unknown one is 404', () => {
    mockRepoSave(DOC, '# a\n', base())
    assert.equal(mockRepoRetry('mock-edit-1').status, 409)
    assert.equal(mockRepoRetry('nope').status, 404)
  })
  it('a conflict shows theirs and mine; the save with base = head resolves it', () => {
    mockRepoSave(DOC, '# mine ' + MOCK_CONFLICT + '\n', base())
    mockRepoEdits({ path: DOC })
    assert.deepEqual(statuses({ path: DOC }), ['conflict'])
    const c = conflictOf(mockRepoConflict('mock-edit-1').body)
    assert.ok(c.theirs.includes('Changed on master'))
    assert.ok(c.mine.includes(MOCK_CONFLICT))
    assert.equal(mockDocs(DOC), c.mine, 'the overlay keeps the member\'s text')
    const saved = mockRepoSave(DOC, '# resolved\n', ifMatchOf(c.head_blob))
    assert.equal(saved.status, 200)
    assert.deepEqual(saved.body.superseded, ['mock-edit-1'])
    assert.deepEqual(statuses({ path: DOC }), ['pushing', 'superseded'])
  })
  it('CONTROL the head blob is no base without a conflict; a pushed edit has no conflict view', () => {
    mockRepoSave(DOC, '# x ' + MOCK_CONFLICT + '\n', base())
    const head = conflictOf({ edit_id: 'x', path: DOC, head_blob: '' })
    assert.equal(head.head_blob, '')
    mockRepoReset()
    mockAuthorNotice({ git_name: MOCK_AUTHOR.git_name, git_email: MOCK_AUTHOR.git_email })
    mockRepoSave(DOC, '# a\n', base())
    assert.equal(mockRepoConflict('mock-edit-1').status, 409)
    assert.equal(mockRepoSave(DOC, '# b\n', '"' + 'c'.repeat(40) + '"').status, 409)
  })
  it('the identity probe: a consent for no identity answers 409 naming the real one', () => {
    const a = mockAuthorNotice({ git_name: '-', git_email: '-' })
    assert.equal(a.status, 409)
    assert.equal(a.body.git_email, MOCK_AUTHOR.git_email)
  })
})

describe('i18n', () => {
  const locales = readdirSync(new URL('../../i18n/locales', import.meta.url)).filter((f) => f.endsWith('.json'))
  it('every T12 string is in all 19 locales, with its placeholders', () => {
    assert.equal(locales.length, 19)
    for (const f of locales) {
      const r = JSON.parse(read('i18n/locales/' + f)).docs.repoEdit
      for (const k of ['pushing', 'pushed', 'conflict', 'failed', 'retry', 'resolve', 'merged']) assert.ok(r.chip?.[k], f + ' chip.' + k)
      for (const k of ['title', 'back', 'lead', 'empty', 'by_you', 'by_agent', 'superseded', 'published', 'identity_lead', 'identity', 'identity_ok']) assert.ok(r.mine?.[k], f + ' mine.' + k)
      for (const k of ['lead', 'theirs', 'mine', 'save']) assert.ok(r.conflict?.[k], f + ' conflict.' + k)
      for (const k of ['not_failed', 'not_conflict', 'not_yours', 'no_edit']) assert.ok(r.err?.[k], f + ' err.' + k)
      assert.match(r.chip.merged, /\{sha\}/, f)
      assert.match(r.mine.by_agent, /\{agent\}/, f)
    }
  })
  it('the English chip reads as spec §3', () => {
    const c = JSON.parse(read('i18n/locales/en.json')).docs.repoEdit.chip
    assert.equal(c.pushing, 'Saved · pushing')
    assert.equal(`${c.conflict} · ${c.resolve}`, 'Conflict · resolve')
    assert.equal(`${c.failed} · ${c.retry}`, 'Not pushed · retry')
  })
})

describe('the first screen stays light (AC-02 budget)', () => {
  it('the chip, My edits and the conflict view load lazily on the docs page', () => {
    const s = read('src/pages/docs.vue')
    for (const c of ['RepoDocStatus', 'RepoDocMyEdits', 'RepoDocConflict']) {
      assert.match(s, new RegExp(`const ${c} = defineAsyncComponent\\(\\(\\) => import\\('~/components/${c}\\.vue'\\)\\)`), c)
      assert.equal(new RegExp(`import\\s+${c}\\b`).test(s), false, c)
    }
  })
})
