// Owner HUM-10 (t1 894678f1, ERR-CLIENT-20261007-185950-2F39): a reply to a
// 10-03 post by c-002@<retired box> read "Not sent - that agent is no longer
// active". The hub now posts such a reply to the topic (or to the id's live
// box) and says so in the ack (014 wui-dispatch §3.2). The reader gets a
// small note for the topic case, never the red error.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { sendFallbackNote } from '../../src/utils/send-failure.mjs'
import { rowFromAck } from '../../src/utils/channel-feed.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const ack = { type: 'ack', msg_id: 'm1', task_id: 't1', cursor: 'c', received_at: '2026-10-07T19:00:00Z' }

describe('a reply to a retired agent seat', () => {
  it('a topic fallback earns the note, naming the retired address', () => {
    assert.deepEqual(sendFallbackNote({ ...ack, fallback: 'topic', retired: 'c-002@box-old' }),
      { key: 'composer.sent_to_topic_retired', params: { retired: 'c-002@box-old' } })
  })

  it('a plain ack, a box fallback and junk earn none', () => {
    assert.equal(sendFallbackNote(ack), null)
    assert.equal(sendFallbackNote({ ...ack, fallback: 'box', retired: 'c-002@box-old', to_box: 'box-new' }), null)
    assert.equal(sendFallbackNote({ ...ack, fallback: 'topic' }), null)
    assert.equal(sendFallbackNote(null), null)
    assert.equal(sendFallbackNote('ack'), null)
  })

  it('the row built from a topic-fallback ack is addressed to the whole topic', () => {
    const frame = { task_id: 't1', to: 'c-002', to_box: 'box-old', kind: 'note', body: 'still on it?', is_parent: 0 }
    assert.equal(rowFromAck({ ...ack, fallback: 'topic', retired: 'c-002@box-old' }, frame).to, '@channel')
    assert.equal(rowFromAck(ack, frame).to, 'c-002')
  })

  it('every locale has the note, with the {retired} placeholder', () => {
    const dir = join(WUI, 'i18n/locales')
    for (const f of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const m = JSON.parse(readFileSync(join(dir, f + '.json'), 'utf8')).composer.sent_to_topic_retired
      assert.ok(typeof m === 'string' && m.includes('{retired}'), f)
    }
  })

  it('both send stores hand the ack to the note, and TopBar shows it as a status, not an error', () => {
    assert.match(src('src/stores/channel.ts'), /sendNote\.value = sendFallbackNote\(ack\)/)
    assert.match(src('src/stores/live.ts'), /sendNote = sendFallbackNote\(ack\)/)
    const bar = src('src/components/TopBar.vue')
    assert.match(bar, /data-test="omnibox-send-note"/)
    assert.match(bar, /role="status"/)
  })
})
