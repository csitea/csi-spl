// SPL-1763 (owner HUM-10, t1 0bb05176 msg 5cd1ce7b): "whenever one clicks on
// the "Archived" label, that label is a button which will unarchive the
// topic". The SHIPPED ArchivedBadge template is rendered with Vue's own
// compiler + server renderer: a viewer the hub lets unarchive gets a
// <button> named "Unarchive topic"; everyone else the plain label (the
// control). utils/archived-card.mjs - the probe that decides it - runs
// against a fake client that answers as the hub does.
//
// Run: node tests/unit/archived-badge-unarchive.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import * as Vue from 'vue'
import { compile } from '@vue/compiler-dom'
import { renderToString } from 'vue/server-renderer'
import { archivedCardOf, unarchivedTopic } from '../../src/utils/archived-card.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const STAMP = '2026-10-02T12:00:00Z'
const LOBBY = 'lobby-task'

const sfc = read('src/components/ArchivedBadge.vue')
const template = sfc.slice(sfc.indexOf('<template>') + 10, sfc.lastIndexOf('</template>'))
const en = JSON.parse(read('i18n/locales/en.json'))
const t = (key, params = {}) => key.split('.').reduce((o, k) => o?.[k], en).replace(/\{(\w+)\}/g, (_, k) => params[k])
const UiIcon = { props: ['name'], render() { return Vue.h('svg', { 'data-icon': this.name }) } }

async function badge(ctx) {
  const code = compile(template, { mode: 'function', prefixIdentifiers: false }).code
  const render = new Function('Vue', code)(Vue)
  const scope = new Proxy({}, {
    has: (_, k) => typeof k === 'string' && !k.startsWith('_') && !(k in globalThis),
    get: (_, k) => (k in ctx ? ctx[k] : undefined),
  })
  const app = Vue.createSSRApp({ render: (_c, cache) => render(scope, cache || []) })
  app.component('UiIcon', UiIcon)
  app.config.warnHandler = () => {}
  return renderToString(app)
}
const base = { t, showWhen: true, date: '2026-10-02', busy: false, unarchive: () => {} }

describe('ArchivedBadge: the label is a button for whoever may unarchive', () => {
  it('may unarchive -> <button type=button> named "Unarchive topic", the word and day still shown', async () => {
    const out = await badge({ ...base, canUnarchive: true, title: 'Archived x · Unarchive topic' })
    assert.match(out, /^<button[^>]*class="archived-badge archived-badge--when archived-badge--btn"/)
    assert.match(out, /type="button"/)
    assert.match(out, /aria-label="Unarchive topic"/)
    assert.match(out, /data-test="archived-badge"/)
    assert.match(out, />Archived</)
    assert.match(out, /archived-badge__when[^>]*>2026-10-02</)
    assert.doesNotMatch(out, /disabled/)
  })
  it('while the write runs the button is disabled (no double unarchive)', async () => {
    assert.match(await badge({ ...base, canUnarchive: true, busy: true }), /<button[^>]*disabled/)
  })
  it('may not (or not known yet) -> the plain label: a span, no name, no type (control)', async () => {
    const out = await badge({ ...base, canUnarchive: false, title: 'Archived x' })
    assert.match(out, /^<span[^>]*class="archived-badge archived-badge--when"/)
    assert.doesNotMatch(out, /<button|aria-label|type="button"|archived-badge--btn/)
    assert.match(out, />Archived</)
  })
  it('the tap area is 44 px without growing the box (mobile first, no header jump)', () => {
    assert.match(sfc, /\.archived-badge--btn::after \{[^}]*width: max\(100%, var\(--tap, 44px\)\);[^}]*height: max\(100%, var\(--tap, 44px\)\);/s)
    assert.match(sfc, /\.archived-badge--btn \{[^}]*position: relative;[^}]*margin: 0;/s)
  })
  it('every locale names the button (archive.unarchive_topic), none left in English', () => {
    for (const f of ['bg', 'el', 'en', 'es', 'et', 'fi', 'he', 'lt', 'lv', 'mk', 'nl', 'pl', 'ro', 'ru', 'sk', 'sr', 'sv', 'tr', 'uk']) {
      const v = JSON.parse(read(`i18n/locales/${f}.json`)).archive?.unarchive_topic
      assert.ok(typeof v === 'string' && v.trim(), `${f}: archive.unarchive_topic`)
      if (f !== 'en') assert.notEqual(v, en.archive.unarchive_topic, `${f}: translated`)
    }
  })
})

