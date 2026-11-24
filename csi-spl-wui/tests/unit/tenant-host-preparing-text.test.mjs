// SPL-6439 (spec 158; owner HUM-10, t1 4a5911f1, msgs e5e72a53 and
// 4e3bb286): the screen a new workspace's owner sees while its address is not
// up yet says that creation takes time, the time to expect, and what to do
// when it does not come up.
//
//   • TenantNotMember.vue, compiled HERE from the shipped SFC and rendered
//     with the real en.json, shows tenant_host.preparing AND
//     tenant_host.not_ready_help for a pending host, and neither for a plain
//     "not a member"
//   • every locale carries both keys with {host}, the 15 and 60 minute
//     bounds, and no payment wording (a demo workspace gets the screen too)
//   • every locale carries operator.created_host_wait (the operator's create
//     notice) with the 15 and 60 minute bounds
//
// The 15..60 minutes: workflow 40's measured runs, see the commit body.
//
// Run: node --test tests/unit/tenant-host-preparing-text.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parse, compileScript } from 'vue/compiler-sfc'
import ts from 'typescript'
import { createSSRApp, ref } from 'vue'
import { renderToString } from 'vue/server-renderer'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const LOCALES = join(WUI, 'i18n/locales')
const locale = (f) => JSON.parse(readFileSync(join(LOCALES, f), 'utf8'))
const EN = locale('en.json')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText

/* the real catalogue: t('a.b', { host }) reads en.json and fills the slots */
const get = (o, k) => k.split('.').reduce((v, p) => (v == null ? v : v[p]), o)
const t = (k, p = {}) => String(get(EN, k) ?? k).replace(/\{(\w+)\}/g, (_, n) => (n in p ? String(p[n]) : `{${n}}`))
globalThis.__tnmState = ref({ tenant: '', home: '', pending: '' })
globalThis.__tnmT = t
/* Nuxt auto-imports, played by the test */
const PRELUDE = 'const useState = () => globalThis.__tnmState;\n'
  + 'const useI18n = () => ({ t: globalThis.__tnmT });\n'

const FILE = 'src/components/TenantNotMember.vue'
async function compile() {
  const { descriptor, errors } = parse(read(FILE), { filename: FILE })
  assert.deepEqual(errors, [], `${FILE} parses`)
  const script = compileScript(descriptor, { id: FILE, inlineTemplate: true, isProd: true, templateOptions: { ssr: true } })
  const js = tsToJs(script.content)
    .replace(/from ['"]vue['"]/g, `from '${import.meta.resolve('vue')}'`)
    .replace(/from ['"]vue\/server-renderer['"]/g, `from '${import.meta.resolve('vue/server-renderer')}'`)
  return (await import(dataUrl(PRELUDE + js))).default
}
const Comp = await compile()
const render = async (state) => {
  globalThis.__tnmState.value = state
  return renderToString(createSSRApp(Comp))
}
const text = (html) => html.replace(/<[^>]+>/g, ' ').replace(/&#39;/g, "'").replace(/\s+/g, ' ')

const PAY_STEMS = /payment|paid|плащан|πληρωμ|pago|maks[eu]|תשלום|apmokėj|maksāj|плаќањ|betal|płatn|plat[aă]|оплат|platb|plaćan|ödem/i
const bounds = (v) => typeof v === 'string' && v.includes('15') && v.includes('60')

describe('TenantNotMember: the preparing screen (SPL-6439)', () => {
  it('a pending host: how long it takes, and what to do past 60 minutes', async () => {
    const host = 'newco.app.example'
    const html = await render({ tenant: 'newco', home: '', pending: host })
    const shown = text(html)
    assert.match(html, /data-test="tenant-host-preparing"/)
    assert.match(html, /data-test="tenant-host-not-ready-help"/)
    assert.ok(shown.includes(t('tenant_host.preparing', { host })), shown)
    assert.ok(shown.includes(t('tenant_host.not_ready_help', { host })), shown)
    assert.match(shown, /takes time/)
    assert.match(shown, /15 to 60 minutes/)
    assert.match(shown, /after 60 minutes/)
    assert.doesNotMatch(html, /tenant-not-member-home/)
  })
  it('not a member (no pending host): neither line', async () => {
    const html = await render({ tenant: 'acme', home: 'https://t1.app.example/', pending: '' })
    assert.doesNotMatch(html, /tenant-host-preparing|tenant-host-not-ready-help/)
    assert.ok(text(html).includes(t('tenant_host.not_member', { tenant: 'acme' })))
    assert.match(html, /tenant-not-member-home/)
  })
})

describe('the wait texts in every locale (SPL-6439)', () => {
  const files = readdirSync(LOCALES).filter((f) => f.endsWith('.json'))
  it('19 locales: preparing + not_ready_help carry {host}, 15..60 minutes, no payment wording', () => {
    assert.equal(files.length, 19)
    for (const f of files) {
      const h = locale(f).tenant_host || {}
      for (const k of ['preparing', 'not_ready_help']) {
        const v = h[k]
        assert.ok(typeof v === 'string' && v.includes('{host}') && !PAY_STEMS.test(v), `${f} tenant_host.${k}: ${v}`)
      }
      assert.ok(bounds(h.preparing), `${f} tenant_host.preparing: ${h.preparing}`)
      assert.ok(String(h.not_ready_help).includes('60'), `${f} tenant_host.not_ready_help: ${h.not_ready_help}`)
    }
  })
  it('19 locales: operator.created_host_wait carries 15..60 minutes', () => {
    for (const f of files) {
      const v = (locale(f).operator || {}).created_host_wait
      assert.ok(bounds(v), `${f} operator.created_host_wait: ${v}`)
    }
  })
  it('CONTROL: the old text (about 30 minutes, no step) fails the guards', () => {
    assert.equal(bounds("The address {host} is not ready yet. A new workspace's address usually works within about 30 minutes of its creation."), false)
    assert.equal(bounds(undefined), false, 'a missing key fails')
  })
})
