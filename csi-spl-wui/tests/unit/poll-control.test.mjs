// SPL-1637 poll-control (owner HUM-10, t1 aab3d88b): a ```poll fence in a
// post is ONE form of radio buttons or checkboxes; a click posts the answer
// as a reply with a machine-readable marker that agents parse.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  answerBody, chatBody, chatPicks, lockSeconds, mayHavePoll, parseAnswer, parsePoll, pollAnswers, splitPolls,
} from '../../src/utils/poll.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const RADIO = 'Which deploy path?\n(A) Deploy now\n(B) Wait for CI'
const CHECK = 'Which envs?\n- [a] dev\n- [b] prd\nWhich checks?\n[1] unit\n[2] e2e'
const MID = '8d3af7a1-0000-4000-8000-000000000001'
const fence = (s) => `\`\`\`poll\n${s}\n\`\`\``

describe('parsePoll: one form, all radios or all checkboxes', () => {
  it('radio options make a single-choice form', () => {
    assert.deepEqual(parsePoll(RADIO), {
      multi: false,
      questions: [{ text: 'Which deploy path?', kind: 'radio', options: [{ key: 'A', text: 'Deploy now' }, { key: 'B', text: 'Wait for CI' }] }],
    })
  })
  it('SPL-1654: a one-option radio question is a Go button', () => {
    assert.deepEqual(parsePoll('Go?\n(GO) Go'), {
      multi: false,
      questions: [{ text: 'Go?', kind: 'button', options: [{ key: 'GO', text: 'Go' }] }],
    })
  })
  it('SPL-1654 control: two options stay radios; a one-box checkbox question stays a checkbox', () => {
    assert.equal(parsePoll('Go or close?\n(GO) Go\n(C) Close').questions[0].kind, 'radio')
    assert.equal(parsePoll('Opt in?\n[A] yes').questions[0].kind, 'check')
    assert.deepEqual(parsePoll('Q1\n(GO) Go\nQ2\n(A) x\n(B) y').questions.map((q) => q.kind), ['button', 'radio'])
  })
  it('a checkbox form of two questions; keys upper-cased; list dashes allowed', () => {
    const p = parsePoll(CHECK)
    assert.equal(p.multi, true)
    assert.deepEqual(p.questions.map((q) => q.text), ['Which envs?', 'Which checks?'])
    assert.deepEqual(p.questions[0].options.map((o) => o.key), ['A', 'B'])
  })
  it('radios and checkboxes mixed is not a form (owner f24f06f2)', () => {
    assert.equal(parsePoll('Q\n(A) x\n[B] y'), null)
    assert.equal(parsePoll('Q1\n(A) x\nQ2\n[A] y'), null)
  })
  it('a mismatched bracket is not an option; a question with no option is not a form', () => {
    assert.equal(parsePoll('Q\n(A] x'), null)
    assert.equal(parsePoll('just text'), null)
    assert.equal(parsePoll('Q1\n(A) x\nQ2 with none'), null)
  })
  it('SPL-3062: a task-list marker before an option is dropped', () => {
    assert.deepEqual(parsePoll('Q\n[ ] (A) x\n- [ ] (B) y').questions[0].options, [{ key: 'A', text: 'x' }, { key: 'B', text: 'y' }])
    assert.deepEqual(parsePoll('Q\n* [x] (B) y\n[X] (C) z').questions[0].options, [{ key: 'B', text: 'y' }, { key: 'C', text: 'z' }])
    assert.deepEqual(parsePoll('Q\n- [ ] [A] x\n- [x] [B] y').questions[0].options.map((o) => o.key), ['A', 'B'])
    assert.deepEqual(splitPolls(fence('Q\n[ ] (A) x\n[ ] (B) y')).map((s) => s.type), ['poll'])
  })
  it('SPL-3062 control: [x] with no option after it stays checkbox X', () => {
    assert.deepEqual(parsePoll('Q\n[x] yes\n[n] no').questions[0].options, [{ key: 'X', text: 'yes' }, { key: 'N', text: 'no' }])
  })
  it('a key twice in one question is not a form', () => {
    assert.equal(parsePoll('Q\n(A) x\n(a) y'), null)
  })
  it('a multi-line question joins; the author\'s own "Chat about this" is dropped', () => {
    const p = parsePoll('Long\nquestion\n(A) x\n(C) Chat about this')
    assert.equal(p.questions[0].text, 'Long question')
    assert.deepEqual(p.questions[0].options, [{ key: 'A', text: 'x' }])
  })
})

