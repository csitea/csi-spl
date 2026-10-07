// spec 104 T005 (§4.4, FR-005/006/009): the lazy API reference viewer.
// ApiDocViewer.vue + ApiRouteCard.vue are compiled HERE from the shipped
// SFCs (Vue's own compiler-sfc, TypeScript stripped by typescript) and
// mounted on a small in-memory renderer, so the template, the script and
// the filter are what ships - not a copy. The fixture is a 4-operation
// OpenAPI 3.0.3 document, not the hub's file.
//
// Positive: grouped by tag; search narrows; the scope toggle hides and
// shows `x-role: operator` operations; params, body and the {error, detail}
// envelope render. Negative: malformed JSON (inline and fetched) shows the
// error state without throwing; the only request is GET /v1/openapi.json.
// Controls that must fail: a mutant viewer that ignores the toggle is caught
// by the same assertion, and the CSP scan flags a planted inline style.
//
// Run: node tests/unit/api-doc-viewer.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import { parse, compileScript } from 'vue/compiler-sfc'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const VIEWER = 'src/components/ApiDocViewer.vue'
const CARD = 'src/components/ApiRouteCard.vue'
const BASE = 'https://hub.invalid'

const ENVELOPE = { $ref: '#/components/responses/Forbidden' }
const FIXTURE = {
  openapi: '3.0.3',
  info: { title: 'Fixture hub', version: '9.9.9' },
  servers: [{ url: 'https://{tenant}.{baseDomain}', variables: { tenant: { default: 't1' }, baseDomain: { default: '<BASE_DOMAIN>' } } }],
  paths: {
    '/v1/messages/{id}': {
      parameters: [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }],
      get: { operationId: 'getMessage', tags: ['messages'], summary: 'Read one message', parameters: [{ $ref: '#/components/parameters/TenantHeader' }], responses: { 200: { description: 'OK' }, 403: ENVELOPE } },
      delete: { operationId: 'deleteMessage', tags: ['messages'], summary: 'Delete one message', responses: { 204: { description: 'Deleted' }, 403: ENVELOPE } },
    },
    '/v1/send': {
      post: {
        operationId: 'postSend', tags: ['messages'], summary: 'Send a message',
        requestBody: { content: { 'application/json': { schema: { $ref: '#/components/schemas/Send' } } } },
        responses: { 202: { description: 'Accepted' }, 400: { $ref: '#/components/responses/BadRequest' } },
      },
    },
    '/v1/admin/boxes': {
      get: { operationId: 'getAdminBoxes', tags: ['admin'], summary: 'List boxes', 'x-role': 'operator', responses: { 200: { description: 'OK' }, 403: ENVELOPE } },
    },
  },
  components: {
    parameters: { TenantHeader: { name: 'X-Spool-Tenant', in: 'header', required: false, schema: { type: 'string' } } },
    responses: {
      Forbidden: { description: 'Forbidden', content: { 'application/json': { schema: { $ref: '#/components/schemas/ErrorEnvelope' } } } },
      BadRequest: { description: 'Bad Request', content: { 'application/json': { schema: { $ref: '#/components/schemas/ErrorEnvelope' } } } },
    },
    schemas: {
      ErrorEnvelope: { type: 'object', required: ['error'], properties: { error: { type: 'string', example: 'not_found' }, detail: { type: 'string', example: 'no such message' } } },
      Send: { type: 'object', required: ['to', 'body'], properties: { to: { type: 'string' }, body: { type: 'string' } } },
    },
  },
}
const SOURCE = JSON.stringify(FIXTURE)

/* ---------- compile the shipped SFCs into importable modules ---------- */

const VUE_URL = import.meta.resolve('vue')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
/* Nuxt auto-imports useI18n; the stub reads the test's catalogue from globalThis */
const I18N_PRELUDE = 'const useI18n = (...a) => globalThis.__apiDocI18n(...a);\n'
const API_STUB = dataUrl('export const useSpoolApi = () => globalThis.__apiDocApi')

