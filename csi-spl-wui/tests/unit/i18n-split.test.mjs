// Perf round 3, P3-06: the build splits each locale catalogue into the
// messages the first screen can show (core) and the rest, which
// src/plugins/i18n-more.client.ts loads before any other page or ?settings=
// and when the browser is idle (src/node/i18n/split-catalogue.mjs).
// tests/e2e/i18n-split.test.mjs proves it in Chrome; this proves the parts:
// nothing is lost or doubled, the first-screen graph reaches what it must and
// stops at other pages, key literals keep their subtree, a template cut and
// a suffixed sibling, and the loader's gates match the split's.
import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SRC, LOCALES_DIR, compiledModule, firstScreenFiles, keysNamedBy, leafKeys, splitCatalogue,
} from '../../src/node/i18n/split-catalogue.mjs'
import { FIRST_SCREEN_PAGES, ON_DEMAND_COMPONENTS, isFirstScreenRoute } from '../../src/utils/i18n-first-screen.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const files = firstScreenFiles()
const reached = new Set([...files].map((f) => relative(SRC, f)))
const en = JSON.parse(readFileSync(join(LOCALES_DIR, 'en.json'), 'utf8'))
const keep = keysNamedBy(files, en)

describe('first-screen graph', () => {
  it('starts at every first-screen page, which exists', () => {
    for (const p of Object.values(FIRST_SCREEN_PAGES)) assert.ok(reached.has(p), p)
  })
  it('reaches the layout, rail, feed and composer, and lazy first-screen parts', () => {
    for (const p of ['app.vue', 'layouts/default.vue', 'components/ChannelSidebar.vue', 'components/MessageCard.vue',
      'components/MessageComposer.vue', 'components/SearchSidePanel.vue', 'components/common/DebugPanel.vue']) {
      assert.ok(reached.has(p), p)
    }
  })
  it('never walks into another page or an on-demand component', () => {
    for (const p of ['pages/issues.vue', 'pages/help/[[page]].vue', 'pages/tenant-settings.vue', ...Object.keys(ON_DEMAND_COMPONENTS)]) {
      assert.ok(!reached.has(p), p)
    }
  })
})

describe('key literals', () => {
  const cat = { a: { b: { c: 'x', d: 'y' }, b_enter: 'z', e: 'w' }, f: { g: 'v' } }
  const tmp = mkdtempSync(join(tmpdir(), 'i18n-split-'))
  const at = (name, src) => { const p = join(tmp, name); writeFileSync(p, src); return p }
  it('keep a subtree, a template cut at ${ and a suffixed sibling', () => {
    assert.deepEqual([...keysNamedBy([at('1.vue', "t('a.b')")], cat)].sort(), ['a.b.c', 'a.b.d', 'a.b_enter'])
    assert.deepEqual([...keysNamedBy([at('2.ts', 't(`f.${x}`)')], cat)], ['f.g'])
    assert.deepEqual([...keysNamedBy([at('3.ts', "const k = 'a.e'")], cat)], ['a.e'])
  })
  it('ignore a bare word that only looks like a namespace', () => {
    assert.deepEqual([...keysNamedBy([at('4.ts', "mode = 'a'")], cat)], [])
  })
  after(() => rmSync(tmp, { recursive: true, force: true }))
})

describe('split', () => {
  it('keeps the first screen catalogue well under the whole one', () => {
    const n = leafKeys(en).length
    assert.ok(keep.size > 300 && keep.size < n * 0.75, `${keep.size} of ${n}`)
  })
  it('partitions every locale: each key once, in core or in the rest', () => {
    for (const f of readdirSync(LOCALES_DIR).filter((n) => n.endsWith('.json'))) {
      const cat = JSON.parse(readFileSync(join(LOCALES_DIR, f), 'utf8'))
      const { core, more } = splitCatalogue(cat, keep)
      const c = leafKeys(core), m = leafKeys(more)
      assert.equal(c.length + m.length, leafKeys(cat).length, f)
      assert.deepEqual([...c, ...m].sort(), leafKeys(cat).sort(), f)
      assert.ok(c.every((k) => keep.has(k)) && m.every((k) => !keep.has(k)), f)
    }
  })
  it('writes the rest as compiled messages (runtime-only vue-i18n has no compiler)', () => {
    const code = compiledModule({ x: { y: 'Hello', z: 'Hi {name}' } }, 'x.mjs')
    assert.match(code, /"z": \{"t":0,"b":\{"t":2/)
    assert.match(code, /"k":"name"/)
    assert.match(code, /"y": "Hello"/) // P3-20: a static message stays its plain string
    assert.match(code, /export default resource/)
  })
})

describe('loader gates', () => {
  it('names first-screen routes by their Nuxt name, any locale', () => {
    assert.ok(isFirstScreenRoute({ name: 'index___bg' }))
    assert.ok(isFirstScreenRoute({ name: 't-task_id___en' }))
    assert.ok(!isFirstScreenRoute({ name: 'issues___en' }))
    assert.ok(!isFirstScreenRoute({ name: undefined }))
  })
  it('the Settings modal is mounted only on ?settings=, which the loader awaits', () => {
    assert.deepEqual(Object.keys(ON_DEMAND_COMPONENTS), ['components/SettingsDialog.vue', 'components/StatusPicker.vue', 'components/ComposerStatusLine.vue'])
    /* the one place that renders it: a second mount without the gate would leave it keyless */
    const tags = (dir, out = []) => {
      for (const n of readdirSync(dir, { withFileTypes: true })) {
        const p = join(dir, n.name)
        if (n.isDirectory()) { if (n.name !== 'node') tags(p, out) } else if (/\.(vue|ts)$/.test(n.name) && /<(?:Lazy)?SettingsDialog\b|import\(.*SettingsDialog\.vue/.test(readFileSync(p, 'utf8'))) out.push(relative(SRC, p))
      }
      return out
    }
    assert.deepEqual(tags(SRC), ['app.vue'])
    assert.match(read('src/app.vue'), /<LazySettingsDialog v-if="settingsMounted"/)
    assert.match(read('src/app.vue'), /settingsQuerySection\(route\.query/)
    const plugin = read('src/plugins/i18n-more.client.ts')
    assert.match(plugin, /settingsQuerySection\(to\.query\) !== null/)
    assert.match(plugin, /isFirstScreenRoute\(to\)/)
    assert.match(plugin, /beforeResolve/)
  })
  it('the build points the i18n module at the core catalogues', () => {
    const cfg = read('nuxt.config.ts')
    assert.match(cfg, /writeSplitCatalogues\(I18N_LOCALES\.map/)
    assert.match(cfg, /locales: I18N_MODULE_LOCALES,/)
    assert.match(cfg, /file: `\.\.\/\.split\/\$\{l\.file\}`/)
  })
})
