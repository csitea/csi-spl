// SPL-4450 (row 1 of SPL-4422, signed-out half): a signed-out /roadmap,
// /help or /docs logged `401 GET /v1/view/roster`, because the manual-status
// store read the roster as soon as it was created. It reads it only once the
// session is 'in' (as useHumanNames), and again when it turns 'in'.
// Run: node --test tests/unit/human-status-signed-out.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { nextTick, ref, watch } from 'vue'
import { whenSignedIn } from '../../src/utils/when-signed-in.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')

/** a mock api counting its roster reads, and the gate wired to it */
function gated(start) {
  const state = ref(start)
  const api = { calls: 0, rosterView() { api.calls++; return Promise.resolve({ humans: [] }) } }
  whenSignedIn(() => state.value, watch, () => api.rosterView())
  return { state, api }
}

describe('the status store reads the roster only signed in', () => {
  for (const s of ['loading', 'unknown', 'out']) {
    it(`session '${s}': no roster read`, async () => {
      const { api } = gated(s)
      await nextTick()
      assert.equal(api.calls, 0)
    })
  }
  it("session 'in' at creation: one read", async () => {
    const { api } = gated('in')
    await nextTick()
    assert.equal(api.calls, 1)
  })
  it("'loading' then 'out' then 'in': one read, when it turns 'in'", async () => {
    const { state, api } = gated('loading')
    state.value = 'out'
    await nextTick()
    assert.equal(api.calls, 0)
    state.value = 'in'
    await nextTick()
    assert.equal(api.calls, 1)
  })
  it("signed out, then in again: read again; staying 'in' never re-reads", async () => {
    const { state, api } = gated('in')
    await nextTick()
    state.value = 'out'
    await nextTick()
    state.value = 'in'
    await nextTick()
    assert.equal(api.calls, 2)
  })
  it('the store wires its roster read through the gate, never at creation', () => {
    const store = readFileSync(join(WUI, 'src/stores/human-status.ts'), 'utf8')
    assert.match(store, /whenSignedIn\(\(\) => session\.state, watch, \(\) => api\.rosterView\(\)/)
    assert.doesNotMatch(store, /^\s*void api\.rosterView\(\)/m)
  })
})
