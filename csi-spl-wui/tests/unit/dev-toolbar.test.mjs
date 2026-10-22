// Spec 148 row B7 (SPL-2912): the local dev toolbar, DevToolbar.vue. The
// SHIPPED SFC is compiled here (vue/compiler-sfc + typescript) with the real
// utils/auth-client.mjs, then
//   • its exported helpers are checked: loopback hosts, the visibility rule
//     (envName "lde" AND a loopback host), the Mailpit link, the endpoint
//   • it is rendered on the server: a prerendered page never carries it,
//     not even with envName "lde"
//   • it is mounted on a small in-memory renderer with a fake window: shown
//     on localhost in local dev; hidden on a dev / prd host, and hidden with
//     any other envName even on localhost
//   • "Dev login" POSTs /api/v1/auth/dev-login with the cookie and loads the
//     app on 2xx; a refusal (404 outside local dev) shows the error and
//     loads nothing
//
// Run: node tests/unit/dev-toolbar.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import * as Vue from 'vue'
import { renderToString } from 'vue/server-renderer'
import { parse, compileScript } from 'vue/compiler-sfc'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const FILE = 'src/components/DevToolbar.vue'
const VUE_URL = import.meta.resolve('vue')
const AUTH_URL = pathToFileURL(join(WUI, 'src/utils/auth-client.mjs')).href
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false } }).outputText

const en = JSON.parse(read('i18n/locales/en.json'))
const tr = (key) => key.split('.').reduce((o, k) => o?.[k], en)

/* Nuxt auto-imports: Vue's API, useI18n (en.json), useRuntimeConfig (per test) */
const PRELUDE = `import { ref, computed, onMounted } from '${VUE_URL}';\n`
  + 'const useI18n = () => ({ t: globalThis.__dt.t });\n'
  + 'const useRuntimeConfig = () => ({ public: globalThis.__dt.pub });\n'

globalThis.__dt = { t: tr, pub: {} }

