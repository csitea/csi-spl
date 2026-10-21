// Row 02 of ui-animations-panel-plan.md (SPL-2479 panel, section 6.1): a
// copy button's tick draws itself once. IssueDetailActions.vue (the open
// issue's Copy link) and MobileStatusStrip.vue (the version card's commit
// copy) are compiled HERE from the shipped SFCs and mounted on a small
// in-memory renderer, with the real useTapAnim.ts, so what ships is tested.
//
//   • a copy puts `tap-anim tap-anim--draw` on the check icon, once
//   • animationend takes both classes off
//   • the icon goes back to the copy glyph after the existing timeout,
//     with no tap-anim class left on it
//   • under prefers-reduced-motion no class is added at all
//
// Run: node --test tests/unit/copy-feedback.test.mjs
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

/* ---------- the shipped modules, compiled ---------- */

const TAP_URL = dataUrl(tsToJs(read('src/composables/useTapAnim.ts')))
/* the real useCopyText (its 1.8 s reset), the clipboard write stubbed */
const CLIP_URL = dataUrl('export async function writeClipboard(t) { globalThis.__cf.clip.push(t) }')
const COPY_URL = dataUrl(vueUrl(tsToJs(read('src/composables/useCopyText.ts'))).split("'~/utils/clipboard.mjs'").join(`'${CLIP_URL}'`))

/* Nuxt auto-imports: Vue's API, useI18n, useRuntimeConfig */
const PRELUDE = `import { ref, computed, watch, watchEffect, nextTick, onMounted, onBeforeUnmount } from '${VUE_URL}';\n`
  + 'const useI18n = () => ({ t: (k) => k });\n'
  + 'const useRuntimeConfig = () => ({ public: { appVersion: "v1.2.3" } });\n'
const stub = (body) => dataUrl(body)
const COMP = stub(`import { h } from '${VUE_URL}'; export default { render: () => h('span') }`)
const STRIP_IMPORTS = {
  '@/components/NotificationCenter.vue': COMP,
  '@/components/ConnectionStatus.vue': COMP,
  '@/components/LastDataClock.vue': COMP,
  '@/components/PoweredBy.vue': COMP,
  '~/composables/useLive': stub(`import { ref } from '${VUE_URL}'; export const useLive = () => ({ state: ref('open') })`),
  '~/composables/useCopyText': COPY_URL,
  /* row 05's reconnect ripple: not under test here */
  '~/composables/useConnectionRipple': stub('export const vReconnectRipple = {}'),
  '~/composables/useTouchUi': stub(`import { ref } from '${VUE_URL}'; export const useKeyboardInset = () => ref(0)`),
  '~/composables/useMobileStack': stub(`import { ref } from '${VUE_URL}'; export const useMobileStack = () => ({ sheetOpen: ref(false), overlay() {} })`),
  '~/composables/useStatusStrip': stub('export function setStatusStripHeight() {}'),
  '~/composables/useClockHost': stub(`import { ref } from '${VUE_URL}'; export const useClockHost = () => ({ strip: ref(false) })`),
  '~/composables/useBuildWatch': stub(`import { ref } from '${VUE_URL}'; export const useBuildWatch = () => ref({ running: 'abc1234def', live: '' }); export function reloadForBuild() {}`),
  '~/utils/channel-feed.mjs': stub('export const connectionHealth = () => "ok"'),
  '~/utils/build-stamp.mjs': stub('export const buildStampText = () => "v"; export const readBuildStamp = async () => null; export const shortCommit = (c) => c'),
  '~/utils/display-version.mjs': stub('export const displayVersion = (v) => v'),
  '~/utils/build-watch.mjs': stub('export const isNewer = () => false'),
}

function compileSfc(file, imports) {
  const { descriptor, errors } = parse(read(file), { filename: file })
  assert.deepEqual(errors, [], `${file} parses`)
  const script = compileScript(descriptor, { id: file, inlineTemplate: true, isProd: true })
  let js = vueUrl(tsToJs(script.content))
  for (const [spec, url] of Object.entries(imports)) js = js.split(`'${spec}'`).join(`'${url}'`)
  return import(dataUrl(PRELUDE + js))
}

const TAP_IMPORT = { '~/composables/useTapAnim': TAP_URL }
const actions = await compileSfc('src/components/IssueDetailActions.vue', TAP_IMPORT)
const strip = await compileSfc('src/components/MobileStatusStrip.vue', { ...STRIP_IMPORTS, ...TAP_IMPORT })

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
    get offsetWidth() { return 10 },
    getBoundingClientRect: () => ({ height: 22 }),
    contains: () => false,
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
const byTest = (root, name) => findAll(root, (n) => n.props?.['data-test'] === name)
const flush = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setTimeout(r, 0)); await Vue.nextTick() } }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* the icon: an svg with the glyph name, as UiIcon draws it */
const UiIcon = { props: ['name', 'size'], render() { return Vue.h('svg', { 'data-icon': this.name }) } }

