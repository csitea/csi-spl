// Owner t1 3b8891e0 (+ New folder in the Qto explorer): the mock tenant's
// folder routes (-doctree-mock.ts), which CI's e2e drives, answer as the
// hub's do (csi-spl-api internal/hub/wsdoc_nodes.go, spec 120 section 7):
// GET /nodes lists a folder's folders first, then its documents; POST
// /folders makes a folder (201), 409 name_taken for a sibling of the same
// name in any case, 400 under a document, 404 under an unknown parent; a
// document create with a parent lands in that folder. The mock is .ts, so
// the test transpiles it. Each check returns the rules it finds broken, so
// the CONTROL proves it catches a mutated mock (no name check).
//
// Run: node tests/unit/qto-folders.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const MOCK = read('src/components/workspace-docs/-doctree-mock.ts')
const HUB = read('../csi-spl-api/src/go/spool-hub-api/internal/hub/wsdoc_nodes.go')

let n = 0
/** the mock module from TS source, a fresh copy each time (its state is module-level) */
async function loadMock(src) {
  const js = ts.transpileModule(src, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText
    .replace(/from '~\/utils\/file-preview\.mjs'/, `from '${pathToFileURL(join(WUI, 'src/utils/file-preview.mjs')).href}'`)
  return import('data:text/javascript,' + encodeURIComponent(js + `\n// copy ${++n}`))
}

/** the folder rules against one mock; returns the ones broken */
function folderRules(m) {
  const broken = []
  const call = (method, path, body) => m.mockDocTree(method, path, body)
  const names = (r) => r.body.nodes.map((x) => `${x.kind}:${x.name || x.title}`).join(', ')
  const top = call('GET', '/nodes')
  if (top.status !== 200 || names(top) !== 'doc:Handbook') broken.push(`seeded top = ${top.status} ${names(top)}`)
  const f = call('POST', '/folders', { name: 'Plans' })
  if (f.status !== 201 || !f.body.id) broken.push(`folder create = ${f.status}`)
  const again = call('POST', '/folders', { name: 'PLANS' })
  if (again.status !== 409 || again.body.error !== 'name_taken') broken.push(`same name = ${again.status} ${again.body.error}`)
  if (call('POST', '/folders', { name: ' ' }).status !== 400) broken.push('a blank name is not refused')
  if (call('POST', '/folders', { name: 'x', parent: 'nope' }).status !== 404) broken.push('an unknown parent is not 404')
  const d = call('POST', '', { title: 'Roadmap', parent: f.body.id })
  if (d.status !== 200) broken.push(`doc into the folder = ${d.status}`)
  const after = call('GET', '/nodes')
  if (names(after) !== 'folder:Plans, doc:Handbook') broken.push(`top after = ${names(after)} (folders first)`)
  if (after.body.nodes[0]?.child_count !== 1) broken.push(`Plans child_count = ${after.body.nodes[0]?.child_count}`)
  const inside = call('GET', '/nodes?parent=' + f.body.id)
  if (names(inside) !== 'doc:Roadmap' || inside.body.nodes[0].doc !== d.body.id) broken.push(`inside Plans = ${names(inside)}`)
  const docNode = inside.body.nodes[0]?.id
  const under = call('POST', '/folders', { name: 'x', parent: docNode })
  if (under.status !== 400 || under.body.error !== 'parent_is_document') broken.push(`under a document = ${under.status} ${under.body.error}`)
  if (call('POST', '/folders', { name: 'Plans', parent: f.body.id }).status !== 201) broken.push('the same name in another folder is refused')
  return broken
}

describe('the mock tenant answers the folder routes as the hub does', () => {
  it('lists, creates, refuses and places a document in a folder', async () => {
    assert.deepEqual(folderRules(await loadMock(MOCK)), [])
  })
  it('a listed node carries the hub\'s fields, no more and no fewer', async () => {
    const hub = [...HUB.slice(HUB.indexOf('type docTreeNode struct'), HUB.indexOf('// handleDocTreeNodes')).matchAll(/json:"([a-z_]+)"/g)].map((x) => x[1]).sort()
    const m = await loadMock(MOCK)
    m.mockDocTree('POST', '/folders', { name: 'A' })
    const keys = m.mockDocTree('GET', '/nodes').body.nodes.map((x) => Object.keys(x).sort().join())
    assert.ok(hub.length === 7, `hub fields: ${hub}`)
    for (const k of keys) assert.equal(k, hub.join())
  })
  it('CONTROL: a mock without the name check is caught', async () => {
    const mutated = MOCK.replace(/if \(\[\.\.\.folders\.values\(\)\]\.some\([^\n]*name_taken[^\n]*\n/, '')
    assert.notEqual(mutated, MOCK, 'the mutation applied')
    assert.ok(folderRules(await loadMock(mutated)).some((r) => r.startsWith('same name')))
  })
})