function compileSfc(file, source, imports) {
  const { descriptor, errors } = parse(source, { filename: file })
  assert.deepEqual(errors, [], `${file} parses`)
  const script = compileScript(descriptor, { id: file, inlineTemplate: true, isProd: true })
  let js = ts.transpileModule(script.content, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false } }).outputText
  js = js.replace(/from ['"]vue['"]/g, `from '${VUE_URL}'`)
  for (const [spec, url] of Object.entries(imports)) js = js.split(`'${spec}'`).join(`'${url}'`)
  return I18N_PRELUDE + js
}

async function loadViewer(mutate = (s) => s) {
  const card = dataUrl(compileSfc(CARD, read(CARD), {}))
  const code = compileSfc(VIEWER, mutate(read(VIEWER)), { './ApiRouteCard.vue': card, '~/composables/useSpoolApi': API_STUB })
  return import(dataUrl(code))
}

/* ---------- a DOM-less renderer: enough to mount, find, fire, read ---------- */

function el(tag) { return { tag, props: {}, children: [], parent: null, text: '' } }
const ops = {
  createElement: (tag) => el(tag),
  createText: (text) => ({ ...el('#text'), text }),
  createComment: (text) => ({ ...el('#comment'), text }),
  setText: (n, text) => { n.text = text },
  setElementText: (n, text) => { n.children = text ? [{ ...el('#text'), text, parent: n }] : [] },
  insert(child, parent, anchor) {
    if (child.parent) ops.remove(child)
    const i = anchor ? parent.children.indexOf(anchor) : -1
    if (i < 0) parent.children.push(child)
    else parent.children.splice(i, 0, child)
    child.parent = parent
  },
  remove(child) {
    const p = child.parent
    if (p) p.children.splice(p.children.indexOf(child), 1)
    child.parent = null
  },
  parentNode: (n) => n.parent,
  nextSibling(n) {
    const sibs = n.parent?.children || []
    return sibs[sibs.indexOf(n) + 1] || null
  },
  patchProp(n, key, _prev, next) { n.props[key] = next },
}
const { createApp } = Vue.createRenderer(ops)

const textOf = (n) => n.tag === '#text' ? n.text : n.tag === '#comment' ? '' : n.children.map(textOf).join('')
function findAll(n, pred, out = []) {
  if (pred(n)) out.push(n)
  for (const c of n.children || []) findAll(c, pred, out)
  return out
}
const byTest = (root, name) => findAll(root, (n) => n.props?.['data-test'] === name)
const flush = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setTimeout(r, 0)); await Vue.nextTick() } }

/* the catalogue: T006 adds docs.api.* to i18n; here a key renders as itself */
function setupGlobals({ fetchImpl } = {}) {
  const calls = []
  globalThis.__apiDocI18n = () => ({ t: (k, p) => (p ? `${k}:${JSON.stringify(p)}` : k) })
  globalThis.__apiDocApi = { base: BASE, token: 'tok', credentials: 'include' }
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), method: (init?.method || 'GET').toUpperCase() })
    return fetchImpl ? fetchImpl(url, init) : new Response(SOURCE, { status: 200 })
  }
  return calls
}

async function mount(mod, props) {
  const root = el('#root')
  const app = createApp(mod.default, props)
  const errors = []
  app.config.errorHandler = (e) => { errors.push(e) }
  app.config.warnHandler = () => {}
  app.mount(root)
  await flush()
  return { root, errors, app }
}

const opIds = (root) => byTest(root, 'api-route').map((n) => n.props['data-op'])
const tagNames = (root) => byTest(root, 'api-doc-tag').map((n) => n.props['data-tag'])
async function fire(node, event, target) { node.props[event]({ target }); await flush() }

