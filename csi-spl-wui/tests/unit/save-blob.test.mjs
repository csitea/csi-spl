// saveBlob (CLE-77915, refactor item 15): one way to hand the browser a file.
// Run: node tests/unit/save-blob.test.mjs
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { saveBlob, OBJECT_URL_REVOKE_MS } from '../../src/utils/save-blob.mjs'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '../../src')

function fakeEnv() {
  const log = []
  const a = { click: () => log.push('click'), remove: () => log.push('remove') }
  return {
    log, a,
    doc: { createElement: (t) => (log.push('create ' + t), a), body: { appendChild: () => log.push('append') } },
    url: { createObjectURL: () => (log.push('url'), 'blob:x'), revokeObjectURL: (u) => log.push('revoke ' + u) },
    later: (fn, ms) => log.push('later ' + ms) && (a.revoke = fn),
  }
}

test('the file is offered under its name, clicked, and its URL revoked LATER, never on the same tick', () => {
  const env = fakeEnv()
  saveBlob(new Blob(['k']), 'spool-key.pem', env)
  assert.equal(env.a.download, 'spool-key.pem')
  assert.equal(env.a.href, 'blob:x')
  assert.equal(env.a.rel, 'noopener')
  assert.deepEqual(env.log, ['url', 'create a', 'append', 'click', 'remove', `later ${OBJECT_URL_REVOKE_MS}`])
  assert.ok(OBJECT_URL_REVOKE_MS >= 1000)
  env.a.revoke()
  assert.equal(env.log.at(-1), 'revoke blob:x')
})

test('no component builds its own download anchor any more', () => {
  for (const f of ['components/KeysSetting.vue', 'components/CheckoutKeyReveal.vue', 'components/FileAttachment.vue']) {
    const src = readFileSync(join(SRC, f), 'utf8')
    assert.match(src, /saveBlob\(/, f)
    assert.doesNotMatch(src, /createObjectURL|revokeObjectURL/, f)
  }
})