describe('splitPolls: at most one form per message (owner b14c95a4)', () => {
  it('keeps text around the form, in order; a second form stays text', () => {
    const seg = splitPolls(`intro\n\n${fence(RADIO)}\nmiddle\n${fence(CHECK)}\nend`)
    assert.deepEqual(seg.map((s) => s.type), ['text', 'poll', 'text'])
    assert.equal(seg[0].text.trim(), 'intro')
    assert.match(seg[2].text, /```poll\nWhich envs/)
  })
  it('a ```poll inside a longer fence is that fence\'s content', () => {
    assert.deepEqual(splitPolls(`\`\`\`\`text\n${fence(RADIO)}\n\`\`\`\``).map((s) => s.type), ['text'])
  })
  it('an unclosed or invalid form stays text', () => {
    assert.deepEqual(splitPolls(`\`\`\`poll\n${RADIO}`).map((s) => s.type), ['text'])
    assert.deepEqual(splitPolls(fence('no options')).map((s) => s.type), ['text'])
  })
  it('mayHavePoll is the cheap gate', () => {
    assert.equal(mayHavePoll(`x\n${fence(RADIO)}`), true)
    assert.equal(mayHavePoll('a ```poll mid-line'), false)
  })
})

describe('the answer marker', () => {
  const p = parsePoll(RADIO)
  it('a radio pick', () => {
    const b = answerBody(p, [['A']], MID)
    assert.equal(b, `Poll: ${MID}\nAnswer: A — Deploy now`)
    assert.deepEqual(parseAnswer(b), { msgId: MID, chat: false, picks: { 1: ['A'] } })
  })
  it('a checkbox form of two questions: one numbered line each, none for an empty one', () => {
    const c = parsePoll(CHECK)
    const b = answerBody(c, [['B', 'A'], []], MID)
    assert.equal(b, `Poll: ${MID}\nAnswer 1: A,B — dev; prd\nAnswer 2: none`)
    assert.deepEqual(parseAnswer(b).picks, { 1: ['A', 'B'], 2: [] })
  })
  it('a chat is a wants-to-discuss marker, not an answer', () => {
    const b = chatBody(p, MID)
    assert.match(b, /^Chat: wants to discuss\nPoll: /)
    assert.match(b, /> Which deploy path\?/)
    assert.equal(parseAnswer(b + 'my text').chat, true)
  })
  it('SPL-1851: the chat marker leads, the question quoted, the reader\'s text after it', () => {
    const b = chatBody(p, MID) + 'my text'
    assert.equal(b, `Chat: wants to discuss\nPoll: ${MID}\n> Which deploy path?\n\nmy text`)
    assert.deepEqual(parseAnswer(b), { msgId: MID, chat: true, picks: {}, quote: 'Which deploy path?' })
  })
  it('SPL-1851: a chat sent with text before the marker (t1 d64c762a msg b09c5a8c) still counts as the chat', () => {
    const b = `I did reset it manually Chat: wants to discuss\nPoll: ${MID}\n> Which deploy path?`
    assert.deepEqual(parseAnswer(b), { msgId: MID, chat: true, picks: {}, quote: 'Which deploy path?' })
  })
  it('no Poll line, no marker', () => {
    assert.equal(parseAnswer('Answer: A'), null)
  })
})

describe('pollAnswers: the newest answer per sender wins', () => {
  const rows = [
    { from: 'HUM-10', ts: '2026-10-13T08:00:00Z', body: `Poll: ${MID}\nAnswer: A` },
    { from: 'HUM-4', ts: '2026-10-13T08:01:00Z', body: `Poll: ${MID}\nAnswer: B` },
    { from: 'HUM-10', ts: '2026-10-13T08:02:00Z', body: `Poll: ${MID}\nAnswer: B — x` },
    { from: 'HUM-10', ts: '2026-10-13T08:03:00Z', body: `Chat: wants to discuss\nPoll: ${MID}\nhm` },
    { from: 'HUM-5', ts: '2026-10-13T08:04:00Z', body: 'Poll: bbbbbbbb-0000\nAnswer: A' },
    { from: 'HUM-6', ts: '2026-10-13T08:05:00Z', body: 'Answer: A' },
  ]
  it('re-answer replaces; chats and other forms are skipped', () => {
    assert.deepEqual(pollAnswers(rows, MID), [
      { from: 'HUM-10', picks: { 1: ['B'] }, ts: '2026-10-13T08:02:00Z' },
      { from: 'HUM-4', picks: { 1: ['B'] }, ts: '2026-10-13T08:01:00Z' },
    ])
  })
})

describe('SPL-1851 chatPicks: a chat reply newer than the answer is the reader\'s pick', () => {
  const p = parsePoll(RADIO)
  const two = parsePoll('First?\n(A) a\n(B) b\nSecond?\n(A) c\n(B) d')
  const chat = (q) => `Chat: wants to discuss\nPoll: ${MID}\n> ${q}\n\nhm`
  it('a chat counts as the "chat" pick on the question it quotes', () => {
    assert.deepEqual(chatPicks(p, [{ from: 'HUM-10', ts: 't1', body: chat('Which deploy path?') }], MID, 'HUM-10'), ['t1'])
    assert.deepEqual(chatPicks(two, [{ from: 'HUM-10', ts: 't1', body: chat('Second?') }], MID, 'HUM-10'), ['', 't1'])
  })
  it('the owner\'s reply with the marker after the text is picked too', () => {
    const body = `I did reset it manually Chat: wants to discuss\nPoll: ${MID}\n> Which deploy path?`
    assert.deepEqual(chatPicks(p, [{ from: 'HUM-10', ts: 't1', body }], MID, 'HUM-10'), ['t1'])
  })
  it('a newer answer replaces it; a newer chat replaces the answer; a row with no ts yet is the newest', () => {
    const ans = (ts) => ({ from: 'HUM-10', ts, body: `Poll: ${MID}\nAnswer: A` })
    const ch = (ts) => ({ from: 'HUM-10', ts, body: chat('Which deploy path?') })
    assert.deepEqual(chatPicks(p, [ch('t1'), ans('t2')], MID, 'HUM-10'), [''])
    assert.deepEqual(chatPicks(p, [ans('t1'), ch('t2')], MID, 'HUM-10'), ['t2'])
    assert.deepEqual(chatPicks(p, [ans('t1'), { from: 'HUM-10', body: chat('Which deploy path?') }], MID, 'HUM-10'), ['~'])
  })
  it('other senders and other forms do not count', () => {
    const rows = [{ from: 'HUM-4', ts: 't1', body: chat('Which deploy path?') }, { from: 'HUM-10', ts: 't2', body: 'Chat: wants to discuss\nPoll: bbbbbbbb-0000' }]
    assert.deepEqual(chatPicks(p, rows, MID, 'HUM-10'), [''])
  })
})

describe('lock-in (owner 8f0da7ca)', () => {
  it('45 s per question: 10 questions = 450 s', () => {
    assert.equal(lockSeconds(1), 45)
    assert.equal(lockSeconds(10), 450)
    assert.equal(lockSeconds(0), 45)
  })
})

describe('the WUI wiring', () => {
  it('MessageBody loads the form lazily, only for a body that may hold one', () => {
    const src = readFileSync(join(WUI, 'src/components/MessageBody.vue'), 'utf8')
    assert.match(src, /mayHavePoll\(/)
    assert.doesNotMatch(src, /utils\/poll\.mjs/)
    assert.match(src, /defineAsyncComponent\(\(\) => import\('~\/components\/PollBody\.vue'\)\)/)
  })
  it('the form has no Send on radios, always offers "Chat about this"', () => {
    const src = readFileSync(join(WUI, 'src/components/PollForm.vue'), 'utf8')
    assert.match(src, /poll\.chat/)
    assert.match(src, /v-if="form\.multi[^"]*"[^>]*data-testid="poll-send"|data-testid="poll-send"[^>]*v-if="form\.multi/)
  })
})
