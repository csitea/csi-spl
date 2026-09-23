// The Omnibox is the only writer. `@receiver` starts a new message. `in:`
// replies into the thread whose starter (first message) has that title.
// The open thread pane must not capture the box: that is what scattered one
// exchange into twelve tasks (CLE-3433 / OA-38) and what made a reply look
// like the only thing the box could do.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  activeInQuery,
  filterThreadTitles,
  insertInClause,
  resolveInClause,
  threadChoices,
} from '../../src/utils/thread-in.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')

const SHORT = { taskId: 'short', title: 'Review', channel: '' }
const LONG = { taskId: 'long', title: 'Review the spool', channel: 'tasks' }

describe('in: query at the caret', () => {
  it('reads the text after in: and ignores a caret that has left the token', () => {
    assert.equal(activeInQuery('in:', 3), '')
    assert.equal(activeInQuery('in: rev', 7), 'rev')
    assert.equal(activeInQuery('please in: Rev', 14), 'Rev')
    assert.equal(activeInQuery('IN: Rev', 7), 'Rev')
    assert.equal(activeInQuery('hello', 5), null)
    assert.equal(activeInQuery('please in: Rev more', 6), null)
    assert.equal(activeInQuery('margin: 4', 9), null)
  })
})

describe('thread title dropdown', () => {
  const rows = [
    { taskId: '1', title: 'Review the spool' },
    { taskId: '2', title: 'Apply the patch' },
    { taskId: '3', title: 'Review alerts' },
  ]

  it('empty query lists the first 8 and a substring is case-insensitive', () => {
    const many = Array.from({ length: 10 }, (_, i) => ({ taskId: String(i), title: `Thread ${i}` }))
    assert.equal(filterThreadTitles(many, '').length, 8)
    assert.equal(filterThreadTitles(many, '')[0].taskId, '0')
    assert.deepEqual(filterThreadTitles(rows, 'review').map((r) => r.taskId), ['1', '3'])
    assert.deepEqual(filterThreadTitles(rows, 'PATCH').map((r) => r.taskId), ['2'])
    assert.deepEqual(filterThreadTitles(rows, 'nope'), [])
  })

  it('inserts the full title, not the fragment that was typed', () => {
    const line = 'please in: rev'
    const next = insertInClause(line, line.length, 'Review the spool')
    assert.equal(next.text, 'please in: Review the spool ')
    assert.equal(next.cursor, next.text.length)
    const bare = insertInClause('in:', 3, 'Review the spool')
    assert.equal(bare.text, 'in: Review the spool ')
  })
})

describe('which threads can be named', () => {
  it('uses the starter only, and a viewer subject beats a feed body', () => {
    const choices = threadChoices({
      threads: [{ task_id: 'T1', subject: 'Viewer subject', channel: 'tasks' }],
      messages: [
        { task_id: 'T1', ts: '2026-09-18T10:00:00Z', msg_id: 'a', body: 'Feed body that must not win' },
        { task_id: 'T1', ts: '2026-09-18T10:05:00Z', msg_id: 'b', body: 'later on the same task' },
        { task_id: 'T2', ts: '2026-09-18T11:00:00Z', msg_id: 'c', body: 'Second thread\nrest' },
        { task_id: 'T2', ts: '2026-09-18T09:00:00Z', msg_id: 'd', body: 'Earlier starter', channel: 'alerts' },
        { task_id: 'child', parent_task_id: 'T2', ts: '2026-09-18T08:00:00Z', msg_id: 'e', body: 'A reply is not a title' },
      ],
    })
    const byId = Object.fromEntries(choices.map((c) => [c.taskId, c]))
    assert.equal(byId.T1.title, 'Viewer subject')
    assert.equal(byId.T1.channel, 'tasks')
    assert.equal(byId.T2.title, 'Earlier starter')
    assert.equal(byId.T2.channel, 'alerts')
    assert.equal(byId.child, undefined)
  })
})

