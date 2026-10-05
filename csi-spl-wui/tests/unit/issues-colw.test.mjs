// owner, topic beb4024f: "the columns of the issues grid should be
// resizeable" - utils/issues-colw.mjs (widths, keys, storage) and the sheet
// wiring in pages/issues.vue.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  COLW_MAX, COLW_MIN, COLW_MIN_BY_COL, COLW_STEP, colMin, ISSUES_COLW_COLS, ISSUES_COLW_KEY,
  clampColWidth, cleanColWidths, colWidthClasses, colWidthVars, dragWidth, keyWidth, loadColWidths, pendingSave, saveColWidths, withColWidth,
  COLW_STASH_MAX_MS, ISSUES_COLW_STASH_KEY, stashColWidths, takeColWidthsStash,
} from '../../src/utils/issues-colw.mjs'
import { memoryStore } from '../../src/utils/prefs.mjs'
import { createAuthClient } from '../../src/utils/auth-client.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

describe('issues column widths', () => {
  it('clamps to [min, max] whole px; junk is null', () => {
    assert.equal(clampColWidth(10), COLW_MIN)
    assert.equal(clampColWidth(5000), COLW_MAX)
    assert.equal(clampColWidth(120.6), 121)
    assert.equal(clampColWidth('x'), null)
    assert.equal(clampColWidth(undefined), null)
    assert.equal(clampColWidth(''), null)
  })

  it('Key and Title keep their own floor; every other column the common one', () => {
    assert.equal(clampColWidth(10, 'title'), COLW_MIN_BY_COL.title)
    assert.equal(clampColWidth(10, 'key'), COLW_MIN_BY_COL.key)
    assert.equal(clampColWidth(10, 'status'), COLW_MIN)
    assert.equal(colMin('title'), 160)
    assert.deepEqual(withColWidth({}, 'title', 50), { title: 160 })
    assert.equal(keyWidth(170, 'ArrowLeft', false, 'title'), 160)
    assert.equal(dragWidth(200, -300, false, 'key'), 56)
  })

  it('a drag adds the pointer travel, mirrored right-to-left', () => {
    assert.equal(dragWidth(100, 40), 140)
    assert.equal(dragWidth(100, 40, true), 60)
    assert.equal(dragWidth(100, -500), COLW_MIN)
  })

  it('arrow keys step, Delete / Backspace mean automatic, other keys do nothing', () => {
    assert.equal(keyWidth(100, 'ArrowRight'), 100 + COLW_STEP)
    assert.equal(keyWidth(100, 'ArrowLeft'), 100 - COLW_STEP)
    assert.equal(keyWidth(100, 'ArrowLeft', true), 100 + COLW_STEP)
    assert.equal(keyWidth(100, 'Delete'), 0)
    assert.equal(keyWidth(100, 'Backspace'), 0)
    assert.equal(keyWidth(100, 'Enter'), null)
    assert.equal(keyWidth(100, 'ArrowUp'), null)
  })

  it('set / unset one column returns a new object; unknown columns are refused', () => {
    const a = { status: 120 }
    const b = withColWidth(a, 'title', 300)
    assert.deepEqual(b, { status: 120, title: 300 })
    assert.deepEqual(a, { status: 120 })
    assert.deepEqual(withColWidth(b, 'status', 0), { title: 300 })
    assert.deepEqual(withColWidth(b, 'bogus', 200), b)
  })

  it('storage keeps only known columns with sane widths', () => {
    const store = memoryStore()
    assert.deepEqual(loadColWidths(store), {})
    saveColWidths({ status: 130, nope: 50, label: 'wide' }, store)
    assert.deepEqual(JSON.parse(store.getItem(ISSUES_COLW_KEY)), { status: 130 })
    assert.deepEqual(loadColWidths(memoryStore({ [ISSUES_COLW_KEY]: '{bad json' })), {})
    assert.deepEqual(loadColWidths(memoryStore({ [ISSUES_COLW_KEY]: '[1,2]' })), {})
    assert.deepEqual(cleanColWidths({ key: 20 }), { key: COLW_MIN_BY_COL.key })
  })

  it('the table gets one custom property and one class per set column', () => {
    assert.deepEqual(colWidthVars({ status: 120, title: 300 }), { '--iw-status': '120px', '--iw-title': '300px' })
    assert.deepEqual(colWidthClasses({ status: 120 }), ['issues-w-status'])
    assert.deepEqual(colWidthVars({}), {})
  })

  it('the sheet wires every column: a grip per header, data-col per cell, a CSS rule per column', () => {
    const vue = readFileSync(join(SRC, 'pages/issues.vue'), 'utf8')
    assert.match(vue, /class="issues-col-grip"[\s\S]{0,700}@pointerdown="onGripDown\(\$event, c\.col\)"/)
    /* the grip handlers live in composables/useIssueColumnGrips (CLE-77915) */
    const grips = readFileSync(join(SRC, 'composables/useIssueColumnGrips.ts'), 'utf8')
    assert.match(vue, /useIssueColumnGrips\(/)
    assert.match(grips, /lastGripDown\.col === col && now - lastGripDown\.at < 400\)[\s\S]{0,80}void fitColumn\(col\)/)
    assert.match(vue, /@keydown\.alt\.left="onGripKey\(\$event, c\.col\)"/)
    assert.match(vue, /@keydown\.alt\.right="onGripKey\(\$event, c\.col\)"/)
    assert.match(vue, /:class="colWidthClasses\(colWidths\)" :style="colWidthVars\(colWidths\)"/)
    for (const col of ISSUES_COLW_COLS) {
      assert.match(vue, new RegExp(`\\.issues-table\\.issues-w-${col} \\[data-col="${col}"\\] \\{ width: var\\(--iw-${col}\\)`), col)
      assert.ok((vue.match(new RegExp(`<th data-col="${col}"|<th class="issues-c-key" data-col="${col}"`, 'g')) || []).length >= 1 || col === 'key', 'filter row ' + col)
    }
  })

  /* c-340: a drag then a reload inside the 500 ms debounce lost the width
     (live, dev 1.5.4: no PUT before the reload, 214 -> 114). The page now
     sends the pending save on pagehide, keepalive so it outlives the page. */
  it('a pending save runs once: on its timer, or at once on flush (pagehide)', () => {
    const timers = []
    const t = { setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimeout: (id) => { timers[id - 1].fn = null } }
    const runs = []
    const s = pendingSave((opts) => runs.push(opts), 500, t)
    assert.equal(s.flush({ keepalive: true }), false)
    s.schedule()
    s.schedule()
    assert.equal(timers.filter((x) => x.fn).length, 1)
    assert.equal(timers[1].ms, 500)
    assert.equal(s.flush({ keepalive: true }), true)
    assert.deepEqual(runs, [{ keepalive: true }])
    assert.equal(s.flush({ keepalive: true }), false)
    s.schedule()
    timers.at(-1).fn()
    assert.deepEqual(runs, [{ keepalive: true }, {}])
    assert.equal(s.flush(), false)
  })

  it('the keepalive save reaches fetch; an ordinary save does not ask for it', async () => {
    const sent = []
    const fetchFn = async (url, init) => {
      sent.push(init)
      return new Response(null, { status: 204 })
    }
    const c = createAuthClient({ fetchFn, base: 'https://hub.example.com/api/v1/auth' })
    await c.saveIssueColumns({ status: 214 }, { keepalive: true })
    await c.saveIssueColumns({ status: 214 })
    assert.equal(sent[0].keepalive, true)
    assert.equal(sent[0].method, 'PUT')
    assert.equal(sent[1].keepalive, undefined)
  })

  it('the sheet sends a pending width save on pagehide, keepalive', () => {
    const ts = readFileSync(join(SRC, 'composables/useIssueColumns.ts'), 'utf8')
    assert.match(ts, /addEventListener\('pagehide', onPageHide\)/)
    assert.match(ts, /removeEventListener\('pagehide', onPageHide\)/)
    assert.match(ts, /function onPageHide\(\)[\s\S]{0,80}\.flush\(\{ keepalive: true \}\)/)
    assert.match(ts, /auth\.saveIssueColumns\(v, opts\)/)
  })

  /* the reloaded page read its session ~130 ms in, before the keepalive PUT
     landed (live, dev 1.5.5: hub {"status":214}, page 114) */
  it('the pagehide stash is read once, by the same person, within a minute', () => {
    const store = memoryStore()
    assert.equal(takeColWidthsStash(store, 1000), null)
    assert.equal(stashColWidths({ status: 214 }, 'HUM-4', store, 1000), true)
    assert.deepEqual(takeColWidthsStash(store, 1200), { hum: 'HUM-4', w: { status: 214 } })
    assert.equal(takeColWidthsStash(store, 1300), null)
    stashColWidths({ status: 214 }, 'HUM-4', store, 1000)
    assert.equal(takeColWidthsStash(store, 1000 + COLW_STASH_MAX_MS + 1), null)
    assert.equal(takeColWidthsStash(store, 1000), null)
    assert.equal(stashColWidths({ status: 214 }, '', store, 1000), false)
    assert.equal(stashColWidths({ status: 214 }, 'HUM-4', null, 1000), false)
    assert.equal(takeColWidthsStash(memoryStore({ [ISSUES_COLW_STASH_KEY]: '{bad' }), 1000), null)
    assert.equal(takeColWidthsStash(memoryStore({ [ISSUES_COLW_STASH_KEY]: '{"hum":"HUM-4","w":[1],"at":1000}' }), 1000), null)
  })

  it('the sheet stashes on pagehide and gives the stash back on its next load', () => {
    const ts = readFileSync(join(SRC, 'composables/useIssueColumns.ts'), 'utf8')
    assert.match(ts, /if \(pending\.flush\(\{ keepalive: true \}\)\) stashColWidths\(now, person\(\), tabStore\(\)\)/)
    assert.match(ts, /takeColWidthsStash\(tabStore\(\)\)/)
    assert.match(ts, /person\(\) === stash\.hum\) save\(stash\.w\)/)
    assert.match(ts, /onMounted\(\(\) => \{[\s\S]{0,120}restoreStash\(\)/)
    /* hum is omitempty on the hub (only "when wired"): the email stands in */
    assert.match(ts, /const person = \(\) => String\(session\.claims\?\.hum \|\| session\.claims\?\.email \|\| ''\)/)
  })
})
