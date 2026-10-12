// SPL-1560 (owner HUM-10, t1 d74ecae5): an X on every attachment removes it
// from the system, at the side the Mac / Windows setting picks.
//
// These pin the client call (one DELETE /v1/attachments/{file_id}, its rows
// read back as view rows), the X's side (the shared close_buttons rule), the
// hosts that wire it, and the strings in every locale.
// Run: node tests/unit/attachment-remove.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'
import { closeButtonShown } from '../../src/utils/view-prefs.mjs'
import { ON_DEMAND_COMPONENTS } from '../../src/utils/i18n-first-screen.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

function stubFetch(routes) {
  const calls = []
  const fn = async (url, opts = {}) => {
    calls.push({ url, opts })
    const hit = routes.find(([p]) => p(url, opts))
    const [status, body] = hit ? hit[1] : [404, { error: 'not_found' }]
    return { ok: status >= 200 && status < 300, status, headers: { get: () => 'application/json' }, json: async () => body }
  }
  return { fn, calls }
}

const FILE = 'a'.repeat(64)
const KEEP = 'b'.repeat(64)
const MSG = '11111111-1111-4111-8111-111111111111'

describe('spool-client removeAttachment', () => {
  it('is ONE DELETE /v1/attachments/{file_id}, and the changed rows come back without the file', async () => {
    const { fn, calls } = stubFetch([[(u, o) => o.method === 'DELETE' && u.endsWith(`/v1/attachments/${FILE}`), [200, {
      file_id: FILE, removed: [MSG], kept: 0, blob_deleted: true,
      messages: [{
        task_id: 'T', cursor: 'c', received_at: '2026-10-12T20:00:00Z',
        env: { from_box: 'box-wui', to_box: 'box-wui', msg: { v: 1, msg_id: MSG, task_id: 'T', body: 'see',
          files: [{ mode: 'blob', kind: 'file', file_id: KEEP, sha256: KEEP, name: 'b.png' }] } },
      }],
    }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    const out = await c.removeAttachment(FILE)
    assert.equal(calls.length, 1)
    assert.equal(calls[0].opts.method, 'DELETE')
    assert.equal(out.blob_deleted, true)
    assert.deepEqual(out.removed, [MSG])
    assert.equal(out.messages[0].msg_id, MSG)
    assert.deepEqual(out.messages[0].files.map((f) => f.file_id), [KEEP])
  })

  it('carries the hub refusal token, and refuses an empty id before any call', async () => {
    const { fn, calls } = stubFetch([[() => true, [403, { error: 'not_author', detail: 'x' }]]])
    const c = createSpoolClient({ fetchFn: fn, mock: false })
    await assert.rejects(c.removeAttachment(FILE), (e) => e.token === 'not_author')
    await assert.rejects(c.removeAttachment(''), (e) => e.token === 'bad_json')
    assert.equal(calls.length, 1)
  })
})

describe('the X side follows close_buttons (Mac = left, the default; Windows = right)', () => {
  it('shows the start X for Mac and for an unset choice, the end X for Windows', () => {
    for (const pref of ['mac', null, undefined, 'bogus']) {
      assert.equal(closeButtonShown('start', pref), true, String(pref))
      assert.equal(closeButtonShown('end', pref), false, String(pref))
    }
    assert.equal(closeButtonShown('start', 'windows'), false)
    assert.equal(closeButtonShown('end', 'windows'), true)
  })

  it('AttachmentRemoveX is the shared UiCloseButton, and FileAttachment puts it at both ends', () => {
    const x = src('src/components/AttachmentRemoveX.vue')
    assert.match(x, /<UiCloseButton[\s\S]*?:side="side"/)
    assert.match(x, /<UiConfirm/, 'one click opens the destructive confirm')
    const card = src('src/components/FileAttachment.vue')
    const at = (side) => card.indexOf(`<LazyAttachmentRemoveX v-if="removable" side="${side}"`)
    assert.ok(at('start') > 0 && at('end') > at('start'), 'start before the card content, end after it')
    assert.match(card, /te\('feed\.file_remove\.label'\)/, 'mounted once its strings are merged')
  })

  it('every host of a file card wires the remove', () => {
    assert.match(src('src/components/MessageCard.vue'), /:remove="filesRemovable \? \(\) => removeFile\(f\) : undefined"/)
    assert.match(src('src/components/IssueDescription.vue'), /<FileAttachment :file="f" :remove="attach \?/)
  })

  it('its strings wait in the second catalogue', () => {
    assert.equal(ON_DEMAND_COMPONENTS['components/AttachmentRemoveX.vue'], 'idle')
  })
})

describe('feed.file_remove in every locale', () => {
  const KEYS = ['label', 'title', 'body', 'confirm', 'failed', 'not_allowed']
  const dir = join(WUI, 'i18n/locales')
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.json'))) {
    it(f, () => {
      const fr = JSON.parse(readFileSync(join(dir, f), 'utf8')).feed.file_remove
      for (const k of KEYS) assert.ok(typeof fr?.[k] === 'string' && fr[k].trim(), `${f} feed.file_remove.${k}`)
      assert.match(fr.label, /\{name\}/)
      assert.match(fr.body, /\{name\}/)
    })
  }
})
