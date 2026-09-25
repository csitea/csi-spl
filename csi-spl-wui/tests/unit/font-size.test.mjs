// Font size (CLE-3495): five levels, default one step above the old 16px root,
// − / + clamp at the ends, per-browser persistence, one root variable in CSS.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  FONT_SIZE_KEY,
  FONT_SIZE_MIN,
  FONT_SIZE_MAX,
  FONT_SIZE_DEFAULT,
  FONT_SIZE_PERCENT,
  FONT_SIZE_LEVELS,
  parseFontSize,
  stepFontSize,
  canShrinkFont,
  canGrowFont,
  readStoredFontSize,
  writeStoredFontSize,
  applyFontSizeAttr,
} from '../../src/utils/font-size.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('font size levels', () => {
  it('has exactly five levels, 1..5, growing strictly', () => {
    assert.deepEqual([...FONT_SIZE_LEVELS], [1, 2, 3, 4, 5])
    assert.equal(FONT_SIZE_MIN, 1)
    assert.equal(FONT_SIZE_MAX, 5)
    for (let n = 2; n <= 5; n++) assert.ok(FONT_SIZE_PERCENT[n] > FONT_SIZE_PERCENT[n - 1], `level ${n}`)
  })

  it('the default is one step above the old 100% root (16px)', () => {
    assert.equal(FONT_SIZE_PERCENT[2], 100)
    assert.equal(FONT_SIZE_DEFAULT, 3)
    assert.ok(FONT_SIZE_PERCENT[FONT_SIZE_DEFAULT] > 100)
  })

  it('parseFontSize accepts 1..5 only, anything else is the default', () => {
    for (const n of [1, 2, 3, 4, 5]) {
      assert.equal(parseFontSize(n), n)
      assert.equal(parseFontSize(String(n)), n)
    }
    for (const bad of [0, 6, -1, '2.5', 'big', '', null, undefined, NaN]) assert.equal(parseFontSize(bad), 3, String(bad))
    assert.equal(parseFontSize('x', 1), 1)
  })

  it('− and + move one level and stop at 1 and 5', () => {
    assert.equal(stepFontSize(3, 1), 4)
    assert.equal(stepFontSize(3, -1), 2)
    assert.equal(stepFontSize(5, 1), 5)
    assert.equal(stepFontSize(1, -1), 1)
    assert.equal(stepFontSize(4, 7), 5, 'a big delta is still one step')
    assert.equal(stepFontSize('junk', 1), 4, 'unknown level steps from the default')
    let n = 1
    for (let i = 0; i < 10; i++) n = stepFontSize(n, 1)
    assert.equal(n, 5)
    for (let i = 0; i < 10; i++) n = stepFontSize(n, -1)
    assert.equal(n, 1)
  })

  it('canShrink / canGrow are false exactly at the ends', () => {
    assert.equal(canShrinkFont(1), false)
    assert.equal(canGrowFont(5), false)
    for (const n of [2, 3, 4, 5]) assert.equal(canShrinkFont(n), true)
    for (const n of [1, 2, 3, 4]) assert.equal(canGrowFont(n), true)
  })
})

describe('font size persistence', () => {
  it('reads the default when nothing (or junk) is stored', () => {
    assert.equal(readStoredFontSize(memoryStore()), 3)
    assert.equal(readStoredFontSize(memoryStore({ [FONT_SIZE_KEY]: '9' })), 3)
  })

  it('writes and reads back each level', () => {
    const s = memoryStore()
    for (const n of [1, 2, 3, 4, 5]) {
      assert.equal(writeStoredFontSize(n, s), true)
      assert.equal(s._data[FONT_SIZE_KEY], String(n))
      assert.equal(readStoredFontSize(s), n)
    }
  })

  it('a store that throws falls back without throwing', () => {
    const bad = { getItem() { throw new Error('denied') }, setItem() { throw new Error('denied') } }
    assert.equal(readStoredFontSize(bad), 3)
    assert.equal(writeStoredFontSize(4, bad), false)
  })

  it('applyFontSizeAttr sets data-font-size on the element', () => {
    const attrs = {}
    const el = { setAttribute(k, v) { attrs[k] = v } }
    assert.equal(applyFontSizeAttr(5, el), 5)
    assert.equal(attrs['data-font-size'], '5')
    assert.equal(applyFontSizeAttr('nope', el), 3)
    assert.equal(attrs['data-font-size'], '3')
  })
})

describe('font size CSS contract', () => {
  const base = read('src/assets/css/base.css')

  it('one root variable drives html font-size, one rule per level', () => {
    assert.match(base, /html\s*\{\s*font-size:\s*var\(--font-root\);?\s*\}/)
    for (const n of [1, 2, 3, 4, 5]) {
      const m = new RegExp(`:root\\[data-font-size="${n}"\\]\\s*\\{\\s*--font-root:\\s*([0-9.]+)%`).exec(base)
      assert.ok(m, `level ${n} rule`)
      assert.equal(Number(m[1]), FONT_SIZE_PERCENT[n], `level ${n} percent`)
    }
    const def = /:root\s*\{\s*--font-root:\s*([0-9.]+)%/.exec(base)
    assert.ok(def, 'default rule without the attribute')
    assert.equal(Number(def[1]), FONT_SIZE_PERCENT[FONT_SIZE_DEFAULT])
  })

  it('text sizes are rem, not px, outside the documented exceptions', () => {
    // Avatar initials sit in fixed-px circles; the FontSizeSetting samples show
    // all five sizes side by side. Files in other lanes are listed until they
    // are converted.
    const allowed = new Set([
      'src/components/FontSizeSetting.vue',
      'src/components/UserMenu.vue',
      'src/pages/settings/profile.vue',
      'src/assets/css/main.css',
      'src/components/MessageBody.vue',
      'src/components/ChannelPropertiesDialog.vue',
      'src/components/ChannelSidebar.vue',
    ])
    const walk = (dir) => readdirSync(join(WUI, dir), { withFileTypes: true }).flatMap((d) =>
      d.isDirectory() ? walk(`${dir}/${d.name}`) : /\.(vue|css)$/.test(d.name) ? [`${dir}/${d.name}`] : [])
    const offenders = walk('src').filter((f) => !allowed.has(f) && /font-size:\s*[0-9.]+px/.test(read(f)))
    assert.deepEqual(offenders, [])
    const mainPx = read('src/assets/css/main.css').match(/font-size:\s*[0-9.]+px/g) || []
    assert.equal(mainPx.length, 1, 'main.css keeps only the .avatar initial in px')
  })
})