describe('api doc viewer: the fixture renders', () => {
  it('groups operations by tag, member scope by default (no operator route)', async () => {
    setupGlobals()
    const { root, errors } = await mount(await loadViewer(), { source: SOURCE })
    assert.deepEqual(errors, [])
    assert.equal(byTest(root, 'api-doc')[0].props['data-state'], 'ready')
    assert.deepEqual(tagNames(root), ['messages'])
    assert.deepEqual(opIds(root), ['getMessage', 'deleteMessage', 'postSend'])
    assert.equal(textOf(byTest(root, 'api-doc-version')[0]), '9.9.9')
    assert.match(textOf(byTest(root, 'api-doc-count')[0]), /"n":3/)
  })

  it('a card shows the method badge, path params, the body schema and the {error, detail} envelope', async () => {
    setupGlobals()
    const { root } = await mount(await loadViewer(), { source: SOURCE })
    const [get, , send] = byTest(root, 'api-route')
    assert.equal(textOf(byTest(get, 'api-route-method')[0]), 'GET')
    assert.equal(textOf(byTest(get, 'api-route-path')[0]), '/v1/messages/{id}')
    const params = textOf(byTest(get, 'api-route-params')[0])
    assert.match(params, /id\s*path · string\s*docs\.api\.required/)
    assert.match(params, /X-Spool-Tenant/)
    const forbidden = textOf(byTest(get, 'api-route-responses')[0])
    assert.match(forbidden, /"error"/)
    assert.match(forbidden, /"detail"/)
    assert.match(textOf(byTest(send, 'api-route-body')[0]), /"to"[\s\S]*"body"/)
    assert.equal(findAll(root, (n) => n.tag === 'details').length, 3, 'a card expands with <details>, no script')
  })
})

describe('api doc viewer: search and scope', () => {
  it('search narrows by path, tag or method; every word must match', async () => {
    setupGlobals()
    const { root } = await mount(await loadViewer(), { source: SOURCE })
    const box = byTest(root, 'api-doc-search')[0]
    await fire(box, 'onInput', { value: 'delete' })
    assert.deepEqual(opIds(root), ['deleteMessage'])
    await fire(box, 'onInput', { value: '/v1/send' })
    assert.deepEqual(opIds(root), ['postSend'])
    await fire(box, 'onInput', { value: 'messages get' })
    assert.deepEqual(opIds(root), ['getMessage'])
    await fire(box, 'onInput', { value: 'nothing-matches' })
    assert.deepEqual(opIds(root), [])
    assert.equal(byTest(root, 'api-doc-empty').length, 1)
  })

  it('the toggle shows and hides x-role: operator operations', async () => {
    setupGlobals()
    const { root } = await mount(await loadViewer(), { source: SOURCE })
    const toggle = byTest(root, 'api-doc-operator')[0]
    await fire(toggle, 'onChange', { checked: true })
    assert.deepEqual(tagNames(root), ['admin', 'messages'])
    assert.ok(opIds(root).includes('getAdminBoxes'))
    const admin = byTest(root, 'api-route').find((n) => n.props['data-op'] === 'getAdminBoxes')
    assert.equal(admin.props['data-role'], 'operator')
    assert.equal(byTest(admin, 'api-route-operator').length, 1)
    await fire(toggle, 'onChange', { checked: false })
    assert.ok(!opIds(root).includes('getAdminBoxes'))
  })

  it('CONTROL: a viewer that ignores the toggle fails the member-scope assertion', async () => {
    setupGlobals()
    const mutant = (s) => {
      const out = s.replace('filterOperations(doc.value.ops, query.value, operator.value)', 'filterOperations(doc.value.ops, query.value, true)')
      assert.notEqual(out, s, 'the mutation applies to the shipped source')
      return out
    }
    const { root } = await mount(await loadViewer(mutant), { source: SOURCE })
    assert.throws(() => assert.ok(!opIds(root).includes('getAdminBoxes')))
  })
})

describe('api doc viewer: errors and requests', () => {
  it('malformed inline JSON shows the error state without throwing', async () => {
    setupGlobals()
    for (const bad of ['{not json', '{"openapi":"2.0","paths":{}}', 'null']) {
      const { root, errors } = await mount(await loadViewer(), { source: bad })
      assert.deepEqual(errors, [], bad)
      assert.equal(byTest(root, 'api-doc')[0].props['data-state'], 'failed', bad)
      assert.equal(byTest(root, 'api-doc-error').length, 1, bad)
      assert.equal(byTest(root, 'api-route').length, 0, bad)
    }
  })

  it('a malformed fetched spec and a 403 both show the error state', async () => {
    for (const res of [() => new Response('{oops', { status: 200 }), () => new Response('{"error":"forbidden"}', { status: 403 })]) {
      setupGlobals({ fetchImpl: res })
      const { root, errors } = await mount(await loadViewer(), {})
      assert.deepEqual(errors, [])
      assert.equal(byTest(root, 'api-doc-error').length, 1)
    }
  })

  it('without `source` it fetches GET /v1/openapi.json once and nothing else, even after search and toggle', async () => {
    const calls = setupGlobals()
    const { root } = await mount(await loadViewer(), {})
    assert.deepEqual(opIds(root), ['getMessage', 'deleteMessage', 'postSend'])
    await fire(byTest(root, 'api-doc-operator')[0], 'onChange', { checked: true })
    await fire(byTest(root, 'api-doc-search')[0], 'onInput', { value: 'admin' })
    assert.deepEqual(calls, [{ url: `${BASE}/v1/openapi.json`, method: 'GET' }])
  })

  it('with `source` it makes no request at all', async () => {
    const calls = setupGlobals()
    await mount(await loadViewer(), { source: SOURCE })
    assert.deepEqual(calls, [])
  })
})

