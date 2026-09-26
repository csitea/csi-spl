// Level-1 card height (specs/033, utils/card-clip.mjs).
// Modes: titles (first 90 code points) | rows (default, 5 text rows, or
// 30% of the window when a picture is on the card) | full (not clipped).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  CARD_CLIP_DEFAULT,
  CARD_CLIP_KEY,
  CARD_CLIP_MODES,
  CARD_CLIP_ROWS,
  cardClipPx,
  cardDragPx,
  cardHasPicture,
  cardIsClipped,
  cardTitle,
  parseCardClipMode,
  readCardClipMode,
  writeCardClipMode,
} from '../../src/utils/card-clip.mjs'
import { PREVIEW_MAX_BYTES } from '../../src/utils/file-preview.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

describe('parseCardClipMode', () => {
  it('keeps a known mode and trims it', () => {
    assert.deepEqual([...CARD_CLIP_MODES], ['titles', 'rows', 'full'])
    assert.equal(CARD_CLIP_DEFAULT, 'rows')
    assert.equal(parseCardClipMode('titles'), 'titles')
    assert.equal(parseCardClipMode('  full  '), 'full')
    assert.equal(parseCardClipMode(' rows '), 'rows')
  })

  it('falls back when the value is missing or unknown', () => {
    assert.equal(parseCardClipMode(undefined), 'rows')
    assert.equal(parseCardClipMode(null), 'rows')
    assert.equal(parseCardClipMode(''), 'rows')
    assert.equal(parseCardClipMode('FULL'), 'rows')
    assert.equal(parseCardClipMode('nope'), 'rows')
    assert.equal(parseCardClipMode('nope', 'full'), 'full')
  })
})

describe('cardTitle', () => {
  it('leaves a short body unchanged', () => {
    assert.equal(cardTitle('hello'), 'hello')
    assert.equal(cardTitle(''), '')
    assert.equal(cardTitle(null), '')
  })

  it('folds newlines to one space and drops a fence marker', () => {
    assert.equal(cardTitle('a\n\n  b'), 'a b')
    assert.equal(cardTitle('```js\nconst x = 1'), 'const x = 1')
    assert.equal(cardTitle('hello ```py world'), 'hello world')
  })

  it('cuts at 90 code points and does not split an emoji', () => {
    assert.equal(cardTitle('a'.repeat(90)), 'a'.repeat(90))
    assert.equal(cardTitle('a'.repeat(91)), 'a'.repeat(90) + '…')
    const emoji = '😀'
    assert.equal([...emoji].length, 1)
    const cut = cardTitle('a'.repeat(89) + emoji + 'ZZZZ')
    assert.equal(cut, 'a'.repeat(89) + emoji + '…')
    assert.equal(cut.includes('\uD83D'), true)
    assert.equal(cut.includes('\uDE00'), true)
    assert.equal(cut.includes('\uD83D\uDE00'), true)
  })

  it('trims the cut so the ellipsis does not follow a space', () => {
    assert.equal(cardTitle('a'.repeat(89) + ' ' + 'b'.repeat(10)), 'a'.repeat(89) + '…')
  })
})

describe('cardHasPicture', () => {
  it('is true for a small png and false for a pdf or an oversized png', () => {
    assert.equal(cardHasPicture([{ name: 'shot.png', bytes: 100 }]), true)
    assert.equal(cardHasPicture([{ name: 'notes.pdf', bytes: 100 }]), false)
    assert.equal(cardHasPicture([{ name: 'shot.png', bytes: PREVIEW_MAX_BYTES + 1 }]), false)
    assert.equal(cardHasPicture([]), false)
    assert.equal(cardHasPicture(null), false)
  })
})

describe('cardClipPx', () => {
  it('clips text at 5 rows and a picture at 30% of the window, never under 5 rows', () => {
    assert.equal(cardClipPx({
      mode: 'rows', picture: false, lineHeightPx: 20, viewportPx: 1000,
    }), 20 * CARD_CLIP_ROWS)
    assert.equal(cardClipPx({
      mode: 'rows', picture: true, lineHeightPx: 20, viewportPx: 1000,
    }), 300)
    assert.equal(cardClipPx({
      mode: 'rows', picture: true, lineHeightPx: 20, viewportPx: 100,
    }), 100)
  })

  it('lets a grip replace the automatic height, floored at one row', () => {
    assert.equal(cardClipPx({
      mode: 'rows', picture: true, lineHeightPx: 20, viewportPx: 1000, userPx: 80,
    }), 80)
    assert.equal(cardClipPx({
      mode: 'rows', picture: false, lineHeightPx: 20, viewportPx: 1000, userPx: 5,
    }), 20)
  })

  it('does not clip titles or full', () => {
    const base = { picture: true, lineHeightPx: 20, viewportPx: 1000, userPx: 400 }
    assert.equal(cardClipPx({ ...base, mode: 'titles' }), null)
    assert.equal(cardClipPx({ ...base, mode: 'full' }), null)
  })
})

describe('cardDragPx', () => {
  it('stays between one row and the card', () => {
    assert.equal(cardDragPx(100, 40, 20, 200), 140)
    assert.equal(cardDragPx(100, -90, 20, 200), 20)
    assert.equal(cardDragPx(100, 500, 20, 200), 200)
  })
})

describe('cardIsClipped', () => {
  it('allows 1px of rounding slack', () => {
    assert.equal(cardIsClipped(101, 100), false)
    assert.equal(cardIsClipped(102, 100), true)
    assert.equal(cardIsClipped(100, 100), false)
  })
})

describe('read and write the mode', () => {
  it('stores spool-card-clip and reads a bad value back as rows', () => {
    const store = memoryStore()
    assert.equal(CARD_CLIP_KEY, 'spool-card-clip')
    assert.equal(readCardClipMode(store), 'rows')
    assert.equal(writeCardClipMode('titles', store), true)
    assert.equal(store.getItem('spool-card-clip'), 'titles')
    assert.equal(readCardClipMode(store), 'titles')
    store.setItem('spool-card-clip', 'nope')
    assert.equal(readCardClipMode(store), 'rows')
    assert.equal(writeCardClipMode('bogus', store), true)
    assert.equal(store.getItem('spool-card-clip'), 'rows')
    store.setItem('spool-card-clip', '  full  ')
    assert.equal(readCardClipMode(store), 'full')
  })
})

describe('the thread uses the same card height mode', () => {
  const read = (rel) => readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../..', rel), 'utf8')
  for (const rel of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue', 'src/pages/t/[task_id].vue']) {
    it(`${rel} passes clip to the thread feed`, () => {
      assert.match(read(rel), /<LiveFeed\s+clip\b/)
    })
  }
})
