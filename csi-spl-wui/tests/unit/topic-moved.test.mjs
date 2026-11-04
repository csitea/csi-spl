// Spec 169 row T7h (SPL-4781): which `moved_to` link the /t/ page follows
// (src/utils/topic-moved.mjs). The hub's link is https://<DST_HOST>/t/<uuid>.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { MOVED_HOP, movedTopicTarget } from '../../src/utils/topic-moved.mjs'
import { createSpoolClient } from '../../src/utils/spool-client.mjs'

const ID = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const HERE = 'https://src.example.com'
const SITE = 'https://example.com'

describe('movedTopicTarget', () => {
  it('follows the hub link to the topic in another workspace', () => {
    assert.deepEqual(movedTopicTarget(`https://dst.example.com/t/${ID}`, HERE, SITE),
      { href: `https://dst.example.com/t/${ID}${MOVED_HOP}`, path: `/t/${ID}`, sameOrigin: false })
    assert.equal(movedTopicTarget(`https://example.com/t/${ID}`, HERE, SITE)?.sameOrigin, false)
  })
  it('R7 N1: follows another origin only on a workspace host of this env', () => {
    for (const bad of [
      `https://evil.test/t/${ID}`,
      `https://dst.example.com.evil.test/t/${ID}`,
      `https://a.b.example.com/t/${ID}`,
      `https://api.example.com/t/${ID}`,
      `https://dst.example.com:8443/t/${ID}`,
    ]) assert.equal(movedTopicTarget(bad, HERE, SITE), null, bad)
    assert.equal(movedTopicTarget(`https://dst.example.com/t/${ID}`, HERE, ''), null, 'no siteUrl: no other origin')
  })
  it('follows a link on this origin, relative or absolute', () => {
    assert.equal(movedTopicTarget(`/t/${ID}`, 'http://127.0.0.1:3000', '')?.sameOrigin, true)
    assert.equal(movedTopicTarget(`http://127.0.0.1:3000/t/${ID}`, 'http://127.0.0.1:3000', '')?.path, `/t/${ID}`)
  })
  it('has nothing to follow on an expired redirect (no moved_to)', () => {
    assert.equal(movedTopicTarget(undefined, HERE, SITE), null)
    assert.equal(movedTopicTarget('', HERE, SITE), null)
    assert.equal(movedTopicTarget(42, HERE, SITE), null)
  })
  it('refuses anything that is not a topic link over https', () => {
    for (const bad of [
      `http://dst.example.com/t/${ID}`,
      `javascript:alert(1)//t/${ID}`,
      `https://dst.example.com/channel/general`,
      `https://dst.example.com/t/${ID}?channel=general`,
      `https://dst.example.com/t/${ID}#x`,
      `https://dst.example.com/t/not-a-uuid`,
      `https://u:p@dst.example.com/t/${ID}`,
      `//evil.example.com/t/${ID}x`,
    ]) assert.equal(movedTopicTarget(bad, HERE, SITE), null, bad)
  })
})

/* the hub's 404 answer of a topic read, as channel_move.go topicMovedAnswer writes it */
function hubAnswering(status, body) {
  return async () => ({ ok: false, status, headers: { get: () => 'application/json' }, json: async () => body })
}

describe('getTopic of a moved topic (live)', () => {
  it('keeps the hub moved_to on the empty page', async () => {
    const link = `https://dst.example.com/t/${ID}`
    const c = createSpoolClient({ mock: false, fetchFn: hubAnswering(404, {
      error: 'topic_moved', detail: `topic moved: tenant=dst link=${link}`, moved_to: link, moved_to_tenant: 'dst' }) })
    const page = await c.getTopic(ID, { limit: 1 })
    assert.deepEqual(page, { task_id: ID, messages: [], next: null, moved_to: link })
  })
  it('an expired redirect and a plain 404 stay the empty page, with no link', async () => {
    for (const body of [{ error: 'topic_moved', detail: 'this topic is gone from this workspace' }, { error: 'not_found' },
      /* R7 N2: a moved_to on any other 404 is not a move */
      { error: 'not_found', moved_to: `https://dst.example.com/t/${ID}` }]) {
      const c = createSpoolClient({ mock: false, fetchFn: hubAnswering(404, body) })
      assert.deepEqual(await c.getTopic(ID, { limit: 1 }), { task_id: ID, messages: [], next: null })
    }
  })
})