/* ---------- CSP, budget, hygiene: static checks on the shipped files ---------- */

/** What the WUI CSP refuses (no unsafe-eval, no unsafe-inline) or the brief forbids. */
function cspProblems(src) {
  const tpl = src.slice(src.indexOf('<template>'), src.lastIndexOf('</template>'))
  const script = (src.match(/<script[\s\S]*?<\/script>/g) || []).join('\n')
  const out = []
  if (/\beval\s*\(|new\s+Function\b|setTimeout\(\s*['"`]/.test(script)) out.push('eval')
  if (/\s:?style\s*=/.test(tpl)) out.push('inline style=')
  if (/\s@?on[a-z]+\s*=\s*"/.test(tpl.replace(/\s@[a-z.]+="[^"]*"/g, ''))) out.push('inline on*=')
  if (/v-html/.test(tpl)) out.push('v-html')
  if (/createElement\(\s*['"]style|<style[^>]*>[\s\S]*?<\/style>[\s\S]*<style/.test(script)) out.push('runtime style')
  if (/try it out|tryItOut|<form|\smethod=/i.test(tpl)) out.push('try it out')
  if (/\d+px/.test((src.match(/font-size:[^;]+/g) || []).join(';'))) out.push('px font size')
  return out
}

describe('api doc viewer: CSP, theme, budget, hygiene', () => {
  it('both SFCs pass the CSP scan: no eval, inline style / on*, v-html, Try it out or px font sizes', () => {
    for (const f of [VIEWER, CARD]) assert.deepEqual(cspProblems(read(f)), [], f)
  })

  it('CONTROL: the scan flags a planted inline style and a planted eval', () => {
    const src = read(CARD)
    assert.deepEqual(cspProblems(src.replace('<article', '<article style="color:red"')), ['inline style='])
    assert.deepEqual(cspProblems(src.replace("defineProps", "eval('1'); defineProps")), ['eval'])
  })

  it('colours come from theme tokens only (no #hex, no rgb())', () => {
    for (const f of [VIEWER, CARD]) {
      const css = read(f).split('<style scoped>')[1] || ''
      assert.doesNotMatch(css, /#[0-9a-f]{3,8}\b|rgba?\(/i, f)
    }
  })

  it('nothing imports the viewer yet (T006 mounts it lazily): 0 KB initial-chunk delta', () => {
    const hits = []
    const walk = (d) => {
      for (const n of readdirSync(d)) {
        const p = join(d, n)
        if (statSync(p).isDirectory()) { if (n !== 'node_modules' && !n.startsWith('.')) walk(p); continue }
        if (!/\.(vue|ts|mjs|js)$/.test(n) || p.endsWith('ApiDocViewer.vue') || p.endsWith('ApiRouteCard.vue')) continue
        const s = readFileSync(p, 'utf8')
        /* the one allowed form is a dynamic import (T006: defineAsyncComponent) */
        if (/<ApiDocViewer|<api-doc-viewer|<ApiRouteCard/.test(s) || /import\s+[\w{][^'"]*from\s+['"][^'"]*ApiDocViewer/.test(s)) hits.push(p)
      }
    }
    walk(join(WUI, 'src'))
    assert.deepEqual(hits, [])
  })

  it('no literal host or domain in the viewer', () => {
    for (const f of [VIEWER, CARD]) assert.doesNotMatch(read(f), /https?:\/\/|\.(net|com|io|app)\b/, f)
  })
})
