// Refactor round 3, row 6: every raw fetch() in these composables and pages
// carries a timeout signal, so a hung connection ends in 'failed' instead of
// an endless spinner. This pins the budgets and that each call site passes
// `signal:` built from them.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DOC_READ_TIMEOUT_MS, DOC_WRITE_TIMEOUT_MS, REVISION_FETCH_MS, docFetchTimeoutMs,
  BOOT_READ_TIMEOUT_MS, ROSTER_READ_TIMEOUT_MS, ACCOUNT_CALL_TIMEOUT_MS,
} from '../../src/utils/fetch-timeouts.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

describe('fetch timeouts', () => {
  it('orders the budgets: write > read > 0, revision > 0', () => {
    assert.ok(DOC_READ_TIMEOUT_MS > 0)
    assert.ok(DOC_WRITE_TIMEOUT_MS > DOC_READ_TIMEOUT_MS)
    assert.ok(REVISION_FETCH_MS > 0)
  })

  it('gives the boot and roster reads a budget and a checkout / keys call no less than a doc write (refactor r4-03)', () => {
    assert.ok(BOOT_READ_TIMEOUT_MS > 0)
    assert.ok(ROSTER_READ_TIMEOUT_MS > 0)
    assert.ok(ACCOUNT_CALL_TIMEOUT_MS >= DOC_WRITE_TIMEOUT_MS)
  })

  it('gives a workspace docs GET the read budget and a PUT / DELETE the write one', () => {
    assert.equal(docFetchTimeoutMs(undefined), DOC_READ_TIMEOUT_MS)
    assert.equal(docFetchTimeoutMs('get'), DOC_READ_TIMEOUT_MS)
    assert.equal(docFetchTimeoutMs('PUT'), DOC_WRITE_TIMEOUT_MS)
    assert.equal(docFetchTimeoutMs('DELETE'), DOC_WRITE_TIMEOUT_MS)
  })

  const sites = [
    ['composables/useLive.ts', /\/v1\/wui\/revision`, \{[^}]*signal: AbortSignal\.timeout\(REVISION_FETCH_MS\)/],
    ['composables/usePaletteItems.ts', /\/v1\/docs\/tree\.json`, \{[^}]*signal: AbortSignal\.timeout\(DOC_READ_TIMEOUT_MS\)/],
    ['composables/useWorkspaceDocs.ts', /const signal = init\.signal \?\? AbortSignal\.timeout\(docFetchTimeoutMs\(init\.method\)\)\n\s*return fetch\([^\n]*\.\.\.init, headers, signal \}\)/],
    ['pages/docs.vue', /\/v1\/docs\/\$\{path\}`, \{[^}]*signal: AbortSignal\.timeout\(DOC_READ_TIMEOUT_MS\)/],
    ['pages/help/[[page]].vue', /fetch\(path, \{[^}]*signal: AbortSignal\.timeout\(DOC_READ_TIMEOUT_MS\)/],
  ]
  for (const [file, re] of sites) {
    it(`${file} passes a timeout signal to its fetch`, () => {
      const src = readFileSync(join(SRC, file), 'utf8')
      assert.match(src, re)
      assert.match(src, /from '~\/utils\/fetch-timeouts\.mjs'/)
    })
  }
})
