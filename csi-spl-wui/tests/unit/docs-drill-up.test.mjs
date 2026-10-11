// t1 3b8891e0: the level above a phone Documents level, for Back after a
// fresh load of /workspace/docs?in=<key> (utils/docs-drill-up.mjs).
// Run: node tests/unit/docs-drill-up.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { drillParent } from '../../src/utils/docs-drill-up.mjs'

/* a tree: top -> Plans -> 2026 -> Roadmap (doc), top -> Handbook (doc);
   Handbook: root -> Introduction -> Scope, root -> Glossary */
const FOLDERS = {
  '': [{ id: 'plans', kind: 'folder', doc: '' }, { id: 'dn-hb', kind: 'doc', doc: 'hb' }],
  plans: [{ id: 'y2026', kind: 'folder', doc: '' }],
  y2026: [{ id: 'dn-rm', kind: 'doc', doc: 'rm' }],
}
const ITEMS = {
  hb: [
    { id: 'root', parent: '' },
    { id: 'intro', parent: 'root' },
    { id: 'scope', parent: 'intro' },
    { id: 'gloss', parent: 'root' },
  ],
}
const client = {
  nodes: async (p) => ({ nodes: FOLDERS[p] ?? [] }),
  subtree: async (d) => {
    if (!ITEMS[d]) throw new Error('404')
    return { items: ITEMS[d] }
  },
}

/** every key from `key` up, Back after Back */
async function chain(key, c = client) {
  const out = []
  for (let k = key; k !== null; k = await drillParent(k, c)) out.push(k)
  return out
}

describe('drillParent', () => {
  it('the top has nothing above it', async () => {
    assert.equal(await drillParent('', client), null)
  })
  it('a section walks up its sections, then its document, then its folder, then the top', async () => {
    assert.deepEqual(await chain('i:hb:scope'), ['i:hb:scope', 'i:hb:intro', 'd:hb', ''])
  })
  it('a top-level section goes to its document', async () => {
    assert.equal(await drillParent('i:hb:gloss', client), 'd:hb')
  })
  it('a document in a nested folder walks the folders up to the top', async () => {
    assert.deepEqual(await chain('d:rm'), ['d:rm', 'f:y2026', 'f:plans', ''])
  })
  it('a nested folder goes to its folder, a top folder to the top', async () => {
    assert.equal(await drillParent('f:y2026', client), 'f:plans')
    assert.equal(await drillParent('f:plans', client), '')
  })
  it('unknown or unreadable keys land on a level that exists', async () => {
    assert.equal(await drillParent('f:gone', client), '')
    assert.equal(await drillParent('d:gone', client), '')
    assert.equal(await drillParent('i:gone:x', client), 'd:gone')
    assert.equal(await drillParent('x:what', client), '')
  })
  it('a folder that fails to list is skipped, the walk goes on', async () => {
    const flaky = { ...client, nodes: async (p) => { if (p === 'plans') throw new Error('500'); return { nodes: FOLDERS[p] ?? [] } } }
    assert.equal(await drillParent('d:hb', flaky), '')
    assert.equal(await drillParent('f:plans', flaky), '')
  })
})