function setupGlobals(reduce) {
  globalThis.__cf = { clip: [] }
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  globalThis.document = { addEventListener() {}, removeEventListener() {} }
}

async function mount(mod, props) {
  const root = el('#root')
  const errors = []
  const state = Vue.reactive({ ...props })
  const app = createApp({ render: () => Vue.h(mod.default, state) })
  app.component('UiIcon', UiIcon)
  app.component('LazyReleaseNotesDialog', { render: () => null })
  app.config.errorHandler = (e) => { errors.push(e) }
  app.config.warnHandler = () => {}
  app.mount(root)
  await flush()
  return { root, errors, state, app }
}

/** fire the keyframes' end on the svg; it bubbles to the button's listener */
function animationEnd(svg) {
  for (const n of [svg, svg.parent]) {
    for (const f of n.listeners.animationend || []) f({ type: 'animationend', animationName: 'tap-draw', target: svg })
  }
}

const svgOf = (btn) => findAll(btn, (n) => n.tag === 'svg')[0]

describe('IssueDetailActions: copy link draws its tick', () => {
  async function copyOnce(reduce) {
    setupGlobals(reduce)
    const m = await mount(actions, { copied: false })
    const btn = byTest(m.root, 'issues-detail-copy')[0]
    btn.props.onClick()
    m.state.copied = true /* the page copied the link */
    await flush()
    return { ...m, btn, svg: svgOf(btn) }
  }

  it('a copy adds tap-anim--draw to the check, animationend removes it', async () => {
    const { btn, svg, errors, state, app } = await copyOnce(false)
    assert.deepEqual(errors, [])
    assert.equal(svg.props['data-icon'], 'check')
    assert.deepEqual([...svg.classes].sort(), ['tap-anim', 'tap-anim--draw'])
    animationEnd(svg)
    assert.equal(svg.classes.size, 0)
    state.copied = false /* the page's timeout ran out */
    await flush()
    assert.equal(svgOf(btn).props['data-icon'], 'copy')
    assert.equal(svgOf(btn).classes.size, 0, 'no class is left on the copy glyph')
    app.unmount()
  })

  it('the other buttons do not animate, and a re-render while copied plays nothing again', async () => {
    const { root, svg, state, app } = await copyOnce(false)
    animationEnd(svg)
    state.tap = true
    await flush()
    assert.equal(svg.classes.size, 0, 'one shot per copy, not per render')
    for (const id of ['archive', 'delete']) assert.equal(svgOf(byTest(root, 'issues-detail-' + id)[0]).classes.size, 0)
    app.unmount()
  })

  it('reduced motion: 0 classes', async () => {
    const { svg, app } = await copyOnce(true)
    assert.equal(svg.props['data-icon'], 'check')
    assert.equal(svg.classes.size, 0)
    app.unmount()
  })
})

describe('MobileStatusStrip: the commit copy draws its tick', () => {
  async function copyOnce(reduce) {
    setupGlobals(reduce)
    const m = await mount(strip, {})
    byTest(m.root, 'status-strip-version')[0].props.onClick()
    await flush()
    const btn = byTest(m.root, 'status-strip-version-copy')[0]
    assert.ok(btn, 'the version card shows the copy button')
    btn.props.onClick()
    await flush()
    return { ...m, btn, svg: svgOf(btn) }
  }

  it('a copy adds tap-anim--draw to the check, animationend removes it, the icon reverts after 1.8 s', async () => {
    const { btn, svg, errors, app } = await copyOnce(false)
    assert.deepEqual(errors, [])
    assert.deepEqual(globalThis.__cf.clip, ['abc1234def'])
    assert.equal(svg.props['data-icon'], 'check')
    assert.deepEqual([...svg.classes].sort(), ['tap-anim', 'tap-anim--draw'])
    animationEnd(svg)
    assert.equal(svg.classes.size, 0)
    await sleep(1900)
    await flush()
    assert.equal(svgOf(btn).props['data-icon'], 'copy')
    assert.equal(svgOf(btn).classes.size, 0, 'no class is left on the copy glyph')
    app.unmount()
  })

  it('reduced motion: 0 classes', async () => {
    const { svg, app } = await copyOnce(true)
    assert.equal(svg.props['data-icon'], 'check')
    assert.equal(svg.classes.size, 0)
    app.unmount()
  })
})