async function compileSfc() {
  const { descriptor, errors } = parse(read(FILE), { filename: FILE })
  assert.deepEqual(errors, [], `${FILE} parses`)
  const script = compileScript(descriptor, { id: FILE, inlineTemplate: true, isProd: true })
  const js = tsToJs(script.content)
    .replace(/from ['"]vue['"]/g, `from '${VUE_URL}'`)
    .split("'~/utils/auth-client.mjs'").join(`'${AUTH_URL}'`)
  return import(dataUrl(PRELUDE + js))
}

const mod = await compileSfc()
const DevToolbar = mod.default

/* ---------- a DOM-less renderer ---------- */

function node(tag) {
  return { tag, props: {}, children: [], text: '', parent: null }
}
const { createApp } = Vue.createRenderer({
  createElement: (tag) => node(tag),
  createText: (text) => ({ ...node('#text'), text }),
  createComment: (text) => ({ ...node('#comment'), text }),
  setText: (n, text) => { n.text = text },
  setElementText: (n, text) => { n.children = [{ ...node('#text'), text }] },
  insert(child, parent, anchor) {
    if (child.parent) child.parent.children.splice(child.parent.children.indexOf(child), 1)
    const i = anchor ? parent.children.indexOf(anchor) : -1
    if (i < 0) parent.children.push(child)
    else parent.children.splice(i, 0, child)
    child.parent = parent
  },
  remove(child) {
    if (!child.parent) return
    child.parent.children.splice(child.parent.children.indexOf(child), 1)
    child.parent = null
  },
  patchProp(n, key, _prev, next) { n.props[key] = next },
  parentNode: (n) => n.parent,
  nextSibling: (n) => (n.parent ? n.parent.children[n.parent.children.indexOf(n) + 1] || null : null),
})

const textOf = (n) => (n.tag === '#text' ? n.text : n.children.map(textOf).join('')).trim()
function byTestId(n, id) {
  if (n.props['data-testid'] === id) return n
  for (const c of n.children) {
    const hit = byTestId(c, id)
    if (hit) return hit
  }
  return null
}
const flush = () => new Promise((r) => setTimeout(r, 0))

/**
 * Mount the toolbar in a fake browser on `hostname` with config `pub`.
 * `answer` is the fetch's response (or an Error to throw).
 */
async function mount({ hostname, pub, answer = { ok: true, status: 204 }, search = '' }) {
  const calls = []
  const assigned = []
  globalThis.__dt.pub = pub
  globalThis.window = {
    location: { hostname, search, assign: (u) => assigned.push(u) },
    fetch: async (url, init) => {
      calls.push({ url, init })
      if (answer instanceof Error) throw answer
      return answer
    },
  }
  const root = node('#root')
  const app = createApp(DevToolbar)
  app.mount(root)
  await flush()
  return { root, calls, assigned, unmount: () => { app.unmount(); delete globalThis.window } }
}

describe('helpers', () => {
  it('loopback hosts: localhost, *.localhost, 127.0.0.0/8, ::1', () => {
    for (const h of ['localhost', 'LOCALHOST', 'spool.localhost', '127.0.0.1', '127.1.2.3', '[::1]', '::1']) {
      assert.equal(mod.isLoopbackHost(h), true, h)
    }
    for (const h of ['', 'example.com', 'localhost.example.com', '10.0.0.1', '128.0.0.1', '127.0.0', '0.0.0.0', '[::]', 'evil-localhost']) {
      assert.equal(mod.isLoopbackHost(h), false, h)
    }
  })

  it('visible only with envName "lde" AND a loopback host', () => {
    assert.equal(mod.LOCAL_DEV_ENV, 'lde')
    assert.equal(mod.devToolbarVisible('lde', 'localhost'), true)
    assert.equal(mod.devToolbarVisible(' LDE ', '127.0.0.1'), true)
    assert.equal(mod.devToolbarVisible('lde', 'app.example.com'), false, 'a deployed host')
    for (const env of ['', 'dev', 'prd', 'local', undefined, null]) {
      assert.equal(mod.devToolbarVisible(env, 'localhost'), false, `envName ${env}`)
    }
  })

  it('Mailpit link: port 8025 on the loopback name the page uses', () => {
    assert.equal(mod.MAILPIT_PORT, 8025)
    assert.equal(mod.mailpitHref('localhost'), 'http://localhost:8025/')
    assert.equal(mod.mailpitHref('127.0.0.1'), 'http://127.0.0.1:8025/')
    assert.equal(mod.mailpitHref('[::1]'), 'http://localhost:8025/')
    assert.equal(mod.mailpitHref('app.example.com'), 'http://localhost:8025/', 'never a non-loopback host')
  })

  it('endpoint: /api/v1/auth/dev-login on the auth origin, a bad base refused as same-origin', () => {
    assert.equal(mod.devLoginUrl(''), '/api/v1/auth/dev-login')
    assert.equal(mod.devLoginUrl('http://localhost:8080/'), 'http://localhost:8080/api/v1/auth/dev-login')
    assert.equal(mod.devLoginUrl('javascript:alert(1)'), '/api/v1/auth/dev-login')
  })

  it('postDevLogin: POST with the cookie; true on 2xx, false on refusal or no hub', async () => {
    const seen = []
    const ok = await mod.postDevLogin(async (url, init) => { seen.push({ url, init }); return { ok: true, status: 204 } }, '')
    assert.equal(ok, true)
    assert.equal(seen[0].url, '/api/v1/auth/dev-login')
    assert.equal(seen[0].init.method, 'POST')
    assert.equal(seen[0].init.credentials, 'include')
    assert.equal(await mod.postDevLogin(async () => ({ ok: false, status: 404 }), ''), false)
    assert.equal(await mod.postDevLogin(async () => { throw new TypeError('network') }, ''), false)
  })
})

describe('server render (prerender)', () => {
  it('never carries the toolbar, even with envName "lde"', async () => {
    globalThis.__dt.pub = { envName: 'lde', authBase: '' }
    const html = await renderToString(Vue.createSSRApp(DevToolbar))
    assert.doesNotMatch(html, /dev-toolbar/)
    assert.doesNotMatch(html, new RegExp(tr('dev_toolbar.login')))
  })
})

describe('mounted', () => {
  it('local dev on localhost: the Dev login button and the Mailpit link', async () => {
    const m = await mount({ hostname: 'localhost', pub: { envName: 'lde', authBase: '' } })
    try {
      const bar = byTestId(m.root, 'dev-toolbar')
      assert.ok(bar, 'toolbar shown')
      assert.equal(bar.props.role, 'toolbar')
      assert.equal(bar.props['aria-label'], tr('dev_toolbar.aria'))
      const btn = byTestId(m.root, 'dev-toolbar-login')
      assert.equal(btn.tag, 'button')
      assert.equal(textOf(btn), tr('dev_toolbar.login'))
      const link = byTestId(m.root, 'dev-toolbar-mailpit')
      assert.equal(link.tag, 'a')
      assert.equal(link.props.href, 'http://localhost:8025/')
      assert.equal(link.props.rel, 'noopener noreferrer')
      assert.equal(textOf(link), tr('dev_toolbar.mailbox'))
      assert.equal(byTestId(m.root, 'dev-toolbar-error'), null)
    } finally { m.unmount() }
  })

  for (const [why, hostname, envName] of [
    ['a dev / prd host, even if its config said "lde"', 'app.example.com', 'lde'],
    ['envName "dev" on localhost', 'localhost', 'dev'],
    ['envName "prd" on localhost', 'localhost', 'prd'],
    ['no envName on localhost', 'localhost', ''],
  ]) {
    it(`hidden: ${why}`, async () => {
      const m = await mount({ hostname, pub: { envName, authBase: '' } })
      try {
        assert.equal(byTestId(m.root, 'dev-toolbar'), null)
        assert.equal(m.calls.length, 0, 'no request')
      } finally { m.unmount() }
    })
  }

  it('Dev login: POSTs the endpoint, then loads the app (the safe redirect)', async () => {
    const m = await mount({ hostname: '127.0.0.1', pub: { envName: 'lde', authBase: '' }, search: '?redirect=%2Fissues' })
    try {
      assert.equal(byTestId(m.root, 'dev-toolbar-mailpit').props.href, 'http://127.0.0.1:8025/')
      byTestId(m.root, 'dev-toolbar-login').props.onClick()
      await flush()
      assert.equal(m.calls.length, 1)
      assert.equal(m.calls[0].url, '/api/v1/auth/dev-login')
      assert.equal(m.calls[0].init.method, 'POST')
      assert.equal(m.calls[0].init.credentials, 'include')
      assert.deepEqual(m.assigned, ['/issues'])
    } finally { m.unmount() }
  })

  it('Dev login: an off-site redirect is replaced by /', async () => {
    const m = await mount({ hostname: 'localhost', pub: { envName: 'lde', authBase: '' }, search: '?redirect=%2F%2Fevil.example' })
    try {
      byTestId(m.root, 'dev-toolbar-login').props.onClick()
      await flush()
      assert.deepEqual(m.assigned, ['/'])
    } finally { m.unmount() }
  })

  for (const [why, answer] of [['the hub refuses (404)', { ok: false, status: 404 }], ['no hub', new TypeError('network')]]) {
    it(`Dev login: ${why} -> the error, no navigation, the button usable again`, async () => {
      const m = await mount({ hostname: 'localhost', pub: { envName: 'lde', authBase: '' }, answer })
      try {
        byTestId(m.root, 'dev-toolbar-login').props.onClick()
        await flush()
        assert.deepEqual(m.assigned, [])
        const err = byTestId(m.root, 'dev-toolbar-error')
        assert.ok(err, 'error shown')
        assert.equal(err.props.role, 'alert')
        assert.equal(textOf(err), tr('auth.error.failed'))
        assert.equal(byTestId(m.root, 'dev-toolbar-login').props.disabled, false)
      } finally { m.unmount() }
    })
  }
})

describe('i18n', () => {
  it('every key the toolbar renders exists in every locale', () => {
    const keys = [...read(FILE).matchAll(/\bt\('([a-z_.]+)'\)/g)].map((x) => x[1])
    assert.deepEqual([...new Set(keys)].sort(), ['auth.error.failed', 'dev_toolbar.aria', 'dev_toolbar.login', 'dev_toolbar.mailbox'])
    for (const code of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const cat = JSON.parse(read(`i18n/locales/${code}.json`))
      for (const k of keys) {
        const v = k.split('.').reduce((o, s) => o?.[s], cat)
        assert.equal(typeof v, 'string', `${code}: ${k}`)
        assert.ok(v.length > 0, `${code}: ${k}`)
      }
    }
  })
})
