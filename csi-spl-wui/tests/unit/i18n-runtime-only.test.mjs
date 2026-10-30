// CLE-35075 (P2, epic SPL-1093): vue-i18n ships runtime-only, without its
// message compiler. Every catalogue is a JSON file under i18n/locales that the
// build precompiles (unplugin-vue-i18n), so the browser never compiles a
// message; the compiler was ~5 KB gzip of first-paint JS for nothing
// (mock bundle 159.8 -> 154.9 KB on e1040f41).
//
// The one way to break this is a message that only exists at runtime: a
// setLocaleMessage / mergeLocaleMessage call or an inline `messages:` object.
// Runtime-only vue-i18n cannot compile those and would print the key instead
// of the text, so this test refuses them.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
// the second catalogue's two loaders: the browser's, and the server's for the
// prerendered documents (SPL-2417)
const MERGES_COMPILED = ['src/plugins/i18n-more.client.ts', 'src/plugins/i18n-more.server.ts']

function files(dir, out = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n)
    if (statSync(p).isDirectory()) files(p, out)
    else if (/\.(vue|ts|mjs|js)$/.test(n)) out.push(p)
  }
  return out
}

describe('vue-i18n runtime-only', () => {
  it('nuxt.config bundles vue-i18n without the message compiler', () => {
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    const bundle = /\bbundle:\s*\{([^}]*)\}/.exec(cfg)
    assert.ok(bundle, 'i18n.bundle block not found in nuxt.config.ts')
    assert.match(bundle[1], /\bruntimeOnly:\s*true\b/)
    assert.match(bundle[1], /\bdropMessageCompiler:\s*true\b/)
  })

  // SPL-4356: @nuxtjs/i18n 10 fetches /_i18n/<hash>/<locale>/messages.json
  // (raw source strings) when every locale file is static JSON; without a
  // compiler "#{name}" reached the screen. The app takes its precompiled
  // chunks instead, through this define, set after the module's own.
  it('nuxt.config keeps the client on its precompiled catalogues, not the messages.json route', () => {
    const cfg = readFileSync(join(WUI, 'nuxt.config.ts'), 'utf8')
    const mod = /function i18nClientMessagesModule\b[^{]*\{\n  nuxt\.hook\("modules:done", \(\) => \{\n    extendViteConfig\(\(config\) => \{\n      config\.define = \{ \.\.\.config\.define, __I18N_FULL_STATIC__: "false" \}/
    assert.match(cfg, mod)
    const modules = /\bmodules: \[([^\]]*)\]/.exec(cfg)
    assert.ok(modules, 'modules list not found in nuxt.config.ts')
    const list = modules[1].split(',').map((m) => m.trim())
    assert.ok(list.indexOf('i18nClientMessagesModule') > list.indexOf('"@nuxtjs/i18n"'), 'i18nClientMessagesModule must follow @nuxtjs/i18n')
  })

  it('no source adds a message at runtime (it would need the compiler)', () => {
    const bad = []
    for (const f of files(join(WUI, 'src'))) {
      const rel = f.slice(WUI.length + 1)
      if (MERGES_COMPILED.includes(rel)) continue
      const src = readFileSync(f, 'utf8')
      if (/\b(setLocaleMessage|mergeLocaleMessage)\s*\(/.test(src)) bad.push(rel)
    }
    assert.deepEqual(bad, [])
  })

  // Perf round 3, P3-06: the one merge, of the second catalogue, which the
  // build writes already compiled (src/node/i18n/split-catalogue.mjs).
  it('the catalogue-split loaders merge only the build-compiled second catalogues', () => {
    for (const f of MERGES_COMPILED) {
      const src = readFileSync(join(WUI, f), 'utf8')
      assert.match(src, /import\.meta\.glob<[^>]*>\('\.\.\/\.\.\/i18n\/\.split\/more\/\*\.mjs'\)/, f)
      assert.equal([...src.matchAll(/\bmergeLocaleMessage\s*\(/g)].length, 1, f)
      assert.match(src, /mergeLocaleMessage\(code, m\.default\)/, f)
    }
    const split = readFileSync(join(WUI, 'src/node/i18n/split-catalogue.mjs'), 'utf8')
    assert.match(split, /generateJSON\(/)
  })

  // SPL-4356: vue-i18n 11's resolver returns on a failed hasOwnProperty before
  // it reads the key, so a view that rendered a key holds no dependency on it
  // and a later merge does not render it again ("demo.intro.limit" stayed on
  // the sign-in page). The browser loader sets the locale root again after
  // its merge. The first case pins the cause, the second the fix.
  it('a key merged after a render reaches the view only through a new locale root', async () => {
    const { reactive, effect } = await import('vue')
    const { resolveValue } = await import('@intlify/core-base')
    const messages = reactive({ en: { demo: { intro: { title: 'Try the demo' } } } })
    const seen = []
    effect(() => { seen.push(resolveValue(messages.en, 'demo.intro.limit')) })
    Object.assign(messages.en.demo.intro, { limit: 'At most {n}' })
    assert.deepEqual(seen, [null], 'CONTROL: the merge alone re-ran the view; the re-set below is no longer needed')
    messages.en = { ...messages.en }
    assert.deepEqual(seen, [null, 'At most {n}'])
    const src = readFileSync(join(WUI, 'src/plugins/i18n-more.client.ts'), 'utf8')
    assert.match(src, /mergeLocaleMessage\(code, m\.default\)\n(?:\s*\/\/.*\n)*\s*i18n\.setLocaleMessage\(code, \{ \.\.\.i18n\.getLocaleMessage\(code\) \}\)/)
  })
})
