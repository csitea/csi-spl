// /channel and /dm on a fresh page load (deep link, refresh): a member's
// reads must flip the view door to the session cookie on the first 401, as
// the lobby does (010 FR-009, live-follow withSessionRetry). Measured on dev
// 8081310 before this: /channel/<name> showed "spool 401 view_door" for a
// signed-in member until another page had flipped the door.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')
const read = (p) => readFileSync(join(SRC, p), 'utf8')

describe('channel views read through the session door', () => {
  for (const [file, calls] of [
    ['stores/channel.ts', ['listChannels', 'listMessages', 'createChannel']],
    ['stores/roster.ts', ['listRoster']],
    ['components/ThreadPane.vue', ['getThread']],
  ]) {
    it(`${file}: every ${calls.join('/')} call is wrapped in withSessionRetry`, () => {
      const src = read(file)
      for (const c of calls) {
        const all = src.match(new RegExp(`api\\.${c}\\(`, 'g')) || []
        const wrapped = src.match(new RegExp(`withSessionRetry\\(api, \\(\\) => api\\.${c}\\(`, 'g')) || []
        assert.ok(all.length > 0, `${c} is called`)
        assert.equal(wrapped.length, all.length, `${c}: ${all.length - wrapped.length} unwrapped call(s)`)
      }
    })
  }
})
