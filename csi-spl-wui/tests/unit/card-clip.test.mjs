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
  CARD_CLIP_THREAD_KEY,
  cardClipKey,
  cardClipPx,
  clipsInThread,
  cardDragPx,
  cardHasPicture,
  cardIsClipped,
  cardTitle,
  parseCardClipMode,
  readCardClipMode,
  writeCardClipMode,
  readCardClipDefault,
  writeCardClipDefault,
  readEffectiveCardClip,
  writeCardClipSession,
  clearCardClipSession,
  CARD_CLIP_DEFAULT_KEY,
} from '../../src/utils/card-clip.mjs'
import { PREVIEW_MAX_BYTES } from '../../src/utils/file-preview.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

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

describe('appearance default and a per-view session override', () => {
  it('a fresh sign-in follows the appearance default, and a view can override it', () => {
    const durable = memoryStore()
    const session = memoryStore()
    assert.equal(CARD_CLIP_DEFAULT_KEY, 'spool-card-clip-default')
    assert.equal(readCardClipDefault(durable), 'rows')
    assert.equal(readEffectiveCardClip('msgs', durable, session), 'rows')
    writeCardClipDefault('titles', durable)
    assert.equal(readEffectiveCardClip('msgs', durable, session), 'titles')
    assert.equal(readEffectiveCardClip('thread', durable, session), 'titles')
    writeCardClipSession('full', 'thread', session)
    assert.equal(readEffectiveCardClip('thread', durable, session), 'full')
    assert.equal(readEffectiveCardClip('msgs', durable, session), 'titles')
    clearCardClipSession(session)
    assert.equal(readEffectiveCardClip('thread', durable, session), 'titles')
  })

  it('the appearance page offers the three list modes', () => {
    const src = read('src/pages/settings/appearance.vue')
    assert.match(src, /data-test="list-clip-default"/)
    assert.match(src, /data-test="`list-clip-\$\{m\}`"/)
    assert.match(src, /setClipDefault/)
  })

  it('the header control writes the session, and sign-out clears it', () => {
    const clip = read('src/composables/useCardClip.ts')
    assert.match(clip, /writeCardClipSession/)
    assert.match(clip, /readEffectiveCardClip/)
    const session = read('src/stores/session.ts')
    assert.match(session, /clearCardClipSession\(\)/)
  })
})

describe('SPL-945: the thread pane has its own control and mode, for the replies', () => {
  it('stores the thread mode under its own key, apart from the middle pane', () => {
    const store = memoryStore()
    assert.equal(CARD_CLIP_THREAD_KEY, 'spool-card-clip-thread')
    assert.equal(cardClipKey('thread'), 'spool-card-clip-thread')
    assert.equal(cardClipKey('msgs'), 'spool-card-clip')
    assert.equal(cardClipKey(), 'spool-card-clip')
    assert.equal(readCardClipMode(store, 'thread'), 'rows')
    writeCardClipMode('full', store, 'thread')
    writeCardClipMode('titles', store)
    assert.equal(readCardClipMode(store, 'thread'), 'full')
    assert.equal(readCardClipMode(store), 'titles')
    assert.equal(store.getItem('spool-card-clip-thread'), 'full')
  })

  it('clips a reply (is_parent 0, or no flag) and never the root (is_parent 1)', () => {
    assert.equal(clipsInThread({ is_parent: 0 }), true)
    assert.equal(clipsInThread({}), true)
    assert.equal(clipsInThread({ is_parent: 1 }), false)
    assert.equal(clipsInThread({ is_parent: '1' }), false)
  })

  for (const p of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
    it(`${p}: the control in the header, the feed clips with the thread mode`, () => {
      const src = read(p)
      assert.match(src, /<header>[\s\S]*?<LazyCardClipControl pane="thread" \/>[\s\S]*?<\/header>/, 'lazy: the shell\'s initial chunk is at its ceiling')
      assert.match(src, /<LiveFeed\s+clip\s+clip-pane="thread"\s+hold-scroll/)
    })
  }

  it('the /t topic page reads the thread mode too, so its root stays whole', () => {
    assert.match(read('src/pages/t/[task_id].vue'), /<LiveFeed\s+clip\s+clip-pane="thread"\s+hold-scroll/)
  })

  it('LiveFeed reads the pane\'s mode and skips the thread root', () => {
    const src = read('src/components/LiveFeed.vue')
    assert.match(src, /useCardClip\(props\.clipPane\)/)
    assert.match(src, /props\.clipPane === 'thread' && !clipsInThread\(m\)\) return undefined/)
    assert.match(src, /:clip-mode="clipModeFor\(m\)"/)
  })

  it('the middle pane stays on the default pane', () => {
    assert.match(read('src/components/MessageFeed.vue'), /\bclip\b/)
    assert.doesNotMatch(read('src/components/MessageFeed.vue'), /clip-pane/)
    assert.match(read('src/components/CardClipControl.vue'), /useCardClip\(props\.pane\)/)
    assert.match(read('src/composables/useCardClip.ts'), /const key = cardClipKey\(pane\)/)
  })
})
