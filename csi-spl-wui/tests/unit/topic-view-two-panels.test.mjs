// The topic page (/t/:id) used to be two panels: a Topics list and the
// thread, with the shell sidebar hidden. Owner HUM-10 (t1 e4bfddb1, msg
// a78e06c8: "Remove the whole topics view"): the list is gone, so the page is
// the thread alone and the shell's left panel (Channels) shows beside it.
// The channel page stays three panels.
// Run: node --test tests/unit/topic-view-two-panels.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

describe('the topic page is the thread alone', () => {
  const page = read('src/pages/t/[task_id].vue')
  const layout = read('src/layouts/default.vue')
  const css = read('src/assets/css/main.css')
  const channel = read('src/pages/channel/[name].vue')

  it('the page is TopicPane, with no topic list beside it', () => {
    assert.match(page, /data-test="topic-browse"/)
    assert.doesNotMatch(page, /data-test="topic-browse-list"/)
    assert.doesNotMatch(page, /topic-browse__list/)
    assert.match(page, /<TopicPane/)
    assert.doesNotMatch(page, /<LiveFeed/)
    assert.doesNotMatch(page, /<MessageCard/)
    assert.match(read('src/components/TopicPane.vue'), /<LiveFeed\s+clip\s+clip-pane="thread"\s+hold-scroll/)
  })

  it('the shell does not open a third column on /t/:id', () => {
    assert.match(layout, /data-topic-browse/)
    assert.match(layout, /topicPage\.value \? NONE : topicSection\(/)
    assert.match(layout, /v-if="section === LIVE"/)
    assert.match(layout, /v-else-if="section === CHANNEL"/)
    assert.doesNotMatch(channel, /data-topic-browse/)
  })

  it('the shell sidebar is not hidden on /t/:id: no rule takes it out of the row', () => {
    assert.doesNotMatch(css, /\[data-topic-browse="1"\] > \.sidebar/)
    assert.doesNotMatch(css, /\[data-topic-browse="1"\] > \.pane-divider/)
    assert.doesNotMatch(css, /\/\* \/t\/:id is two panels:/)
    assert.doesNotMatch(css, /data-phone="list"/)
    /* CONTROL: the thread's own column rules are still there */
    assert.match(css, /\.topic-browse__thread \{/)
  })
})
