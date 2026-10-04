// The topic view is two vertical panels. The channel page stays three.
// Run: node --test tests/unit/topic-view-two-panels.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')

describe('the topic view is two panels', () => {
  const page = read('src/pages/t/[task_id].vue')
  const layout = read('src/layouts/default.vue')
  const css = read('src/assets/css/main.css')
  const channel = read('src/pages/channel/[name].vue')

  it('the page is a topic list beside TopicPane', () => {
    assert.match(page, /data-test="topic-browse"/)
    assert.match(page, /data-test="topic-browse-list"/)
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

  it('desktop hides the sidebar; a phone shows one panel', () => {
    assert.match(css, /\.spool-shell\[data-topic-browse="1"\] > \.sidebar/)
    assert.match(css, /@media \(min-width: 821px\) \{[\s\S]*\.spool-shell\[data-topic-browse="1"\] > \.sidebar/)
    assert.match(css, /\.topic-browse:not\(\[data-phone="list"\]\) > \.topic-browse__list \{ display: none; \}/)
    assert.match(css, /\.topic-browse\[data-phone="list"\] > \.topic-browse__thread \{ display: none; \}/)
  })
})
