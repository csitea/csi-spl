// Perf round 3, P3-20: a build ships every static message (no placeholder,
// link, plural or escape) as its plain string, not the compiled AST
// (src/node/i18n/split-catalogue.mjs plainStatics), and vue-i18n compiles
// such a string with src/utils/i18n-plain-messages.mjs. Proves: only the
// static AST shape is replaced, and every `en` message translates to exactly
// the same text through the plain catalogue as through the AST one.
import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { generateJSON } from '@intlify/bundle-utils'
import { compile, createCoreContext, fallbackWithLocaleChain, resolveValue, translate } from '@intlify/core-base'
import { compiledModule, leafKeys, plainStatics } from '../../src/node/i18n/split-catalogue.mjs'
import { plainMessageCompiler } from '../../src/utils/i18n-plain-messages.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8'))
const tmp = mkdtempSync(join(tmpdir(), 'i18n-plain-'))
after(() => rmSync(tmp, { recursive: true, force: true }))

const OPTS = { type: 'plain', env: 'production', jit: true, isGlobal: false, allowDynamic: true, strictMessage: true, escapeHtml: false, forceStringify: false, onlyLocales: [] }
// what vue-i18n registers on core-base; without it every key resolves to itself
const WIRED = { messageResolver: resolveValue, localeFallbacker: fallbackWithLocaleChain }
let n = 0
/** Import module code as an ES module. */
async function load(code) {
  const p = join(tmp, `m${n++}.mjs`)
  writeFileSync(p, code)
  return (await import(pathToFileURL(p).href)).default
}
const get = (o, k) => k.split('.').reduce((a, s) => a?.[s], o)

describe('plainStatics', () => {
  it('replaces a static message and nothing else', async () => {
    const cat = await load(compiledModule({ a: 'Hello "x"', b: 'Hi {n}', c: 'one | two', d: "x{'@'}y", e: '@:a' }, 'x.mjs'))
    assert.equal(cat.a, 'Hello "x"')
    for (const k of ['b', 'c', 'd', 'e']) assert.equal(typeof cat[k], 'object', k)
  })
  it('is idempotent', () => {
    const code = generateJSON(JSON.stringify({ a: 'Hello' }), { ...OPTS, filename: 'y.json' }).code
    assert.equal(plainStatics(plainStatics(code)), plainStatics(code))
  })
})

describe('every en message, plain vs AST', async () => {
  const ast = await load(generateJSON(JSON.stringify(en), { ...OPTS, filename: 'en.json' }).code)
  const plain = await load(compiledModule(en, 'en.mjs'))
  const keys = leafKeys(en)
  const strings = keys.filter((k) => typeof get(plain, k) === 'string')

  it('most messages ship as plain strings', () => {
    assert.ok(strings.length > keys.length * 0.8, `${strings.length} of ${keys.length}`)
  })
  it('translates every key to the same text', () => {
    const a = createCoreContext({ locale: 'en', messages: { en: ast }, messageCompiler: compile, missingWarn: false, fallbackWarn: false, ...WIRED })
    const b = createCoreContext({ locale: 'en', messages: { en: plain }, messageCompiler: plainMessageCompiler, missingWarn: false, fallbackWarn: false, ...WIRED })
    const diff = []
    for (const k of keys) {
      for (const args of [[], [{ n: 3, count: 3, name: 'X', target: 'T', provider: 'P' }], [2]]) {
        let x, y
        try { x = translate(a, k, ...args) } catch (e) { x = `throws ${e.message}` }
        try { y = translate(b, k, ...args) } catch (e) { y = `throws ${e.message}` }
        if (x !== y) diff.push({ k, x, y })
      }
    }
    assert.deepEqual(diff.slice(0, 5), [])
    /* and it is the text, not a key or an error, on both sides */
    for (const k of strings.slice(0, 50)) assert.equal(translate(b, k), get(en, k), k)
  })
  it('a plain message in a vnode context (<i18n-t>) comes back normalized, as the AST does', () => {
    const k = strings[0]
    const ctx = { type: 'vnode', normalize: (v) => ['N', ...v] }
    assert.deepEqual(plainMessageCompiler(get(plain, k), {})(ctx), compile(get(ast, k), {})(ctx))
  })
})

describe('wiring', () => {
  it('the build ships the core catalogues plain too, and the compiler is registered before vue-i18n', () => {
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    assert.match(cfg, /enforce: "post",\s+transform\(code: string, id: string\) \{[\s\S]{0,200}plainStatics\(code\)/)
    const plugin = readFileSync(join(WUI, 'src/plugins/0.i18n-plain-messages.ts'), 'utf8')
    assert.match(plugin, /enforce: 'pre'/)
    assert.match(plugin, /registerMessageCompiler\(plainMessageCompiler/)
  })
})
