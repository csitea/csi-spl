// E06: the section strip must not force a layout at mount. Overflow and the
// first centre are computed in the ResizeObserver callback, from one read
// taken while layout is clean, then a single scrollLeft write. The old mount
// called refresh(true), which read a rect per control while Vue's DOM was
// still dirty.
//
// The scroll numbers below are the Chrome result of reveal + wrap (m390, the
// phone strip's flex row, gap 4) for the read taken BEFORE the copies exist.
// loopMountScroll must land on that picture within 2 px.
//
// Run: node tests/unit/loop-strip-mount.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { loopPosition } from '../../src/utils/section-strip.mjs'

const src = readFileSync(fileURLToPath(new URL('../../src/composables/useLoopStrip.ts', import.meta.url)), 'utf8')

function bodyOf(name) {
  const start = src.search(new RegExp(`function ${name}\\b`))
  assert.ok(start >= 0, name)
  const open = src.indexOf('{', src.indexOf(')', start))
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++
    else if (src[i] === '}') {
      depth--
      if (depth === 0) return src.slice(open + 1, i)
    }
  }
  throw new Error(`no end for ${name}`)
}

const loopMountScroll = new Function('snap', 'wrap', bodyOf('loopMountScroll'))
const loopScrollWrite = new Function('snap', 'wrap', bodyOf('loopScrollWrite'))
const stripOverflows = new Function('span', 'view', bodyOf('stripOverflows'))

function mountedOf(text) {
  const a = text.indexOf('onMounted(() =>')
  const b = text.indexOf('onBeforeUnmount(() =>')
  assert.ok(a >= 0 && b > a, 'onMounted block')
  return text.slice(a, b)
}

function assertNoMountRead(text) {
  const mounted = mountedOf(text)
  assert.equal(text.includes('refresh(true)'), false)
  assert.equal(mounted.includes('getBoundingClientRect'), false)
  assert.equal(mounted.includes('getComputedStyle'), false)
  assert.equal(mounted.includes('scrollWidth'), false)
  assert.match(mounted, /new ResizeObserver\(\(\) => \{ void place\(ctx, !centred\.v\) \}\)/)
  assert.match(mounted, /ro\.observe\(box\)/)
}

describe('strip overflow', () => {
  it('overflows only past the row by more than a pixel', () => {
    assert.equal(stripOverflows(100, 100), false)
    assert.equal(stripOverflows(101, 100), false)
    assert.equal(stripOverflows(102, 100), true)
  })
})

describe('the mount scroll, predicted before the copies exist', () => {
  /* Chrome, reveal + wrap, copies inserted after the read. Tolerance covers
     the selected control's 1 px margin, which the span rounds differently
     from the laid-out copy. */
  const cases = [
    { name: 'ltr Channels', snap: { span: 816.66, gap: 4, rtl: false, max: 444, delta: -153.24, scrollLeft: 0 }, chrome: 668.41 },
    { name: 'ltr Issues', snap: { span: 814.63, gap: 4, rtl: false, max: 441, delta: -19.38, scrollLeft: 0 }, chrome: 799.25 },
    { name: 'ltr Boxes', snap: { span: 814.63, gap: 4, rtl: false, max: 441, delta: 428.63, scrollLeft: 0 }, chrome: 428.63 },
    { name: 'ltr Settings', snap: { span: 812.63, gap: 4, rtl: false, max: 439, delta: 599.63, scrollLeft: 0 }, chrome: 599.63 },
    { name: 'rtl Channels', snap: { span: 816.66, gap: 4, rtl: true, max: 444, delta: 153.24, scrollLeft: 0 }, chrome: -1490.07 },
    { name: 'rtl Issues', snap: { span: 814.63, gap: 4, rtl: true, max: 441, delta: 19.38, scrollLeft: 0 }, chrome: -1617.88 },
    { name: 'rtl Boxes', snap: { span: 814.63, gap: 4, rtl: true, max: 441, delta: -428.63, scrollLeft: 0 }, chrome: -1247.25 },
    { name: 'rtl Settings', snap: { span: 812.63, gap: 4, rtl: true, max: 439, delta: -599.63, scrollLeft: 0 }, chrome: -1416.25 },
  ]
  for (const c of cases) {
    it(`${c.name} matches the laid-out reveal + wrap`, () => {
      const write = loopMountScroll(c.snap, loopPosition)
      assert.ok(Math.abs(write - c.chrome) <= 2, `${write} vs chrome ${c.chrome}`)
    })
  }
})

describe('a later scroll, copies already laid out', () => {
  it('leaves a fully visible control where it is unless force is set', () => {
    const snap = { rtl: false, max: 400, pos: 100, delta: 12, set: 200, force: false, fully: true, hasSel: true }
    assert.equal(loopScrollWrite(snap, loopPosition), null)
    assert.equal(loopScrollWrite({ ...snap, force: true }, loopPosition), 112)
  })
  it('centres a cut-off control and wraps it back into the middle copy', () => {
    const snap = { rtl: false, max: 2000, pos: 10, delta: 1400, set: 800, force: false, fully: false, hasSel: true }
    assert.equal(loopScrollWrite(snap, loopPosition), loopPosition(1410, 800))
  })
  it('no selected control writes nothing', () => {
    assert.equal(loopScrollWrite({ rtl: false, max: 0, pos: 0, delta: 0, set: 0, force: true, fully: false, hasSel: false }, loopPosition), null)
  })
})

describe('mount does not read layout', () => {
  it('the old synchronous refresh(true) is gone', () => {
    assertNoMountRead(src)
    assert.match(src, /overflowAnchor = 'none'/)
  })
  it('after the copies land, the callback writes scroll and does not read', () => {
    const place = bodyOf('place')
    const turn = place.slice(place.indexOf('if (turningOn)'))
    const afterCopies = turn.slice(turn.indexOf('await nextTick'))
    assert.equal(/getBoundingClientRect|getComputedStyle|scrollWidth|clientWidth|scrollLeft ===/.test(afterCopies), false)
    assert.match(afterCopies, /box\.scrollLeft = write/)
    const writeAt = turn.indexOf('box.scrollLeft = write')
    const showAt = turn.indexOf('showStrip(box)')
    assert.ok(writeAt >= 0 && showAt > writeAt, 'shown only after the centred scroll')
  })
  it('an enabled strip stays hidden until that centred frame', () => {
    assert.match(mountedOf(src), /if \(opts\.enabled\(\)\) box\.style\.visibility = 'hidden'/)
  })
  it('control: planting the old mount read fails the gate', () => {
    const planted = src.replace('ro.observe(box)', 'ro.observe(box)\n    void refresh(true)')
    assert.throws(() => assertNoMountRead(planted))
  })
})
