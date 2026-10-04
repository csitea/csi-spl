// spec 075 T010: workspace docs in the Docs view. A workspace doc lives at
// /docs/ws/<path>; New doc turns what a member types into a .md path the
// hub takes; the workspace tree.json is read leniently; Edit shows to a
// member who can write (docs.write) and never to a guest; the mock bucket
// saves last-write-wins and keeps the overwritten body.
//
// Run: node tests/unit/ws-docs.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { DOCS_WRITE, canWriteDocs, newDocBody, newDocPath, wsDocsRoute, wsPathOf, wsTreeFiles } from '../../src/utils/ws-docs.mjs'
import { createMockWsDocs } from '../../src/utils/ws-docs-mock.mjs'

describe('routes', () => {
  it('a workspace doc is /docs/ws/<path>, and the page reads its path back', () => {
    assert.equal(wsDocsRoute('runbooks/deploy.md'), '/docs/ws/runbooks/deploy.md')
    assert.equal(wsPathOf('ws/runbooks/deploy.md'), 'runbooks/deploy.md')
  })
  it('CONTROL a repo doc is not a workspace doc', () => {
    assert.equal(wsPathOf('README.md'), '')
    assert.equal(wsPathOf('csi-spl-doc/ws/x.md'), '')
    assert.equal(wsPathOf(''), '')
  })
})

describe('newDocPath', () => {
  it('adds .md, turns spaces into dashes, drops a leading slash', () => {
    assert.equal(newDocPath('runbooks/deploy'), 'runbooks/deploy.md')
    assert.equal(newDocPath('  my notes '), 'my-notes.md')
    assert.equal(newDocPath('/a/b.MD'), 'a/b.md')
    assert.equal(newDocPath('a/b.md'), 'a/b.md')
  })
  it('CONTROL refuses what the hub would refuse', () => {
    for (const p of ['', '   ', '../x', 'a/../b', '.hidden', 'a/.b/c', 'a//b', 'ä.md', null]) assert.equal(newDocPath(p), '', String(p))
  })
  it('a new doc starts with a heading named after the file', () => {
    assert.equal(newDocBody('runbooks/deploy.md'), '# deploy\n\n')
  })
})

describe('wsTreeFiles', () => {
  it('reads the repo catalogue shape, a bare list and a list of paths', () => {
    assert.deepEqual(wsTreeFiles({ v: 1, files: [{ path: 'a/b.md', title: 'B' }] }), [{ path: 'a/b.md', title: 'B' }])
    assert.deepEqual(wsTreeFiles([{ path: 'c.md' }]), [{ path: 'c.md', title: 'c.md' }])
    assert.deepEqual(wsTreeFiles(['d/e.md']), [{ path: 'd/e.md', title: 'e.md' }])
  })
  it('CONTROL drops bad paths and anything that is not a list', () => {
    assert.deepEqual(wsTreeFiles({ files: [{ path: '../x.md' }, { path: '.history/a.md' }, { title: 'no path' }] }), [])
    assert.deepEqual(wsTreeFiles(null), [])
    assert.deepEqual(wsTreeFiles({ files: 'x' }), [])
  })
})

describe('canWriteDocs', () => {
  it('a member with docs.write may edit', () => {
    assert.equal(canWriteDocs({ humanId: 'HUM-1', permissions: ['topics.read', DOCS_WRITE] }), true)
  })
  it('no /v1/view/me answer, or no permission list, fails open as accessAllows does', () => {
    assert.equal(canWriteDocs(null), true)
    assert.equal(canWriteDocs({ humanId: 'HUM-1', permissions: null }), true)
  })
  it('CONTROL a member without docs.write, and a guest, may not', () => {
    assert.equal(canWriteDocs({ humanId: 'HUM-2', permissions: ['topics.read'] }), false)
    assert.equal(canWriteDocs({ humanId: null, permissions: null }), false)
  })
})

describe('the mock bucket', () => {
  it('saves last write wins, keeps the overwritten body, lists and deletes', () => {
    const b = createMockWsDocs({ 'a.md': '# A\n' })
    assert.deepEqual(JSON.parse(b.get('tree.json')).files, [{ path: 'a.md', title: 'A' }])
    b.put('a.md', '# A2\n')
    assert.equal(b.get('a.md'), '# A2\n')
    assert.deepEqual(b.history, [{ path: 'a.md', body: '# A\n' }])
    b.put('n/new.md', '# New\n')
    assert.equal(JSON.parse(b.get('tree.json')).files.length, 2)
    assert.equal(b.del('a.md'), true)
    assert.equal(b.get('a.md'), null)
    assert.equal(b.del('a.md'), false)
  })
})
