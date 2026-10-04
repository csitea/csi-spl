// Topic e1f8f797: internal link previews. Which links of a body name a topic
// or a message of THIS workspace, the per-user switch (pinned equal to the
// hub's auth.ViewPrefs and rdb 0120), the batched lookup the lazy cards use,
// and the mock answer (the hub's text rule).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LINK_PREVIEWS, PREVIEWS_PER_BODY, parseLinkPreviews, previewRefs, previewTarget } from '../../src/utils/link-preview.mjs'
import { PREVIEW_ASK_MAX, PREVIEW_TTL_MS, createPreviewLookup, mockPreviews, previewText } from '../../src/utils/link-preview-lookup.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const O = 'https://acme.example.com'
const T = 'aaaaaaaa-0000-4000-8000-00000000000a'
const M = 'bbbbbbbb-0000-4000-8000-00000000000b'

describe('the link_previews setting', () => {
  it('is on | off in the hub (auth.ViewPrefs) and rdb 0120, on first; anything else reads on', () => {
    assert.deepEqual([...LINK_PREVIEWS], ['on', 'off'])
    assert.match(read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go'), /PrefLinkPreviews: +\{"on", "off"\}/)
    assert.match(read('../csi-spl-rdb/src/sql/postgres/spool-hub/0120_human_link_previews.sql'), /link_previews IN \('on','off'\)/)
    for (const raw of [null, undefined, '', 'On', 'no', false]) assert.equal(parseLinkPreviews(raw), 'on')
    assert.equal(parseLinkPreviews('off'), 'off')
  })
  it('every locale names the setting and the two card kinds', () => {
    for (const code of ['en', 'fi', 'sv', 'bg', 'ru', 'he']) {
      const j = JSON.parse(read(`i18n/locales/${code}.json`))
      assert.ok(j.settings.link_previews.label && j.settings.link_previews.hint, code)
      assert.ok(j.link_preview.topic && j.link_preview.message, code)
    }
  })
})

describe('previewTarget', () => {
  it('names a topic or a message by its address on this origin', () => {
    assert.equal(previewTarget(`/t/${T}`, O), T)
    assert.equal(previewTarget(`/fi/t/${T.toUpperCase()}`, O), T)
    assert.equal(previewTarget(`/t/${T}#${M}`, O), M)
    assert.equal(previewTarget(`/m/${M}`, O), M)
    assert.equal(previewTarget(`${O}/channel/lobby?topic=${T}`, O), T)
    assert.equal(previewTarget(`${O}/dm/CLE-07?topic=${T}#${M}`, O), M)
    assert.equal(previewTarget(`?topic=${T}`, O), T)
  })
  it('anything else is no object: another host, another tenant, a page, a bad id', () => {
    for (const href of [
      `https://other.example.net/t/${T}`,
      `https://beta.example.com/t/${T}`,
      `${O}/channel/lobby`,
      `${O}/t/not-a-uuid`,
      `${O}/issues?issue=ABC-12`,
      `javascript:alert(1)//?topic=${T}`,
      `//evil.example/t/${T}`,
    ]) assert.equal(previewTarget(href, O), null, href)
    assert.equal(previewTarget(`/t/${T}`, ''), null, 'no page origin, nothing is ours')
  })
})

describe('previewRefs', () => {
  it('reads markdown and bare links in body order, each object once, at most three', () => {
    const body = [
      `see [the fix](/t/${T}) and ${O}/m/${M}.`,
      `again ${O}/t/${T}`,
      `and ${O}/t/cccccccc-0000-4000-8000-00000000000c, ${O}/t/dddddddd-0000-4000-8000-00000000000d`,
    ].join('\n')
    const refs = previewRefs(body, O)
    assert.equal(PREVIEWS_PER_BODY, 3)
    assert.deepEqual(refs.map((r) => r.id), [T, M, 'cccccccc-0000-4000-8000-00000000000c'])
    assert.equal(refs[0].href, `/t/${T}`)
    assert.equal(refs[1].href, `${O}/m/${M}`, 'the trailing full stop is not part of the link')
  })
  it('a link in code, an id as text and an external link are not previewed', () => {
    const body = ['```', `${O}/t/${T}`, '```', `\`${O}/m/${M}\``, `topic ${T}`, 'https://example.org/t/x'].join('\n')
    assert.deepEqual(previewRefs(body, O), [])
    assert.deepEqual(previewRefs(null, O), [])
  })
})

describe('createPreviewLookup', () => {
  it('asks the ids of every body noted in one tick in one call, then answers from the cache', async () => {
    const calls = []
    let flushes = []
    let clock = 0
    let changes = 0
    const lk = createPreviewLookup({
      fetchPreviews: async (ids) => { calls.push(ids); return { previews: ids.filter((i) => i !== M).map((id) => ({ id, kind: 'topic', title: 't' + id.slice(0, 2) })) } },
      onChange: () => { changes += 1 },
      schedule: (fn) => flushes.push(fn),
      now: () => clock,
    })
    lk.want([T])
    lk.want([M, T])
    assert.equal(flushes.length, 1, 'one flush armed per tick')
    assert.equal(lk.get(T), null, 'nothing before the answer')
    flushes.shift()()
    await new Promise((r) => setImmediate(r))
    assert.deepEqual(calls, [[T, M]])
    assert.equal(changes, 1)
    assert.equal(lk.get(T.toUpperCase()).title, 'taa')
    assert.equal(lk.get(M), null, 'left out by the hub: a plain link')
    lk.want([T, M])
    assert.equal(flushes.length, 0, 'a repaint asks nothing')
    clock = PREVIEW_TTL_MS + 1
    lk.want([T])
    assert.equal(flushes.length, 1, 'asked again after the TTL')
  })
  it('splits a large batch at the hub limit and keeps a failure as none', async () => {
    const calls = []
    const lk = createPreviewLookup({
      fetchPreviews: async (ids) => { calls.push(ids.length); throw new Error('down') },
      onChange: () => {},
      schedule: (fn) => fn(),
    })
    const ids = Array.from({ length: PREVIEW_ASK_MAX + 5 }, (_, i) => `${String(i).padStart(8, '0')}-0000-4000-8000-000000000000`)
    lk.want(ids)
    await new Promise((r) => setImmediate(r))
    assert.deepEqual(calls, [PREVIEW_ASK_MAX, 5])
    assert.equal(lk.get(ids[0]), null)
  })
})

describe('the card text (the hub rule) and the mock answer', () => {
  it('title = first non-empty line cut at 100, excerpt = the next three, fences skipped', () => {
    const long = 'é'.repeat(150)
    const got = previewText(`\n  ${long}  \n\nline a\n\`\`\`go\nline b\n\`\`\`\nline c\nline d`)
    assert.equal(got.title, 'é'.repeat(99) + '…')
    assert.equal(got.excerpt, 'line a\nline b\nline c')
  })
  it('a topic prints its first message; a reply prints its own body under the topic title', () => {
    const rows = [
      { msg_id: M, task_id: 'r0000000-0000-4000-8000-000000000000', parent_task_id: T, channel: 'lobby', from: 'HUM-2', body: 'the reply', ts: '2026-10-04T10:01:00Z' },
      { msg_id: 'c0000000-0000-4000-8000-000000000000', task_id: T, channel: 'lobby', from: 'HUM-1', body: 'The plan\nstep one\nstep two', ts: '2026-10-04T10:00:00Z' },
    ]
    const { previews } = mockPreviews(rows, [T, M, 'ffffffff-0000-4000-8000-00000000000f'])
    assert.equal(previews.length, 2)
    assert.deepEqual([previews[0].kind, previews[0].title, previews[0].excerpt, previews[0].from], ['topic', 'The plan', 'step one\nstep two', 'HUM-1'])
    assert.deepEqual([previews[1].kind, previews[1].title, previews[1].excerpt, previews[1].task_id], ['message', 'The plan', 'the reply', T])
  })
})
