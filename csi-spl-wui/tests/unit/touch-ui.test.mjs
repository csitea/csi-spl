// SPL-991: the phone message area - breakpoint, keyboard inset, long-press.
// Run: node tests/unit/touch-ui.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { MOBILE_STACK_QUERY } from '../../src/utils/mobile-stack.mjs'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { messageCardSrc } from './lib/message-card-src.mjs'
import { messageComposerSrc } from './lib/message-composer-src.mjs'
import { importTs } from './lib/load-ts.mjs'
const {
  LONG_PRESS_MS,
  createLongPress,
  isTouchPointer,
  keyboardInset,
  isTextEntry,
  layoutKeyboardStep,
} = await importTs('src/utils/touch-ui.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

function fakeTimers() {
  const q = new Map()
  let n = 0
  return {
    setTimer: (fn, ms) => { q.set(++n, { fn, ms }); return n },
    clearTimer: (id) => { q.delete(id) },
    run() { for (const [id, t] of [...q]) { q.delete(id); t.fn() } },
    get size() { return q.size },
  }
}

describe('the phone line', () => {
  it('is SPL-989\'s one 820 px breakpoint, and the CSS says the same', () => {
    assert.equal(MOBILE_STACK_QUERY, '(max-width: 820px)')
    for (const f of ['MessageCard.vue', 'MessageComposer.vue', 'MentionList.vue']) {
      const src = readFileSync(join(WUI, 'src/components', f), 'utf8')
      assert.match(src, /@media \(max-width: 820px\)/, f)
    }
    assert.match(readFileSync(join(WUI, 'src/composables/useTouchUi.ts'), 'utf8'), /useMobileStack\(\)\.isMobile/)
  })
})

describe('keyboardInset', () => {
  it('is the part of the layout viewport under the keyboard', () => {
    assert.equal(keyboardInset(800, { height: 450, offsetTop: 0 }), 350)
  })
  it('subtracts the visual viewport scrolled down by iOS on focus', () => {
    assert.equal(keyboardInset(800, { height: 450, offsetTop: 100 }), 250)
  })
  it('reads a toolbar slide or a pinch as no keyboard', () => {
    assert.equal(keyboardInset(800, { height: 760, offsetTop: 0 }), 0)
    assert.equal(keyboardInset(800, { height: 900, offsetTop: 0 }), 0)
  })
  it('SPL-2829: zoomed in, every px of the layout viewport under the screen counts', () => {
    /* the owner's screenshot: x1.07, the visual viewport at the top - 52 px
       of the layout viewport under the screen, below the keyboard floor */
    assert.equal(keyboardInset(800, { height: 748, offsetTop: 0, scale: 1.07 }), 52)
    assert.equal(keyboardInset(800, { height: 400, offsetTop: 400, scale: 2 }), 0)
    assert.equal(keyboardInset(800, { height: 400, offsetTop: 410, scale: 2 }), 0)
    /* CONTROL: unzoomed, the same 52 px is a toolbar slide */
    assert.equal(keyboardInset(800, { height: 748, offsetTop: 0, scale: 1 }), 0)
  })
  it('is 0 without the API or with nonsense', () => {
    assert.equal(keyboardInset(800, null), 0)
    assert.equal(keyboardInset(800, undefined), 0)
    assert.equal(keyboardInset(0, { height: 400 }), 0)
    assert.equal(keyboardInset(800, { height: Number.NaN }), 0)
  })
})

describe('SPL-3785 layoutKeyboardStep: the Android keyboard (resizes-content)', () => {
  /* the frames a Pixel 7 gives: 915 tall, a field focused, then the keyboard
     shrinks innerHeight (and visualViewport.height with it) to 615 */
  const run = (frames) => frames.reduce((st, [h, w, editing]) => layoutKeyboardStep(st, h, w, editing), null)
  it('innerHeight 300 px below its height before the focus, a field focused: open', () => {
    assert.equal(run([[915, 412, false], [615, 412, true]]).open, true)
    /* CONTROL: iOS leaves innerHeight alone - not this rule's case (keyboardInset is) */
    assert.equal(run([[915, 412, false], [915, 412, true]]).open, false)
  })
  it('the keyboard goes while the field keeps the focus (Android Back): closed', () => {
    assert.equal(run([[915, 412, false], [615, 412, true], [915, 412, true]]).open, false)
  })
  it('the field loses the focus: closed, and the base is the new height', () => {
    const st = run([[915, 412, false], [615, 412, true], [615, 412, false]])
    assert.equal(st.open, false)
    assert.equal(st.base, 615)
  })
  it('a shrink with NO field focused is the toolbar or a split screen, not a keyboard', () => {
    assert.equal(run([[915, 412, false], [615, 412, false]]).open, false)
  })
  it('a turned phone (another width) is a new base, not a keyboard', () => {
    assert.equal(run([[915, 412, false], [412, 915, true]]).open, false)
  })
  it('the browser toolbar sliding (< 60 px) is no keyboard', () => {
    assert.equal(run([[915, 412, false], [860, 412, true]]).open, false)
  })
  it('nonsense keeps it closed', () => {
    assert.equal(run([[915, 412, false], [0, 412, true]]).open, false)
    assert.equal(run([[915, 412, false], [Number.NaN, 412, true]]).open, false)
  })
})

describe('SPL-3785 isTextEntry: a field the keyboard types into', () => {
  it('text inputs, textareas and contenteditable are; buttons, checkboxes and read-only fields are not', () => {
    assert.equal(isTextEntry({ tagName: 'TEXTAREA' }), true)
    assert.equal(isTextEntry({ tagName: 'INPUT', type: 'text' }), true)
    assert.equal(isTextEntry({ tagName: 'INPUT', type: 'search' }), true)
    assert.equal(isTextEntry({ tagName: 'INPUT', type: '' }), true)
    assert.equal(isTextEntry({ tagName: 'DIV', isContentEditable: true }), true)
    assert.equal(isTextEntry({ tagName: 'INPUT', type: 'checkbox' }), false)
    assert.equal(isTextEntry({ tagName: 'BUTTON' }), false)
    assert.equal(isTextEntry({ tagName: 'TEXTAREA', readOnly: true }), false)
    assert.equal(isTextEntry(null), false)
  })
})

describe('isTouchPointer', () => {
  it('a finger and a pen long-press, a mouse has its right-click', () => {
    assert.equal(isTouchPointer('touch'), true)
    assert.equal(isTouchPointer('pen'), true)
    assert.equal(isTouchPointer('mouse'), false)
    assert.equal(isTouchPointer(undefined), false)
  })
})

describe('createLongPress', () => {
  const touch = (x = 10, y = 10) => ({ pointerType: 'touch', clientX: x, clientY: y, isPrimary: true })

  it('fires once after the delay at the press point, and swallows the next click once', () => {
    const t = fakeTimers()
    const hits = []
    const lp = createLongPress({ onPress: (x, y) => hits.push([x, y]), ...t })
    lp.down(touch(20, 30))
    assert.equal(lp.pending, true)
    t.run()
    assert.deepEqual(hits, [[20, 30]])
    assert.equal(lp.takeClick(), true)
    assert.equal(lp.takeClick(), false)
  })

  it('uses LONG_PRESS_MS by default', () => {
    const t = fakeTimers()
    let ms = 0
    const lp = createLongPress({ onPress: () => {}, setTimer: (fn, d) => { ms = d; return t.setTimer(fn, d) }, clearTimer: t.clearTimer })
    lp.down(touch())
    assert.equal(ms, LONG_PRESS_MS)
  })

  it('a finger that moves past the slop is scrolling: no press', () => {
    const t = fakeTimers()
    let hit = 0
    const lp = createLongPress({ onPress: () => { hit++ }, ...t })
    lp.down(touch(10, 10))
    lp.move({ clientX: 12, clientY: 14 })
    assert.equal(lp.pending, true)
    lp.move({ clientX: 10, clientY: 40 })
    assert.equal(lp.pending, false)
    t.run()
    assert.equal(hit, 0)
    assert.equal(lp.takeClick(), false)
  })

  it('lifting early is a tap, not a press', () => {
    const t = fakeTimers()
    let hit = 0
    const lp = createLongPress({ onPress: () => { hit++ }, ...t })
    lp.down(touch())
    lp.up()
    t.run()
    assert.equal(hit, 0)
    assert.equal(t.size, 0)
  })

  it('a mouse or a second finger never starts one', () => {
    const t = fakeTimers()
    const lp = createLongPress({ onPress: () => {}, ...t })
    lp.down({ pointerType: 'mouse', clientX: 0, clientY: 0 })
    assert.equal(lp.pending, false)
    lp.down({ pointerType: 'touch', clientX: 0, clientY: 0, isPrimary: false })
    assert.equal(lp.pending, false)
  })

  it('a new touch clears a stale fired flag', () => {
    const t = fakeTimers()
    const lp = createLongPress({ onPress: () => {}, ...t })
    lp.down(touch())
    t.run()
    lp.down(touch())
    lp.up()
    assert.equal(lp.takeClick(), false)
  })
})

describe('the phone composer dock (MessageComposer.vue)', () => {
  const vue = messageComposerSrc()
  it('docks only the global composer, on a phone, on EVERY level and page (SPL-1005), unless dock=false', () => {
    assert.match(vue, /const docked = computed\(\(\) => Boolean\(props\.global\) && props\.dock && phone\.value\)/)
  })
  it('dock defaults to true (Vue reads an absent boolean prop as false)', () => {
    assert.match(vue, /\}>\(\), \{ dock: true \}\)/)
  })
  it('sits above the keyboard and publishes its height for the panes and the top bar', () => {
    assert.match(vue, /bottom: calc\(var\(--kb-inset, 0px\) \+ var\(--status-strip-h, 0px\)\);/)
    assert.match(vue, /setProperty\('--composer-dock-h'/)
    assert.match(vue, /const kbInset = useKeyboardInset\(\)/)
  })
  it('CLE-77888: sits on the bottom status strip and counts it in its dock height', () => {
    assert.match(vue, /const total = px > 0 \? px \+ stripH\.value : 0/)
    assert.match(vue, /watch\(stripH, \(\) => setDockHeight\(dockPx\)\)/)
    const strip = readFileSync(join(WUI, 'src/components/MobileStatusStrip.vue'), 'utf8')
    for (const t of ['status-strip-health', 'status-strip-version']) assert.ok(strip.includes(`data-test="${t}"`), t)
    assert.match(strip, /<NotificationCenter placement="strip" \/>/)
    assert.match(strip, /const shown = computed\(\(\) => !kbOpen\.value\)/)
    assert.match(strip, /const kbOpen = useKeyboardOpen\(\)/)
    const layout = readFileSync(join(WUI, 'src/layouts/default.vue'), 'utf8')
    assert.match(layout, /<MobileStatusStrip v-if="stack\.isMobile\.value && !docsReading" \/>/)
  })
  /* SPL-2093 (owner, t1 04d9c246): the dock 8 px lower - its controls keep
     the 44 px width and are 40 px tall, still a touch target */
  it('keeps iOS from zooming, and every control is a 44 x 40 px target', () => {
    assert.match(vue, /\.composer--dock\.composer--dock textarea \{\s*font-size: max\(16px, 1rem\);/)
    assert.match(vue, /--dock-tap: 40px;/)
    assert.match(vue, /width: var\(--tap\);\s*height: var\(--dock-tap\);/)
  })
  it('honours the submit-key setting on the on-screen keyboard too', () => {
    assert.match(vue, /:enterkeyhint="docked \? \(submitMode === 'enter' \? 'send' : 'enter'\) : undefined"/)
  })
  it('has no camera button: a photo is taken through Attach (topic d4bc9db4)', () => {
    assert.doesNotMatch(vue, /capture=|attach-camera|openCamera/)
    /* no accept= on the one picker, so the OS sheet offers files, gallery and camera */
    assert.match(vue, /type="file"\s*multiple\s*hidden/)
  })
  it('the dock row is Back | Attach | Send, Back the top bar\'s "<" (topic d4bc9db4)', () => {
    const row = vue.slice(vue.indexOf('<div class="composer-row">'))
    const at = (id) => row.indexOf(`data-testid="${id}"`)
    assert.ok(at('dock-back') > 0 && at('dock-back') < at('attach') && at('attach') < at('send'))
    const back = readFileSync(join(WUI, 'src/components/MobileBack.vue'), 'utf8')
    assert.match(back, /@click\.stop="stack\.pop\(\)"/)
    assert.match(row, /data-testid="dock-back"[^>]*@click\.stop="stack\.pop\(\)"[^>]*:aria-label="t\('mobile\.back'\)"/)
  })
  it('the sheet Reply focuses it', () => {
    assert.match(vue, /window\.addEventListener\(COMPOSER_FOCUS_EVENT, onFocusRequest\)/)
    const card = messageCardSrc()
    assert.match(card, /new CustomEvent\(COMPOSER_FOCUS_EVENT\)/)
  })
})

describe('the phone card rules win (MessageCard.vue)', () => {
  it('the <= 820 px block is the last rule block, so same-specificity rules above cannot undo it', () => {
    const vue = readFileSync(join(WUI, 'src/components/MessageCard.vue'), 'utf8')
    const css = vue.slice(vue.lastIndexOf('<style'))
    const at = css.indexOf('@media (max-width: 820px)')
    assert.ok(at > 0)
    const after = css.slice(at)
    for (const sel of ['.card-grip {', '.msg-reaction {', '.msg-meta > .msg-reactions {']) {
      assert.ok(after.includes(sel), sel + ' is overridden inside the phone block')
      assert.ok(css.lastIndexOf(sel) >= at, sel + ' has no later desktop rule')
    }
  })
})