/* A fake client: `cards` are the hub's archived cards by msg id. */
function fakeApi(cards, oldest = {}) {
  const asked = []
  return {
    asked,
    async getTopic(task) { asked.push(`topic:${task}`); return { messages: oldest[task] ? [{ msg_id: oldest[task] }] : [] } },
    async topicSize(id) {
      asked.push(`size:${id}`)
      const c = cards[id]
      if (!c) throw Object.assign(new Error('no'), { status: 404, token: 'not_found' })
      return { msg_id: id, task_id: c.task, archived: c.archived !== false, can_archive: c.may === true, can_delete: false, replies: 0, task_ids: [c.task] }
    },
  }
}

describe('archivedCardOf: the hub decides who gets the button', () => {
  it('a channel topic: its first message is the card; can_archive true -> may unarchive', async () => {
    const api = fakeApi({ 'm-1': { task: 'task-1', may: true } }, { 'task-1': 'm-1' })
    assert.deepEqual(await archivedCardOf(api, 'task-1', LOBBY), { msgId: 'm-1', canUnarchive: true })
  })
  it('can_archive false (workspace setting "admins") -> the label only', async () => {
    const api = fakeApi({ 'm-1': { task: 'task-1', may: false } }, { 'task-1': 'm-1' })
    assert.deepEqual(await archivedCardOf(api, 'task-1', LOBBY), { msgId: 'm-1', canUnarchive: false })
  })
  it('a lobby card thread: the task id is the card (its task is the lobby)', async () => {
    const api = fakeApi({ 'card-9': { task: LOBBY, may: true } })
    assert.deepEqual(await archivedCardOf(api, 'card-9', LOBBY), { msgId: 'card-9', canUnarchive: true })
  })
  it('a live card, a refused read or another topic\'s card -> null (control)', async () => {
    assert.equal(await archivedCardOf(fakeApi({ 'm-1': { task: 'task-1', may: true, archived: false } }, { 'task-1': 'm-1' }), 'task-1', LOBBY), null)
    assert.equal(await archivedCardOf(fakeApi({}), 'task-1', LOBBY), null)
    assert.equal(await archivedCardOf(fakeApi({ 'm-1': { task: 'other', may: true } }, { 'task-1': 'm-1' }), 'task-1', LOBBY), null)
    assert.equal(await archivedCardOf(fakeApi({}), '', LOBBY), null)
  })
  it('the lobby itself is never a topic: nothing asked', async () => {
    const api = fakeApi({ [LOBBY]: { task: LOBBY, may: true } })
    assert.equal(await archivedCardOf(api, LOBBY, LOBBY), null)
    assert.deepEqual(api.asked.filter((a) => a.startsWith('size:')), [])
  })
})

describe('unarchivedTopic: every badge on the topic hears the unarchive', () => {
  it('matches the card\'s task or a lobby card\'s thread; an archive or another topic does not', () => {
    assert.ok(unarchivedTopic({ msgId: 'm-1', taskId: 'task-1', archived: false }, 'task-1'))
    assert.ok(unarchivedTopic({ msgId: 'card-9', taskId: LOBBY, archived: false }, 'card-9'))
    assert.ok(!unarchivedTopic({ msgId: 'm-1', taskId: 'task-1', archived: true }, 'task-1'))
    assert.ok(!unarchivedTopic({ msgId: 'm-2', taskId: 'task-2', archived: false }, 'task-1'))
    assert.ok(!unarchivedTopic(null, 'task-1'))
  })
})
