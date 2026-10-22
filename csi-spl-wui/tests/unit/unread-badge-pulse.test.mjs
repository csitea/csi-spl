// Row 04 of ui-animations-panel-plan.md (SPL-2736, epic SPL-2403): an unread
// badge in the sidebar swells once when its number goes up.
//
//   • ChannelSidebar.vue binds v-swell-up to the rail tab (its number or pip)
//     and to a DM row (its unread); the directive is cut out of the shipped
//     SFC HERE and run with the real useTapAnim.ts on a DOM-less Vue renderer
//   • a store unread count going up adds `tap-anim tap-anim--swell` to the
//     badge, once; animationend takes them off
//   • nothing on the first paint, on an identical re-render, or when the
//     count goes down; 0 classes under prefers-reduced-motion
//   • SPL-2815: nothing while the first counts load (countsLoaded false: the
//     0 -> N of the load is the first paint), and nothing on a badge that is
//     not rendered (checkVisibility false: no animationend would take it off)
//
// Run: node --test tests/unit/unread-badge-pulse.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const SFC = read('src/components/ChannelSidebar.vue')
const TEMPLATE = SFC.slice(0, SFC.indexOf('<script'))
const SCRIPT = SFC.slice(SFC.indexOf('<script'), SFC.indexOf('</script>'))
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText

const tap = await import(dataUrl(tsToJs(read('src/composables/useTapAnim.ts'))))

/** the shipped `const vSwellUp = { ... }`, cut out of the SFC script */
function shippedDirective() {
  const at = SCRIPT.indexOf('const vSwellUp')
  if (at < 0) return null
  const src = SCRIPT.slice(at, SCRIPT.indexOf('\n}\n', at) + 2)
  const js = tsToJs(src + '\nexport default vSwellUp\n')
  return import(dataUrl(`const playTapAnim = globalThis.__swell.play\nconst countsLoaded = globalThis.__swell.loaded\n${js}`)).then((m) => m.default)
}
/* countsLoaded (useSidebarCounts): the first counts are on screen */
globalThis.__swell = { play: (...a) => tap.playTapAnim(...a), loaded: Vue.ref(true) }
const vSwellUp = await shippedDirective()

/* ---------- a DOM-less renderer, with what playTapAnim touches ---------- */

function el(tag) {
  const classes = new Set()
  const listeners = {}
  const n = {
    tag, props: {}, children: [], parent: null, text: '', classes, listeners, adds: [],
    classList: {
      add: (...c) => { n.adds.push(...c); c.forEach((x) => classes.add(x)) },
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
    },
    get offsetWidth() { return 10 },
    /* a selector list of classes, as the directive asks */
    querySelector(sel) {
      const want = sel.split(',').map((s) => s.trim().replace(/^\./, ''))
      return findAll(n, (x) => x !== n && want.some((c) => String(x.props.class || '').split(' ').includes(c)))[0] || null
    },
    addEventListener: (t, f) => { (listeners[t] ||= new Set()).add(f) },
    removeEventListener: (t, f) => { listeners[t]?.delete(f) },
  }
  return n
}
const ops = {
  createElement: (tag) => el(tag),
  createText: (text) => Object.assign(el('#text'), { text }),
  createComment: (text) => Object.assign(el('#comment'), { text }),
  setText: (n, text) => { n.text = text },
  setElementText: (n, text) => { n.children = text ? [Object.assign(el('#text'), { text, parent: n })] : [] },
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

function findAll(n, pred, out = []) {
  if (pred(n)) out.push(n)
  for (const c of n.children || []) findAll(c, pred, out)
  return out
}
const flush = async () => { for (let i = 0; i < 3; i++) { await new Promise((r) => setTimeout(r, 0)); await Vue.nextTick() } }

/**
 * A sidebar row as the SFC draws it: the host (the rail tab / DM row) stays
 * mounted with v-swell-up on its count; the badge shows while the count is
 * not 0. `store` is the unread store's count for the row; `tick` forces a
 * re-render with nothing changed.
 */
async function mountRow(kind, n, reduce, { loaded = true } = {}) {
  assert.ok(vSwellUp, 'ChannelSidebar.vue declares vSwellUp')
  globalThis.__swell.loaded.value = loaded
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  const store = Vue.reactive({ n, tick: 0 })
  const badgeClass = { dm: 'badge-unread', rail: 'sidebar-tab__count', pip: 'sidebar-tab__pip' }[kind]
  const root = el('#root')
  const errors = []
  const app = createApp({
    render: () => Vue.withDirectives(
      Vue.h('div', { class: 'nav-row', 'data-tick': store.tick }, [
        Vue.h('a', { class: 'nav-item' }, [store.n ? Vue.h('span', { class: badgeClass }, String(store.n)) : null]),
      ]),
      [[vSwellUp, store.n]],
    ),
  })
  app.config.errorHandler = (e) => { errors.push(e) }
  app.mount(root)
  await flush()
  const badge = () => findAll(root, (x) => x.props.class === badgeClass)[0]
  const swells = () => (badge()?.adds || []).filter((c) => c === 'tap-anim--swell').length
  return { store, badge, swells, errors, app }
}

describe('ChannelSidebar binds the swell to its unread badges', () => {
  it('imports playTapAnim from useTapAnim, and nothing new beyond it', () => {
    assert.match(SCRIPT, /import\s*\{[^}]*\bplayTapAnim\b[^}]*\}\s*from\s*'~\/composables\/useTapAnim'/)
  })

  it("the rail tab carries v-swell-up on the number its badge shows", () => {
    const tab = TEMPLATE.match(/<button\s+v-for="item in rail"[^>]*role="tab"[^>]*>/)
    assert.ok(tab, 'the rail tab button')
    assert.match(tab[0], /v-swell-up="railBadgeN\(item\.id\)"/)
    assert.match(SCRIPT, /function railBadgeN\(id: string\)\s*\{\s*return parseInt\(id === 'flow' \? flowLabel\.value : railCount\(id\)\) \|\| \+tabUnread\(id\)/)
  })

  it("a DM row carries v-swell-up on the row's unread", () => {
    const row = TEMPLATE.match(/<div\s+v-for="\(p, peerIndex\) in peers"[^>]*>/)
    assert.ok(row, 'the DM row')
    assert.match(row[0], /v-swell-up="unreadOf\('dm:' \+ p\.label\)"/)
  })

  it('SPL-2815: plays nothing until countsLoaded (the first counts on screen)', () => {
    assert.match(SCRIPT, /countsLoaded\.value && value > \(oldValue \|\| 0\)/)
  })

  it("plays 'swell' on the badge it finds, never a loop", () => {
    assert.match(SCRIPT, /playTapAnim\(badge, 'swell'\)/)
    for (const c of ['badge-unread', 'sidebar-tab__count', 'sidebar-tab__pip']) assert.ok(SCRIPT.includes('.' + c), c)
  })
})

