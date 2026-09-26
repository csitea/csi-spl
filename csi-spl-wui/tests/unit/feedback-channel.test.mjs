import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { feedbackChannelCopy, feedbackChannelFromPath, isFeedbackChannel } from '../../src/utils/feedback-channel.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

describe('#feedback locale name and description', () => {
  it('recognises the slug with or without a hash', () => {
    assert.equal(isFeedbackChannel('feedback'), true)
    assert.equal(isFeedbackChannel('#Feedback'), true)
    assert.equal(isFeedbackChannel(' lobby '), false)
    assert.equal(isFeedbackChannel(''), false)
  })

  it('uses the locale copy, and a stored description wins', () => {
    const copy = { name: 'palaute', description: 'Merkitse omistaja.' }
    assert.deepEqual(feedbackChannelCopy('feedback', copy, ''), {
      name: 'palaute',
      description: 'Merkitse omistaja.',
    })
    assert.deepEqual(feedbackChannelCopy('#feedback', copy, '  what we ship  '), {
      name: 'palaute',
      description: 'what we ship',
    })
    assert.equal(feedbackChannelCopy('lobby', copy, ''), null)
    assert.equal(feedbackChannelCopy('feedback', null, '').name, 'feedback')
  })


  it('reads the channel out of a locale-prefixed path', () => {
    assert.equal(feedbackChannelFromPath('/channel/feedback'), 'feedback')
    assert.equal(feedbackChannelFromPath('/fi/channel/feedback'), 'feedback')
    assert.equal(feedbackChannelFromPath('/channel/lobby'), 'lobby')
    assert.equal(feedbackChannelFromPath('/lobby'), '')
    assert.equal(isFeedbackChannel(feedbackChannelFromPath('/fi/channel/feedback')), true)
  })

  it('the sidebar, the channel header and the @ picker use the helpers', () => {
    const sidebar = src('src/components/ChannelSidebar.vue')
    const page = src('src/pages/channel/[name].vue')
    /* SPL-985: the @ picker moved out of MessageComposer into the shared pair */
    const composer = src('src/composables/useMentionPicker.ts') + src('src/components/MentionList.vue')
    assert.match(sidebar, /feedbackChannelCopy/)
    assert.match(sidebar, /shownChannels/)
    assert.match(page, /feedbackChannelCopy/)
    assert.match(page, /titleName/)
    assert.match(composer, /isFeedbackChannel/)
    assert.match(composer, /owners: roster\.owners/)
    assert.match(composer, /ownersFirst: inFeedback\.value/)
    assert.match(composer, /feedbackChannelFromPath/)
    assert.match(composer, /composer\.biz_owner/)
  })
})
