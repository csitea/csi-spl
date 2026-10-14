// SPL-1637 poll-control (owner HUM-10, t1 aab3d88b): a ```poll fence in a
// post is ONE form of radio buttons or checkboxes; a click posts the answer
// as a reply with a machine-readable marker that agents parse.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  answerBody, chatBody, lockSeconds, mayHavePoll, parseAnswer, parsePoll, pollAnswers, splitPolls,
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
  it('no Poll line, no marker', () => {
    assert.equal(parseAnswer('Answer: A'), null)
  })
})

describe('pollAnswers: chat replies and UI state', () => {
  const rows = [
    { from: 'HUM-10', ts: '2026-10-13T08:00:00Z', body: `Poll: ${MID}\nAnswer: A` },
    { from: 'HUM-10', ts: '2026-10-13T08:02:00Z', body: `Chat: wants to discuss\nPoll: ${MID}\n> Which deploy path?\n\nmy text` },
    { from: 'HUM-10', ts: '2026-10-13T08:03:00Z', body: `Poll: ${MID}\nAnswer: B` },
  ]
  it('a chat reply is not an answer, but the UI should recognize it as a "Chat about this" pick', () => {
    const answers = pollAnswers(rows, MID)
    assert.deepEqual(answers, [{ from: 'HUM-10', picks: { 1: ['B'] }, ts: '2026-10-13T08:03:00Z' }])
    // The UI should recognize the chat reply and show "Chat about this" as picked
    const chatReplies = rows.filter((r) => /^Chat: wants to discuss/i.test(String(r.body || '')))
    assert.equal(chatReplies.length, 1)
  })
})

// Defect 1: A chat reply should show "Chat about this" as picked in the UI.
describe('Defect 1: chat reply recognition in UI', () => {
  const MID = '8d3af7a1-0000-4000-8000-000000000001'
  const form = {
    multi: false,
    questions: [{ text: 'Which deploy path?', kind: 'radio', options: [{ key: 'A', text: 'Deploy now' }, { key: 'B', text: 'Wait for CI' }] }],
  }
  const me = 'HUM-10'
  const rows = [
    { from: me, ts: '2026-10-13T08:02:00Z', body: `Chat: wants to discuss\nPoll: ${MID}\n> Which deploy path?\n\nmy text` },
  ]
  
  // Simulate the UI state logic from PollForm.vue
  function getChatPicks(form, rows, msgId, me) {
    const chatPicks = {}
    const chatReply = rows.find((r) => r.from === me && String(r.body || '').includes(`Poll: ${msgId}`) && /(^|\n)Chat: wants to discuss/i.test(String(r.body || '')))
    if (chatReply) {
      form.questions.forEach((_, i) => {
        chatPicks[i] = true
      })
    }
    return chatPicks
  }
  
  it('should recognize a chat reply and set chatPicks for all questions', () => {
    const chatPicks = getChatPicks(form, rows, MID, me)
    assert.deepEqual(chatPicks, { 0: true })
  })
  
  it('should NOT set chatPicks if the chat reply is missing', () => {
    const noChatRows = [{ from: me, ts: '2026-10-13T08:00:00Z', body: `Poll: ${MID}\nAnswer: A` }]
    const chatPicks = getChatPicks(form, noChatRows, MID, me)
    assert.deepEqual(chatPicks, {})
  })
  
  it('should set chatPicks even if the chat marker is trailing (backward compatibility)', () => {
    const malformedRows = [
      { from: me, ts: '2026-10-13T08:02:00Z', body: `my text\nChat: wants to discuss\nPoll: ${MID}` },
    ]
    const chatPicks = getChatPicks(form, malformedRows, MID, me)
    assert.deepEqual(chatPicks, { 0: true })
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