describe('an unread count update swells the badge once', () => {
  for (const kind of ['dm', 'rail', 'pip']) {
    it(`${kind}: 3 -> 4 adds tap-anim--swell once; animationend takes it off`, async () => {
      const r = await mountRow(kind, 3, false)
      assert.equal(r.swells(), 0, 'the first paint plays nothing')
      r.store.n = 4
      await flush()
      assert.deepEqual(r.errors, [])
      assert.equal(r.swells(), 1)
      assert.deepEqual([...r.badge().classes].sort(), ['tap-anim', 'tap-anim--swell'])
      for (const f of r.badge().listeners.animationend || []) f({ type: 'animationend', animationName: 'tap-swell', target: r.badge() })
      assert.equal(r.badge().classes.size, 0)
      r.app.unmount()
    })
  }

  it('0 -> 1: the badge that appears swells', async () => {
    const r = await mountRow('dm', 0, false)
    assert.equal(r.badge(), undefined)
    r.store.n = 1
    await flush()
    assert.equal(r.swells(), 1)
    r.app.unmount()
  })

  it('an identical re-render plays nothing', async () => {
    const r = await mountRow('dm', 2, false)
    r.store.n = 3
    await flush()
    assert.equal(r.swells(), 1)
    r.store.tick++
    await flush()
    r.store.n = 3
    r.store.tick++
    await flush()
    assert.equal(r.swells(), 1, 'one shot per increment, not per render')
    r.app.unmount()
  })

  it('a count going down plays nothing', async () => {
    const r = await mountRow('rail', 5, false)
    r.store.n = 2
    await flush()
    assert.equal(r.swells(), 0)
    r.app.unmount()
  })

  it('SPL-2815: the first counts loading (0 -> N before countsLoaded) play nothing; the next rise swells', async () => {
    for (const kind of ['dm', 'rail', 'pip']) {
      const r = await mountRow(kind, 0, false, { loaded: false })
      r.store.n = 3
      await flush()
      assert.equal(r.swells(), 0, `${kind}: the load is the first paint`)
      globalThis.__swell.loaded.value = true
      r.store.n = 4
      await flush()
      assert.equal(r.swells(), 1, `${kind}: a real increase after the load swells`)
      r.app.unmount()
    }
  })

  it('SPL-2815: a badge that is not rendered gets no class (nothing would take it off)', async () => {
    const r = await mountRow('dm', 1, false)
    /* a hidden sidebar (a phone's level 2): the badge is not rendered */
    r.badge().checkVisibility = () => false
    r.store.n = 2
    await flush()
    assert.equal(r.swells(), 0)
    assert.equal(r.badge().classes.size, 0)
    r.app.unmount()
  })

  it('reduced motion: 0 classes on an increment', async () => {
    const r = await mountRow('dm', 1, true)
    r.store.n = 7
    await flush()
    assert.equal(r.swells(), 0)
    assert.equal(r.badge().classes.size, 0)
    r.app.unmount()
  })
})

describe('0 px layout shift', () => {
  const CSS = read('src/assets/css/tap-anim.css')
  it('tap-swell animates transform only', () => {
    const kf = CSS.match(/@keyframes tap-swell\s*\{((?:[^{}]*\{[^}]*\})*)\s*\}/)
    assert.ok(kf, '@keyframes tap-swell')
    const props = new Set([...kf[1].matchAll(/([a-z-]+)\s*:/g)].map((m) => m[1]))
    assert.deepEqual([...props], ['transform'])
  })

  it('the badges set no transform of their own for the swell to override', () => {
    for (const c of ['sidebar-tab__count', 'sidebar-tab__pip']) {
      const rule = SFC.match(new RegExp(`\\n\\.${c}\\s*\\{([^}]*)\\}`))
      assert.ok(rule, c)
      assert.doesNotMatch(rule[1], /transform\s*:/)
    }
  })
})
