// Ids in a message body become links to the topic, the DM, or the message.
// Controls: a hex string that is not an id, an id in code, an unknown id.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { parseBody, markdownSource } from '../../src/utils/code-blocks.mjs'
import {
  indexCatalog,
  linkifyBlocks,
  linkifyMarkdown,
  linkifyText,
  resetIdCatalogProvider,
  setIdCatalogProvider,
} from '../../src/utils/id-links.mjs'

const TOPIC = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
const OTHER = 'abababab-abab-4bab-8bab-abababababab'
const MSG = '33333333-3333-4333-8333-333333333333'
const DM_TOPIC = '99999999-9999-4999-8999-999999999999'
const DM_MSG = '77777777-7777-4777-8777-777777777777'
const DM_REPLY = '7a7a7a7a-7a7a-4a7a-8a7a-7a7a7a7a7a7a'
const UNKNOWN = '00000000-0000-4000-8000-000000000099'

const channelMsg = {
  msg_id: MSG,
  task_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
  parent_task_id: TOPIC,
  channel: 'lobby',
  from: 'CLE-07',
  from_box: 'box-a',
  to: 'HUM-1',
  to_box: 'box-wui',
}
const dmRoot = {
  msg_id: DM_MSG,
  task_id: DM_TOPIC,
  channel: null,
  from: 'HUM-1',
  from_box: 'box-wui',
  to: 'GRK-03',
  to_box: 'box-a',
}
const dmReply = {
  msg_id: DM_REPLY,
  task_id: DM_MSG,
  parent_task_id: DM_TOPIC,
  channel: null,
  from: 'GRK-03',
  from_box: 'box-a',
  to: 'HUM-1',
  to_box: 'box-wui',
}

function catalog() {
  return indexCatalog({
    self: 'HUM-1',
    topics: [{ task_id: OTHER, channel: 'lobby', participants: ['HUM-1@box-wui'] }],
    messages: [channelMsg, dmRoot, dmReply],
  })
}

const link = (text, href) => ({ type: 'link', text, href })
const txt = (text) => ({ type: 'text', text })