describe('resolving in: on send', () => {
  const choices = [SHORT, LONG]

  it('an exact title replies into that thread and leaves the rest of the line', () => {
    const hit = resolveInClause('in: Review the spool thanks', choices)
    assert.equal(hit.taskId, 'long')
    assert.equal(hit.channel, 'tasks')
    assert.equal(hit.title, 'Review the spool')
    assert.equal(hit.body, 'thanks')
  })

  it('the longest title wins, and a mere prefix does not', () => {
    assert.equal(resolveInClause('in: Review the spool now', choices).taskId, 'long')
    assert.equal(resolveInClause('in: Review now', choices).taskId, 'short')
    assert.equal(resolveInClause('in: Review', choices).taskId, 'short')
    const prefix = resolveInClause('in: Revi', [LONG])
    assert.equal(prefix.taskId, '')
    assert.equal(prefix.body, 'in: Revi')
  })

  it('matches without regard to case, and @ stays in the body', () => {
    assert.equal(resolveInClause('IN: review the spool', choices).taskId, 'long')
    const both = resolveInClause('@CLE-07 look in: Review the spool', choices)
    assert.equal(both.taskId, 'long')
    assert.equal(both.body, '@CLE-07 look')
  })

  it('an unknown in: stays literal, so the send is a new message', () => {
    const miss = resolveInClause('in: nobody hello', choices)
    assert.equal(miss.taskId, '')
    assert.equal(miss.body, 'in: nobody hello')
    const plain = resolveInClause('hello channel', choices)
    assert.equal(plain.taskId, '')
    assert.equal(plain.body, 'hello channel')
  })

  it('in: inside a code fence is literal', () => {
    const fenced = '```\nin: Review the spool\n```\noutside'
    const hit = resolveInClause(fenced, choices)
    assert.equal(hit.taskId, '')
    assert.equal(hit.body, fenced.trim())
  })
})

describe('the box follows the line, not the open pane', () => {
  const pages = ['src/pages/dm/[peer].vue', 'src/pages/channel/[name].vue', 'src/pages/lobby.vue']

  it('channel and DM no longer bind the Omnibox to the open thread', () => {
    for (const page of pages.slice(0, 2)) {
      const s = src(page)
      assert.doesNotMatch(s, /omniboxParentTaskId/)
      assert.match(s, /channel\.send\(text, threadId \|\| undefined, files, channelId\)/)
    }
  })

  it('the composer offers thread titles and resolves in: before it emits', () => {
    const s = src('src/components/MessageComposer.vue')
    assert.match(s, /data-test="thread-in-suggestions"/)
    assert.match(s, /activeInQuery/)
    assert.match(s, /filterThreadTitles/)
    assert.match(s, /insertInClause/)
    assert.match(s, /resolveInClause/)
    assert.ok(s.indexOf('resolveInClause(') < s.indexOf("emit('send'"))
    assert.doesNotMatch(s, /omniboxParentTaskId/)
  })

  it('TopBar keeps the resolved thread on Retry', () => {
    const s = src('src/components/TopBar.vue')
    assert.match(s, /await target\.send\(text, sent, parent, channelId\)/)
    assert.match(s, /onSend\(failed\.text, failed\.threadId, failed\.files, failed\.channelId\)/)
  })

  it('a reply into another channel does not ride the DM peer or this feed', () => {
    const live = src('src/stores/channel.ts')
    assert.match(live, /task_id: parentTaskId \|\| newId\(\)/)
    assert.match(live, /const asDm = !channelId && Boolean\(peer\.value\)/)
    assert.match(live, /const showHere = !channelId \|\| channelId === active\.value/)
  })

  it('a closed right pane starts a new lobby thread; an open one still posts into the room', () => {
    const s = src('src/pages/lobby.vue')
    assert.match(s, /sendsNewThread/)
    assert.match(s, /threadId !== here/)
    assert.match(s, /channel\.send\(text, threadId, files, channelId\)/)
    assert.match(s, /channelId \|\| 'lobby'/)
    assert.match(s, /store\.send\(text, files \|\| \[\]\)/)
  })
})
