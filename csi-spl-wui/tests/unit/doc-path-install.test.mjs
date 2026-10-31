// SPL-4515 (SPL-4509 row 8, round 2 of the console errors): the doc-path
// linker (utils/doc-path-install.ts) reads the member tree
// GET /v1/docs/tree.json only for a signed-in reader. Signed out it reads
// only the build's public docs index, so /docs signed out logs no 401.
//
//   • session 'out': one request, PUBLIC_DOCS_DIR/index.json, none to tree.json
//   • signed in: the tree as before, the public index only when it is empty
//   • a failed session check reads the tree, as before
//
// Run: node --test tests/unit/doc-path-install.test.mjs
import { describe, it, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
const fileUrl = (p) => pathToFileURL(join(WUI, p)).href

/* the real utils by file URL; the Nuxt-bound imports (api, session) are stubs */
const js = tsToJs(read('src/utils/doc-path-install.ts'))
  .replace(/from '~\/utils\/([^']+)'/g, (_, f) => `from '${fileUrl('src/utils/' + f)}'`)
  .replace(/^import \{ useSpoolApi \}.*$/m, 'const { useSpoolApi } = globalThis.__dpi')
  .replace(/^import \{ useSessionStore \}.*$/m, 'const { useSessionStore } = globalThis.__dpi')
globalThis.__dpi = { useSpoolApi: () => ({}), useSessionStore: () => ({ state: 'in' }) }
const { installDocPaths } = await import(dataUrl(js))
const { activeDocPathLinker, setDocPathLinker } = await import(fileUrl('src/utils/doc-path-hook.mjs'))

const DOC = 'csi-spl-doc/doc/md/README.md'
const API = { base: 'https://hub.example.com', mock: false }
const TREE = API.base + '/v1/docs/tree.json'
const INDEX = '/docs-public/index.json'
let asked = []
function serve(routes) {
  asked = []
  globalThis.fetch = async (url) => {
    asked.push(String(url))
    const [status, body] = routes[String(url)] || [404, {}]
    return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
  }
}
const tree = { files: [{ path: DOC }] }
const index = { files: [{ path: DOC }] }

describe('doc-path-install: who reads which list', () => {
  beforeEach(() => setDocPathLinker(null))

  it('signed out: only the public index, no request to the member tree', async () => {
    serve({ [TREE]: [401, { error: 'unauthorized' }], [INDEX]: [200, index] })
    await installDocPaths(API, async () => true)
    assert.deepEqual(asked.filter((u) => u.includes('/v1/docs/tree.json')), [], 'asked: ' + asked.join(' '))
    assert.deepEqual(asked, [INDEX])
    assert.ok(activeDocPathLinker()?.resolve(DOC), 'the public index installs the linker')
  })

  it('signed in: the member tree, and no public index when it lists docs', async () => {
    serve({ [TREE]: [200, tree], [INDEX]: [200, index] })
    await installDocPaths(API, async () => false)
    assert.deepEqual(asked, [TREE])
    assert.ok(activeDocPathLinker()?.resolve(DOC))
  })

  it('signed in, the tree fails: the public index after it, as before', async () => {
    serve({ [TREE]: [503, {}], [INDEX]: [200, index] })
    await installDocPaths(API, async () => false)
    assert.deepEqual(asked, [TREE, INDEX])
  })

  it('a failed session check reads the tree, as before', async () => {
    serve({ [TREE]: [200, tree] })
    await installDocPaths(API, async () => { throw new Error('probe down') })
    assert.deepEqual(asked, [TREE])
  })

  it('no session check given: the tree, as before', async () => {
    serve({ [TREE]: [200, tree] })
    await installDocPaths(API)
    assert.deepEqual(asked, [TREE])
  })
})
