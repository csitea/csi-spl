// Row 03 of ui-animations-panel-plan.md (SPL-2714, epic SPL-2403): a tapped
// reaction chip pops once, on the desktop and the phone feed.
//
//   • a desktop chip's click calls playTapAnim(<the chip>, 'pop') before the
//     toggle; a pick from the emoji sheet (the phone's way to react, and the
//     desktop smile's) pops that emoji's chip once the toggle is back
//   • the chips carry no v-tap-anim, so no second kind is stacked on them
//   • on a chip (no svg inside) the pop class goes on the chip itself and
//     comes off on animationend; 0 classes under prefers-reduced-motion
//   • 0 px layout shift: tap-pop moves only transform, .tap-anim sets no box
//     property, and the chip is an inline-flex box (a transform applies and
//     never moves its neighbours)
//
// Run: node --test tests/unit/reaction-anim.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const CARD = readFileSync(join(WUI, 'src/components/MessageCard.vue'), 'utf8')
const CSS = readFileSync(join(WUI, 'src/assets/css/tap-anim.css'), 'utf8')
const TEMPLATE = CARD.slice(0, CARD.indexOf('<script'))
const SCRIPT = CARD.slice(CARD.indexOf('<script'), CARD.indexOf('</script>'))

/** useTapAnim.ts transpiled to a temp .mjs, then imported */
async function load() {
  const tmp = mkdtempSync(join(tmpdir(), 'reaction-anim-'))
  try {
    const src = readFileSync(join(WUI, 'src/composables/useTapAnim.ts'), 'utf8')
    const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    writeFileSync(join(tmp, 'useTapAnim.mjs'), js)
    return await import(pathToFileURL(join(tmp, 'useTapAnim.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

/** a reaction chip: classList and listeners, no svg inside */
function fakeChip() {
  const classes = new Set()
  const listeners = {}
  const el = {
    classes,
    classList: {
      add: (...c) => c.forEach((x) => classes.add(x)),
      remove: (...c) => c.forEach((x) => classes.delete(x)),
      contains: (c) => classes.has(c),
    },
    get offsetWidth() { return 10 },
    querySelector: () => null,
    addEventListener: (t, f) => { (listeners[t] ||= new Set()).add(f) },
    removeEventListener: (t, f) => { listeners[t]?.delete(f) },
    fire(type, animationName) {
      for (const f of listeners[type] || []) f({ type, animationName, target: el })
    },
  }
  return el
}

function withMotion(reduce, fn) {
  const prev = globalThis.matchMedia
  globalThis.matchMedia = (q) => ({ matches: reduce && q.includes('reduce') })
  try { return fn() } finally { globalThis.matchMedia = prev }
}

/** the text of `function <name>(...) { ... }` in the card's script */
function fnBody(name) {
  const at = SCRIPT.search(new RegExp(`function ${name}\\s*\\(`))
  assert.ok(at >= 0, `function ${name} in MessageCard.vue`)
  return SCRIPT.slice(at, SCRIPT.indexOf('\n}', at))
}

/** the handler a template event names: "popChip($event, chip.emoji)" -> popChip */
function handlerOf(attr) {
  const m = attr.match(/^([A-Za-z_$][\w$]*)/)
  return m ? m[1] : ''
}

const mod = await load()

describe('MessageCard reaction chips pop', () => {
  it('imports playTapAnim from useTapAnim', () => {
    assert.match(SCRIPT, /import\s*\{[^}]*\bplayTapAnim\b[^}]*\}\s*from\s*'~\/composables\/useTapAnim'/)
  })

  it("a desktop chip's click plays 'pop' on the chip, then toggles", () => {
    const chip = TEMPLATE.match(/<button\s[^>]*class="msg-reaction"[^>]*>/)
    assert.ok(chip, 'the desktop chip button')
    const click = chip[0].match(/@click(?:\.stop)?="([^"]+)"/)
    assert.ok(click, 'its click handler')
    const body = fnBody(handlerOf(click[1]))
    assert.match(body, /playTapAnim\([^)]*,\s*'pop'\)/)
    assert.match(body, /onReact\(/)
    assert.ok(body.indexOf('playTapAnim') < body.indexOf('onReact('), 'pop first: the tap answers at once')
  })

  it("a pick from the emoji sheet pops that emoji's chip (the phone way)", () => {
    const choose = TEMPLATE.match(/<LazyEmojiPicker[^>]*@choose="([^"]+)"/)
    assert.ok(choose, 'the picker choose handler')
    const body = fnBody(handlerOf(choose[1]))
    assert.match(body, /await onReact\(/)
    assert.match(body, /dataset\.emoji|data-emoji/)
    assert.match(body, /playTapAnim\([^)]*,\s*'pop'\)/)
  })

  it('stacks no v-tap-anim on a chip', () => {
    for (const m of TEMPLATE.matchAll(/<(?:button|span)\s[^>]*class="msg-reaction"[^>]*>/g)) {
      assert.doesNotMatch(m[0], /v-tap-anim/)
    }
  })
})

describe('playTapAnim on a chip', () => {
  it('adds tap-anim tap-anim--pop on the chip and removes them on animationend', () => withMotion(false, () => {
    const el = fakeChip()
    mod.playTapAnim(el, 'pop')
    assert.deepEqual([...el.classes].sort(), ['tap-anim', 'tap-anim--pop'])
    el.fire('animationend', 'tap-pop')
    assert.equal(el.classes.size, 0)
  }))

  it('adds 0 classes under prefers-reduced-motion', () => withMotion(true, () => {
    const el = fakeChip()
    mod.playTapAnim(el, 'pop')
    assert.equal(el.classes.size, 0)
  }))
})

describe('0 px layout shift', () => {
  it('tap-pop animates transform only, once', () => {
    const kf = CSS.match(/@keyframes tap-pop\s*\{((?:[^{}]*\{[^}]*\})*)\s*\}/)
    assert.ok(kf, '@keyframes tap-pop')
    const props = new Set([...kf[1].matchAll(/([a-z-]+)\s*:/g)].map((m) => m[1]))
    assert.deepEqual([...props], ['transform'])
    assert.match(CSS, /\.tap-anim\s*\{[^}]*animation-iteration-count:\s*1/)
  })

  it('.tap-anim and .tap-anim--pop set no box property', () => {
    for (const sel of ['\\.tap-anim', '\\.tap-anim--pop']) {
      const rule = CSS.match(new RegExp(`${sel}\\s*\\{([^}]*)\\}`))
      assert.ok(rule, sel)
      const props = [...rule[1].matchAll(/([a-z-]+)\s*:/g)].map((m) => m[1])
      for (const p of props) assert.match(p, /^(animation(-[a-z-]+)?|transform-origin)$/, `${sel} sets ${p}`)
    }
  })

  it('the chip is an inline-flex box, so the transform applies without moving the list', () => {
    assert.match(CARD, /\n\.msg-reaction\s*\{[^}]*display:\s*inline-flex/)
  })
})
