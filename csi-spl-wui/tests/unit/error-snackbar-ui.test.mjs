// ErrorSnackbar.vue + pages/events.vue + the default-layout mount
// (topic 4335f075). Source-read, same shape as error-journal.test.mjs.
//
// Run: node tests/unit/error-snackbar-ui.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('ErrorSnackbar.vue', () => {
  const src = read('src/components/common/ErrorSnackbar.vue')

  it('renders createSnackbarQueue bound to the one journal', () => {
    assert.match(src, /createSnackbarQueue\(/)
    assert.match(src, /bindSnackbarToJournal\(/)
    assert.match(src, /SNACKBAR_TICK_MS/)
    assert.match(src, /getErrors/)
    assert.match(src, /subscribeErrors/)
    assert.match(src, /from '~\/utils\/error-snackbar\.mjs'/)
  })

  it('slides in from the top and drops the slide when motion is reduced', () => {
    assert.match(src, /@keyframes error-snackbar-in/)
    assert.match(src, /translateY\(-100%\)/)
    assert.match(src, /prefers-reduced-motion:\s*reduce/)
    assert.match(src, /animation:\s*none/)
  })

  it('is about the top-bar height, rem type, one focus-ring token', () => {
    assert.match(src, /min-height:\s*var\(--top-bar-h\)/)
    assert.match(src, /z-index:\s*var\(--z-snackbar\)/)
    assert.match(src, /font-size:\s*0\.875rem/)
    assert.match(src, /outline:\s*var\(--focus-ring-w\)\s+solid\s+var\(--focus-ring\)/)
  })

  it('each row is role=alert with message, error id, dismiss and xN count', () => {
    assert.match(src, /role="alert"/)
    assert.match(src, /item\.text/)
    assert.match(src, /item\.errorId/)
    assert.match(src, /t\('snackbar\.dismiss'\)/)
    assert.match(src, /t\('snackbar\.region'\)/)
    assert.match(src, /t\('snackbar\.repeat'/)
    assert.match(src, /queue\.dismiss\(/)
    assert.match(src, /queue\.hold\(/)
  })
})

describe('layouts/default.vue mounts the snackbar next to DebugPanel', () => {
  const src = read('src/layouts/default.vue')
  it('imports ErrorSnackbar and renders it next to DebugPanel', () => {
    assert.match(src, /import ErrorSnackbar from '@\/components\/common\/ErrorSnackbar\.vue'/)
    const snack = src.indexOf('<ErrorSnackbar')
    const debug = src.indexOf('<DebugPanel')
    assert.ok(snack > 0 && debug > snack)
    const only = src.indexOf('<ClientOnly>')
    assert.ok(only > 0 && snack > only)
  })
})

describe('pages/events.vue', () => {
  const src = read('src/pages/events.vue')

  it('lists and clears through createEventsClient', () => {
    assert.match(src, /createEventsClient\(/)
    assert.match(src, /from '~\/utils\/event-log\.mjs'/)
    assert.match(src, /client\.list\(/)
    assert.match(src, /client\.clear\(/)
    assert.match(src, /eventsErrorKey\(/)
  })

  it('uses the catalogue keys and shows signed-out without posting', () => {
    for (const k of [
      'events.title', 'events.empty', 'events.clear', 'events.load_more',
      'events.col_when', 'events.col_id', 'events.col_source', 'events.col_status',
      'events.col_message', 'events.col_route', 'events.signed_out', 'events.load_failed',
    ]) {
      assert.ok(src.includes(`'${k}'`) || src.includes(`"${k}"`) || src.includes(`eventsErrorKey`), k)
      if (k !== 'events.load_failed') assert.ok(src.includes(k), k)
    }
    assert.match(src, /data-test="events-signed-out"/)
    const script = src.split('<script')[1] || ''
    assert.equal(/noteError/.test(script), false)
    assert.equal(/client\.add\(/.test(script), false)
  })

  it('pages older rows with next_before', () => {
    assert.match(src, /next_before/)
    assert.match(src, /data-test="events-load-more"/)
    assert.match(src, /data-test="events-table"/)
  })
})