describe('id links', () => {
  const index = catalog()

  it('a full topic uuid opens that topic', () => {
    assert.deepEqual(linkifyText(`topic ${TOPIC} please`, index), [
      txt('topic '),
      link(TOPIC, `/t/${TOPIC}`),
      txt(' please'),
    ])
  })

  it('a unique 8-hex topic prefix opens that topic', () => {
    assert.deepEqual(linkifyText('see bbbbbbbb now', index), [
      txt('see '),
      link('bbbbbbbb', `/t/${TOPIC}`),
      txt(' now'),
    ])
  })

  it('a topic prefix shared by two topics stays text', () => {
    const ambiguous = indexCatalog({
      topics: [
        { task_id: 'abcdef01-0000-4000-8000-000000000001', channel: 'lobby' },
        { task_id: 'abcdef01-0000-4000-8000-000000000002', channel: 'lobby' },
      ],
    })
    assert.deepEqual(linkifyText('ref abcdef01 end', ambiguous), [txt('ref abcdef01 end')])
  })

  it('a channel message id opens its topic, scrolled to the message', () => {
    const href = `/channel/lobby?topic=${TOPIC}#${MSG}`
    assert.deepEqual(linkifyText(`msg ${MSG}.`, index), [
      txt('msg '),
      link(MSG, href),
      txt('.'),
    ])
    assert.deepEqual(linkifyText('short 33333333', index), [
      txt('short '),
      link('33333333', href),
    ])
  })

  it('a DM topic opens the direct message with that topic', () => {
    const href = `/dm/GRK-03%40box-a?topic=${DM_TOPIC}`
    assert.deepEqual(linkifyText(DM_TOPIC, index), [link(DM_TOPIC, href)])
    assert.deepEqual(linkifyText('99999999', index), [link('99999999', href)])
  })

  it('a DM message opens the direct message, scrolled to it', () => {
    const href = `/dm/GRK-03%40box-a?topic=${DM_TOPIC}#${DM_REPLY}`
    assert.deepEqual(linkifyText(DM_REPLY, index), [link(DM_REPLY, href)])
  })

  it('a DM topic known only from the topic list still opens the DM', () => {
    const only = indexCatalog({
      self: 'HUM-1',
      topics: [{
        task_id: DM_TOPIC,
        channel: null,
        participants: ['HUM-1@box-wui', 'GRK-03@box-a'],
      }],
    })
    assert.deepEqual(linkifyText(DM_TOPIC, only), [
      link(DM_TOPIC, `/dm/GRK-03%40box-a?topic=${DM_TOPIC}`),
    ])
  })

  it('an unknown uuid stays text', () => {
    assert.deepEqual(linkifyText(`missing ${UNKNOWN}`, index), [txt(`missing ${UNKNOWN}`)])
  })

  it('a hex string that is not an id stays text', () => {
    assert.deepEqual(linkifyText('code deadbeef and cafe', index), [txt('code deadbeef and cafe')])
    const sha = 'a'.repeat(64)
    assert.deepEqual(linkifyText(sha, index), [txt(sha)])
    assert.deepEqual(linkifyText('bbbbbbb', index), [txt('bbbbbbb')])
    assert.deepEqual(linkifyText('bbbbbbbbb', index), [txt('bbbbbbbbb')])
  })

  it('the letters of the id are kept as written', () => {
    const upper = TOPIC.toUpperCase()
    assert.deepEqual(linkifyText(upper, index), [link(upper, `/t/${TOPIC}`)])
  })

  it('an id in inline code or a fence stays text', () => {
    const inline = linkifyBlocks(parseBody(`run \`${TOPIC}\` now`), index)
    assert.deepEqual(inline[0].parts[1], { type: 'inline', text: TOPIC })
    assert.equal(inline[0].parts.some((p) => p.type === 'link'), false)

    const fence = linkifyBlocks(parseBody('```\n' + TOPIC + '\n```'), index)
    assert.equal(fence[0].type, 'code')
    assert.equal(fence[0].text, TOPIC)
    assert.equal(JSON.stringify(fence).includes('"type":"link"'), false)
  })

  it('an id inside an existing link stays that link', () => {
    const href = `https://example.com/${TOPIC}`
    const blocks = linkifyBlocks([{
      type: 'para',
      parts: [{ type: 'link', text: href, href }],
    }], index)
    assert.deepEqual(blocks[0].parts, [{ type: 'link', text: href, href }])
    const md = `[go](https://example.com/${TOPIC}) and https://example.com/${OTHER}`
    assert.equal(linkifyMarkdown(md, index), md)
  })

  it('an empty catalog changes nothing', () => {
    const none = indexCatalog({})
    assert.equal(none.empty, true)
    const blocks = parseBody(`topic ${TOPIC}`)
    assert.equal(linkifyBlocks(blocks, none), blocks)
  })

  it('parseBody and markdownSource use the registered catalog, and skip code', () => {
    setIdCatalogProvider(() => index)
    try {
      const blocks = parseBody(`topic ${TOPIC} and \`${TOPIC}\``)
      const parts = blocks[0].parts
      assert.equal(parts.some((p) => p.type === 'link' && p.href === `/t/${TOPIC}`), true)
      assert.equal(parts.some((p) => p.type === 'inline' && p.text === TOPIC), true)

      const md = markdownSource(`# Note\n\nsee ${TOPIC}\n\n\`${MSG}\`\n`)
      assert.match(md, new RegExp(`\\[${TOPIC}\\]\\(/t/${TOPIC}\\)`))
      assert.match(md, new RegExp('`' + MSG + '`'))
      assert.equal(md.includes(`[${MSG}](`), false)
    } finally {
      resetIdCatalogProvider()
    }
  })
})
