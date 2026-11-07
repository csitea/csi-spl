// SPL-4901 (owner HUM-10, t1 7da30ebd msg 5af63dee; t1 2f4311d9 msgs
// 1497d676, acf9d324): the search button opens on the entities of the section
// the reader is in - calendar entries, notes, qto docs - from one map,
// utils/section-search.mjs. The browser half (phone 390, desktop 1440) is
// tests/e2e/section-search.test.mjs.
//
// Run: node tests/unit/section-search.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SEARCH_LINE, isDockCollapsedPath, lineLeavingSection, sectionSearchLine, sectionSearchType,
} from '../../src/utils/section-search.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')

describe('the section -> search type map', () => {
  it('docs, calendar and notes, in any locale and below', () => {
    for (const p of ['/docs', '/docs/abc', '/workspace/docs', '/workspace/docs/x/y', '/sv/docs', '/fi/workspace/docs?d=1']) {
      assert.equal(sectionSearchType(p), 'doc', p)
    }
    for (const p of ['/calendar', '/calendar?d=2026-11-06&event=e1', '/bg/calendar']) assert.equal(sectionSearchType(p), 'calendar', p)
    for (const p of ['/notes', '/notes/', '/sv/notes', '/notes?note=n1']) assert.equal(sectionSearchType(p), 'notes', p)
  })
  it('CONTROL: every other section has no type', () => {
    for (const p of ['/', '/lobby', '/channel/general', '/issues', '/search', '/docsx', '/workspace', '/calendars', '/notesx', '/public-calendar', '/events', '/t/abc']) {
      assert.equal(sectionSearchType(p), '', p)
    }
  })
})

describe('the line the Omnibox opens with', () => {
  it('docs prefill the hub type token; the others keep the plain line', () => {
    assert.equal(SEARCH_LINE, '/search ')
    assert.equal(sectionSearchLine('doc'), '/search type:doc ')
    for (const t of ['', 'calendar', 'notes', 'x']) assert.equal(sectionSearchLine(t), '/search ')
  })
})

describe('the collapsed phone dock (owner msg 1497d676)', () => {
  it('docs and notes collapse, as the docs reading view does', () => {
    for (const p of ['/docs', '/workspace/docs', '/notes', '/fi/notes']) assert.equal(isDockCollapsedPath(p), true, p)
  })
  it('CONTROL: calendar and every other section keep the dock', () => {
    for (const p of ['/calendar', '/', '/channel/general', '/issues', '/search']) assert.equal(isDockCollapsedPath(p), false, p)
  })
})

describe('leaving a section puts the Omnibox back to normal (owner msg acf9d324)', () => {
  it('a line that is only the docs prefill is emptied', () => {
    assert.equal(lineLeavingSection('/search type:doc ', 'doc'), '')
    assert.equal(lineLeavingSection('/search type:doc', 'doc'), '')
  })
  it('CONTROL: a typed query, another line or a section without a prefill stays', () => {
    assert.equal(lineLeavingSection('/search type:doc plan', 'doc'), '/search type:doc plan')
    assert.equal(lineLeavingSection('hello', 'doc'), 'hello')
    assert.equal(lineLeavingSection('/search ', 'calendar'), '/search ')
    assert.equal(lineLeavingSection('/search type:doc ', ''), '/search type:doc ')
  })
})

describe('the wiring reads the one map', () => {
  it('the omnibox store opens the section search: calendar ask, notes filter, else the Omnibox line', () => {
    const s = read('stores/omnibox.ts')
    assert.match(s, /from '~\/utils\/section-search\.mjs'/)
    assert.match(s, /function openSectionSearch\(path: string\)/)
    assert.match(s, /calendarSearchAsk\.value\+\+/)
    assert.match(s, /querySelector<HTMLInputElement>\(NOTES_FILTER_SELECTOR\)/)
    assert.match(s, /openSearch\(sectionSearchLine\(type\)\)/)
  })
  it('the layout collapses on the map and its button opens the section search', () => {
    const s = read('layouts/default.vue')
    assert.match(s, /isDockCollapsedPath\(route\.path\)/)
    assert.match(s, /@click="omnibox\.openSectionSearch\(route\.path\)"/)
    assert.doesNotMatch(s, /isDocsReadingPath/)
  })
  it('the composer collapses on the map, opens on the asked line and clears a left prefill', () => {
    const s = read('components/MessageComposer.vue')
    assert.match(s, /isDockCollapsedPath\(route\.path\)/)
    assert.match(s, /const line = omniboxTargets\.searchLine/)
    assert.match(s, /lineLeavingSection\(text\.value, left\)/)
  })
  it('the top bar button opens the section own search, else its line', () => {
    const s = read('components/TopBar.vue')
    assert.match(s, /omnibox\.openOwnSearch\(type\)/)
    assert.match(s, /setText\(sectionSearchLine\(type\)\)/)
  })
  it('SPL-4905: the top bar button also shows on a desktop with the box at the top, on a section with a type', () => {
    const s = read('components/TopBar.vue')
    assert.match(s, /v-if="barSearch"/)
    assert.match(s, /const barSearch = computed\(\(\) => atBottom\.value \|\| Boolean\(omnibox\.archivedTopic\) \|\| \(!phone\.value && sectionSearchType\(route\.path\) !== ''\)\)/)
  })
  it('SPL-4905: an operator picked outside search mode starts the section line', () => {
    const s = read('composables/useComposerSyntax.ts')
    assert.match(s, /\$\{sectionSearchLine\(sectionSearchType\(route\.path\)\)\}\$\{op\}/)
  })
  it('the desktop calendar reuses the phone calendar search, no new search UI', () => {
    const s = read('pages/calendar.vue')
    assert.match(s, /import\('~\/components\/CalendarPhoneSearch\.vue'\)/)
    assert.match(s, /omnibox\.calendarSearchAsk/)
  })
})
