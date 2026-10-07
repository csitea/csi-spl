// spec 075 repo-edit T11: editable Repo Docs in the WUI. tree.json's
// editable flag and blob are read leniently; a save sends If-Match = the
// opened blob; a 428 names the identity the notice shows; 409/413/422/429
// and the 403 reasons each say why; the mock hub answers 428 until the
// member consents; the §4.2 notice text is in all 19 locales; the editor,
// its store and the repo-edit code stay out of the first screen.
//
// Run: node tests/unit/repo-edit.test.mjs
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { ifMatchOf, noticeIdentity, repoEditFiles, saveErrorOf } from '../../src/utils/repo-edit.mjs'
import { MOCK_AUTHOR, MOCK_REJECT, mockAuthorNotice, mockDocBase, mockDocs, mockRepoReset, mockRepoSave } from '../../src/utils/docs-mock.mjs'
import { FIRST_SCREEN_PAGES } from '../../src/utils/i18n-first-screen.mjs'

const read = (p) => readFileSync(new URL('../../' + p, import.meta.url), 'utf8')
const SHA = 'a'.repeat(40)

describe('repoEditFiles', () => {
  it('reads editable, blob and overlay per path', () => {
    const m = repoEditFiles([{ path: 'a/b.md', editable: true, blob: SHA, overlay: true }, { path: 'c.md', editable: false, blob: SHA }])
    assert.deepEqual(m.get('a/b.md'), { editable: true, blob: SHA, overlay: true })
    assert.deepEqual(m.get('c.md'), { editable: false, blob: SHA, overlay: false })
  })
  it('CONTROL an unflagged file (editing off, an older hub) is not editable', () => {
    const m = repoEditFiles([{ path: 'a.md' }, { path: 'b.md', editable: 'true', blob: 'nope' }, { path: '../x.md', editable: true }, null])
    assert.equal(m.get('a.md').editable, false)
    assert.equal(m.get('b.md').editable, false)
    assert.equal(m.get('b.md').blob, '')
    assert.equal(m.has('../x.md'), false)
    assert.equal(repoEditFiles(undefined).size, 0)
  })
})

describe('ifMatchOf', () => {
  it('quotes the opened blob', () => {
    assert.equal(ifMatchOf(SHA), `"${SHA}"`)
    assert.equal(ifMatchOf(`W/"${SHA.toUpperCase()}"`), `"${SHA}"`)
  })
  it('CONTROL no blob (a doc not published yet) sends no If-Match', () => {
    for (const b of ['', null, undefined, 'abc', 'z'.repeat(40)]) assert.equal(ifMatchOf(b), '', String(b))
  })
})

describe('noticeIdentity', () => {
  it('is the identity a 428 names', () => {
    assert.deepEqual(noticeIdentity({ error: 'author_notice_required', git_name: 'FirstName LastName', git_email: 'm@example.com', author_source: 'signin' }),
      { git_name: 'FirstName LastName', git_email: 'm@example.com', author_source: 'signin' })
  })
  it('CONTROL a body without both name and email is no notice', () => {
    for (const b of [null, {}, { git_name: 'x' }, { git_email: 'x@example.com' }, 'x']) assert.equal(noticeIdentity(b), null)
  })
})

describe('saveErrorOf', () => {
  it('409 413 422 429 each say why', () => {
    assert.equal(saveErrorOf(409, { error: 'base_unknown' }).key, 'docs.repoEdit.err.conflict')
    assert.equal(saveErrorOf(413, { error: 'too_large' }).key, 'docs.repoEdit.err.too_large')
    assert.equal(saveErrorOf(422, { error: 'rejected_text' }).key, 'docs.repoEdit.err.rejected')
    assert.equal(saveErrorOf(429, { error: 'rate_limited' }).key, 'docs.repoEdit.err.rate_limited')
  })
  it('422 names the first hit\'s rule and line', () => {
    assert.deepEqual(saveErrorOf(422, { hits: [{ kind: 'secret', rule: 'private key', line: 7 }, { rule: 'x', line: 9 }] }),
      { key: 'docs.repoEdit.err.rejected_line', params: { rule: 'private key', line: 7 } })
    assert.equal(saveErrorOf(422, { hits: [{ kind: 'gate', rule: 'gate', line: 0 }] }).key, 'docs.repoEdit.err.rejected')
  })
  it('403 by reason, 404 off, anything else failed', () => {
    for (const [r, k] of [['path_denied', 'path_denied'], ['email_unverified', 'email_unverified'], ['member_too_new', 'member_too_new'], ['workspace_blocked', 'workspace_blocked'], ['forbidden', 'forbidden'], ['', 'forbidden']]) {
      assert.equal(saveErrorOf(403, { error: r }).key, 'docs.repoEdit.err.' + k, r)
    }
    assert.equal(saveErrorOf(404, { error: 'repo_edit_off' }).key, 'docs.repoEdit.err.off')
    for (const s of [0, 500, 503]) assert.equal(saveErrorOf(s, null).key, 'docs.repoEdit.err.failed')
  })
})

