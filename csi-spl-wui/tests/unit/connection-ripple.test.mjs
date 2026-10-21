// Row 05 of ui-animations-panel-plan.md (SPL-2792, epic SPL-2403): the
// connection dot ripples once when the socket reconnects.
//
//   • ChannelSidebar.vue (desktop foot, data-testid=connection-health) and
//     MobileStatusStrip.vue (phone strip) bind v-reconnect-ripple="health"
//     on their dot
//   • the directive (composables/useConnectionRipple.ts), run with the real
//     useTapAnim.ts on a DOM-less Vue renderer: ok -> down -> ok adds
//     `tap-anim tap-anim--ripple` once, for 2 x 600 ms = 1.2 s, and
//     animationend takes them off
//   • a steady connection, a re-render, the first connect after a page load
//     and a warn <-> down flap stay static; 0 classes under reduced motion
//
// Run: node --test tests/unit/connection-ripple.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
const templateOf = (p) => { const s = read(p); return s.slice(0, s.indexOf('<script')) }

const RIPPLE = 'src/composables/useConnectionRipple.ts'
globalThis.__ripple = await import(dataUrl(tsToJs(read('src/composables/useTapAnim.ts'))))
const vReconnectRipple = existsSync(join(WUI, RIPPLE))
  ? (await import(dataUrl(tsToJs(read(RIPPLE)).replace(/^import \{ playTapAnim \}.*$/m, 'const { playTapAnim } = globalThis.__ripple')))).vReconnectRipple
  : null

/* ---------- a DOM-less renderer, with what playTapAnim touches ---------- */

function el(tag) {
  const classes = new Set()
  const listeners = {}
  const n = {
    tag, children: [], parent: null, text: '', classes, listeners, adds: [],
    classList: {
      add: (...c) => { n.adds.push(...c); c.forEach((x) => classes.add(x)) },
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
    },
    get offsetWidth() { return 10 },
    querySelector: () => null,
    addEventListener: (t, f) => { (listeners[t] ||= new Set()).add(f) },
    removeEventListener: (t, f) => { listeners[t]?.delete(f) },
    fire(type, animationName) {
      for (const f of listeners[type] || []) f({ type, animationName, target: n })
    },
  }
  return n
}
const { createRenderer, h, nextTick, ref, withDirectives } = Vue
const { render } = createRenderer({
  createElement: (tag) => el(tag),
  createText: (text) => Object.assign(el('#text'), { text }),
  createComment: (text) => Object.assign(el('#comment'), { text }),
  setText: (n, text) => { n.text = text },
  setElementText: (n, text) => { n.text = text },
  insert(child, parent) { parent.children.push(child); child.parent = parent },
  remove(child) { const p = child.parent; if (p) p.children.splice(p.children.indexOf(child), 1) },
  parentNode: (n) => n.parent,
  nextSibling: () => null,
  patchProp(n, key, _prev, next) {
    /* Vue sets the whole class string, as on the real span */
    if (key === 'class') { n.classes.clear(); String(next || '').split(' ').filter(Boolean).forEach((c) => n.classes.add(c)) }
  },
})

/** mount a dot bound to `health`, as the two components do */
function mountDot(first) {
  const health = ref(first)
  const tick = ref(0)
  const root = el('root')
  const App = { render: () => (tick.value, withDirectives(h('span', { class: 'health-dot ' + health.value }), [[vReconnectRipple, health.value]])) }
  render(h(App), root)
  const dot = root.children[0]
  return {
    dot,
    async go(...states) { for (const s of states) { health.value = s; await nextTick() } },
    async rerender() { tick.value++; await nextTick() },
    ripples: () => dot.adds.filter((c) => c === 'tap-anim--ripple').length,
  }
}

function withMotion(reduce, fn) {
  const was = globalThis.matchMedia
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  return Promise.resolve(fn()).finally(() => { globalThis.matchMedia = was })
}

describe('connection dot: radar ripple on socket reconnect', () => {
  it('both dots bind v-reconnect-ripple to their health', () => {
    assert.match(templateOf('src/components/ChannelSidebar.vue'),
      /data-testid="connection-health"[\s\S]{0,300}<span v-reconnect-ripple="health" class="health-dot" :class="health" \/>/)
    assert.match(templateOf('src/components/MobileStatusStrip.vue'),
      /<span v-reconnect-ripple="health" class="status-strip__dot" :class="health"/)
  })

  it('ok -> down -> ok ripples once, 2 x 600 ms = 1.2 s, then the class comes off', async () => {
    assert.ok(vReconnectRipple, RIPPLE + ' exports vReconnectRipple')
    await withMotion(false, async () => {
      const d = mountDot('ok')
      await d.go('down', 'warn')
      assert.equal(d.ripples(), 0, 'nothing while offline')
      await d.go('ok')
      assert.equal(d.ripples(), 1)
      assert.ok(d.dot.classes.has('tap-anim') && d.dot.classes.has('tap-anim--ripple'), 'active after the reconnect')
      assert.ok(d.dot.classes.has('ok'), 'the dot keeps its health class')
      await d.rerender()
      assert.equal(d.ripples(), 1, 'a re-render does not replay it')
      d.dot.fire('animationend', 'tap-ripple')
      assert.ok(!d.dot.classes.has('tap-anim') && !d.dot.classes.has('tap-anim--ripple'), 'removed on animationend')
      assert.ok(d.dot.classes.has('ok'))
      const rule = read('src/assets/css/tap-anim.css').match(/\.tap-anim--ripple \{([^}]*)\}/)[1]
      const ms = Number(rule.match(/animation-duration:\s*(\d+)ms/)[1]) * Number(rule.match(/animation-iteration-count:\s*(\d+)/)[1])
      assert.equal(ms, 1200, 'the ripple runs 1.2 s')
      await d.go('down', 'ok')
      assert.equal(d.ripples(), 2, 'one shot per reconnect')
    })
  })

  it('a steady connection, the first connect and an offline flap stay static', async () => {
    assert.ok(vReconnectRipple, RIPPLE + ' exports vReconnectRipple')
    await withMotion(false, async () => {
      const steady = mountDot('ok')
      await steady.rerender()
      await steady.rerender()
      assert.equal(steady.ripples(), 0, 'steady ok')
      assert.equal(steady.dot.adds.length, 0)
      const boot = mountDot('warn')
      await boot.go('ok')
      assert.equal(boot.ripples(), 0, 'first connect after a page load')
      await boot.go('down', 'warn', 'down')
      assert.equal(boot.ripples(), 0, 'warn <-> down')
      await boot.go('ok')
      assert.equal(boot.ripples(), 1, 'a reconnect after it was online')
    })
  })

  it('nothing moves under prefers-reduced-motion', async () => {
    assert.ok(vReconnectRipple, RIPPLE + ' exports vReconnectRipple')
    await withMotion(true, async () => {
      const d = mountDot('ok')
      await d.go('down', 'ok', 'warn', 'ok')
      assert.equal(d.dot.adds.length, 0)
    })
  })
})
