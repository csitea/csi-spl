// Row 06 of ui-animations-panel-plan.md (SPL-2479 panel, section 6.1;
// SPL-2793): the empty feed's robot mascot waves once on mount, then rests.
// FeedEmpty.vue is compiled HERE from the shipped SFC and mounted on a small
// in-memory renderer, with the real useTapAnim.ts, so what ships is tested.
//
//   • mounting puts `tap-anim tap-anim--greeting` on the mascot svg, once
//   • animationend takes both classes off, and a re-render plays nothing again
//   • no loop: the greeting keyframes run once, at most 1 s, never infinite
//   • under prefers-reduced-motion no class is added at all
//   • the mascot is inline SVG (no image file), aria-hidden, no :style, no v-html
//
// Run: node --test tests/unit/feed-empty-mascot.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import { parse, compileScript } from 'vue/compiler-sfc'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const VUE_URL = import.meta.resolve('vue')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false } }).outputText
const vueUrl = (js) => js.replace(/from ['"]vue['"]/g, `from '${VUE_URL}'`)

const FILE = 'src/components/FeedEmpty.vue'
const SFC = read(FILE)
const TAP_URL = dataUrl(tsToJs(read('src/composables/useTapAnim.ts')))

/* Nuxt auto-imports: Vue's API and useI18n (the friendly copy merged) */
const PRELUDE = `import { ref, computed, watch, nextTick, onMounted, onBeforeUnmount } from '${VUE_URL}';\n`
  + 'const useI18n = () => ({ t: (k) => k, te: () => true });\n'

function compileSfc() {
  const { descriptor, errors } = parse(SFC, { filename: FILE })
  assert.deepEqual(errors, [], `${FILE} parses`)
  const script = compileScript(descriptor, { id: FILE, inlineTemplate: true, isProd: true })
  const js = vueUrl(tsToJs(script.content)).split("'~/composables/useTapAnim'").join(`'${TAP_URL}'`)
  return import(dataUrl(PRELUDE + js))
}
const feedEmpty = await compileSfc()

/* ---------- a DOM-less renderer, with what playTapAnim touches ---------- */

function el(tag) {
  const classes = new Set()
  const listeners = {}
  const n = {
    tag, props: {}, children: [], parent: null, text: '', classes, listeners,
    classList: {
      add: (...c) => c.forEach((x) => classes.add(x)),
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
    },
    get offsetWidth() { return 48 },
    querySelector: (sel) => findAll(n, (x) => x !== n && x.tag === sel)[0] || null,
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
const byTest = (root, name) => findAll(root, (n) => n.props?.['data-testid'] === name)
const flush = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setTimeout(r, 0)); await Vue.nextTick() } }

const UiIcon = { props: ['name', 'size'], render() { return Vue.h('i', { 'data-icon': this.name }) } }

async function mount(reduce, props = { channel: 'general' }) {
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  globalThis.document = { querySelector: () => null }
  const root = el('#root')
  const errors = []
  const state = Vue.reactive({ ...props })
  const app = createApp({ render: () => Vue.h(feedEmpty.default, state) })
  app.component('UiIcon', UiIcon)
  app.config.errorHandler = (e) => { errors.push(e) }
  app.config.warnHandler = () => {}
  app.mount(root)
  await flush()
  const mascot = byTest(root, 'feed-empty-mascot')[0]
  return { root, errors, state, app, mascot, svg: mascot && findAll(mascot, (n) => n.tag === 'svg')[0] }
}

/** the keyframes' end on the svg; it bubbles to the mascot's listener */
function animationEnd(svg) {
  for (const n of [svg, svg.parent]) {
    for (const f of n.listeners.animationend || []) f({ type: 'animationend', animationName: 'tap-greeting', target: svg })
  }
}

describe('FeedEmpty: the mascot greets once on mount', () => {
  it('mount adds tap-anim--greeting to the mascot svg, animationend removes it', async () => {
    const { errors, mascot, svg, app } = await mount(false)
    assert.deepEqual(errors, [])
    assert.ok(mascot, 'the empty feed shows the mascot')
    assert.ok(svg, 'the mascot is an inline svg')
    assert.deepEqual([...svg.classes].sort(), ['tap-anim', 'tap-anim--greeting'])
    animationEnd(svg)
    assert.equal(svg.classes.size, 0, 'it rests after the wave')
    app.unmount()
  })

  it('one shot: a re-render (filter typed, cleared) plays nothing again', async () => {
    const { state, svg, app } = await mount(false)
    animationEnd(svg)
    state.search = 'zzz'
    await flush()
    state.search = ''
    await flush()
    assert.equal(svg.classes.size, 0, 'one greeting per mount, not per render')
    app.unmount()
  })

  it('a filter with no match greets too, and it is the only animated node', async () => {
    const { root, svg, app } = await mount(false, { channel: 'general', search: 'x' })
    assert.deepEqual([...svg.classes].sort(), ['tap-anim', 'tap-anim--greeting'])
    const animated = findAll(root, (n) => n.classes?.has('tap-anim'))
    assert.deepEqual(animated, [svg])
    app.unmount()
  })

  it('reduced motion: 0 classes, nothing moves', async () => {
    const { root, svg, app } = await mount(true)
    assert.ok(svg)
    assert.equal(svg.classes.size, 0)
    assert.equal(findAll(root, (n) => n.classes?.has('tap-anim')).length, 0)
    app.unmount()
  })
})

describe('FeedEmpty: no loop, no layout shift, CSP and distribution rules', () => {
  const css = read('src/assets/css/tap-anim.css')
  const greeting = css.match(/\.tap-anim--greeting\s*\{([^}]*)\}/)

  it('the greeting runs once, in at most 1 s', () => {
    assert.ok(greeting, 'tap-anim.css has .tap-anim--greeting')
    const ms = Number(greeting[1].match(/animation-duration:\s*(\d+)ms/)?.[1])
    assert.ok(ms > 0 && ms <= 1000, `duration ${ms} ms <= 1000`)
    assert.doesNotMatch(greeting[1], /iteration-count|infinite/)
    assert.match(css, /\.tap-anim\s*\{[^}]*animation-iteration-count:\s*1;/)
  })

  it('the component adds no animation of its own and keeps a fixed mascot box', () => {
    const style = SFC.slice(SFC.indexOf('<style'))
    assert.doesNotMatch(style, /animation|@keyframes|infinite|transition/)
    assert.match(style, /\.feed-empty__mascot\s*\{[^}]*width:\s*48px;[^}]*height:\s*48px;/)
  })

  it('inline svg, aria-hidden, no image file, no :style, no v-html', () => {
    const tpl = SFC.slice(SFC.indexOf('<template>'), SFC.lastIndexOf('</template>'))
    assert.match(tpl, /<span ref="mascot" class="feed-empty__mascot"[^>]*aria-hidden="true"/)
    assert.doesNotMatch(tpl, /<img|\.png|\.svg['"]|:style|v-html/)
  })
})