describe('the mock hub', () => {
  beforeEach(() => mockRepoReset())
  const DOC = 'csi-spl-doc/doc/md/csi-spl.feature.md'
  const DENIED = 'csi-spl-doc/doc/help/how-to-post.md'
  const tree = () => JSON.parse(mockDocs('tree.json')).files
  it('tree.json flags each doc editable with a blob; the help doc is denied', () => {
    const m = repoEditFiles(tree())
    assert.equal(m.get(DOC).editable, true)
    assert.equal(m.get(DOC).blob, mockDocBase(DOC))
    assert.equal(m.get(DENIED).editable, false)
  })
  it('428 with the identity until consent, then 200 and the overlay serves the text', () => {
    const base = ifMatchOf(mockDocBase(DOC))
    const first = mockRepoSave(DOC, '# new\n', base)
    assert.equal(first.status, 428)
    assert.deepEqual(noticeIdentity(first.body), MOCK_AUTHOR)
    assert.equal(mockDocs(DOC).startsWith('# Spool feature'), true, 'nothing written before consent')
    assert.equal(mockAuthorNotice({ git_name: MOCK_AUTHOR.git_name, git_email: MOCK_AUTHOR.git_email }).status, 204)
    const second = mockRepoSave(DOC, '# new\n', base)
    assert.equal(second.status, 200)
    assert.equal(second.body.status, 'queued')
    assert.equal(mockDocs(DOC), '# new\n')
    assert.equal(repoEditFiles(tree()).get(DOC).overlay, true)
  })
  it('CONTROL a wrong base 409, a denied path 403, a planted secret 422, another identity 409', () => {
    assert.equal(mockRepoSave(DOC, 'x', '"' + 'b'.repeat(40) + '"').status, 409)
    assert.equal(mockRepoSave(DENIED, 'x', ifMatchOf(mockDocBase(DENIED))).status, 403)
    const r = mockRepoSave(DOC, 'a\n' + MOCK_REJECT + '\n', ifMatchOf(mockDocBase(DOC)))
    assert.equal(r.status, 422)
    assert.deepEqual(saveErrorOf(r.status, r.body).params, { rule: 'private key', line: 2 })
    assert.equal(mockAuthorNotice({ git_name: 'Other', git_email: MOCK_AUTHOR.git_email }).status, 409)
  })
})

describe('i18n', () => {
  const locales = readdirSync(new URL('../../i18n/locales', import.meta.url)).filter((f) => f.endsWith('.json'))
  it('all 19 locales carry the notice and every message', () => {
    assert.equal(locales.length, 19)
    const leaves = (o, pre = '') => Object.entries(o).flatMap(([k, v]) => typeof v === 'object' ? leaves(v, pre + k + '.') : [pre + k])
    const want = leaves(JSON.parse(read('i18n/locales/en.json')).docs.repoEdit).sort()
    assert.ok(want.includes('authorNotice.title') && want.includes('err.rate_limited'), want.join())
    for (const f of locales) {
      const r = JSON.parse(read('i18n/locales/' + f)).docs.repoEdit
      assert.deepEqual(r && leaves(r).sort(), want, f)
      assert.match(r.err.rejected_line, /\{line\}/, f)
      assert.match(r.err.rejected_line, /\{rule\}/, f)
    }
  })
  it('the English notice is the spec §4.2 text', () => {
    const n = JSON.parse(read('i18n/locales/en.json')).docs.repoEdit.authorNotice
    assert.equal(n.title, 'Your edit will be public, with your name and email')
    assert.equal(n.lead, "Saved edits are pushed to this product's public GitHub repository. Git records you as the author:")
    assert.equal(n.public, 'Anyone can read this name and email address in the repository history, and it cannot be removed later.')
    assert.equal(n.other, 'To publish under a different verified address, ask a workspace admin to set your author identity before you save.')
    assert.equal(n.confirm, 'I understand, save')
  })
})

describe('the first screen stays light (AC-02 budget)', () => {
  it('the docs page is not a first-screen page and loads the editor lazily', () => {
    assert.equal(Object.values(FIRST_SCREEN_PAGES).includes('pages/docs.vue'), false)
    const s = read('src/pages/docs.vue')
    assert.match(s, /defineAsyncComponent\(\(\) => import\('~\/components\/RepoDocEditor\.vue'\)\)/)
    assert.equal(/import\s+RepoDocEditor\b/.test(s), false)
  })
  it('no first-screen file, layout, plugin or app.vue names the repo-edit code', () => {
    const files = ['src/app.vue', ...Object.values(FIRST_SCREEN_PAGES).map((p) => 'src/' + p)]
    for (const d of ['src/layouts', 'src/plugins']) for (const f of readdirSync(new URL('../../' + d, import.meta.url))) files.push(d + '/' + f)
    for (const f of files) assert.equal(/repoEdit|repo-edit|RepoDoc/.test(read(f)), false, f)
  })
})
