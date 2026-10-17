// SPL-2357 (refactor round 13 row 09): the first-paint poll gate's edges.
// mayHavePoll decides whether MessageBody loads the parser and the form at
// all, so a false "no" hides a form: every body splitPolls (poll.mjs) turns
// into a form must pass the gate. A false "yes" only costs a lazy load.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { mayHavePoll, POLL_HOST, POLL_ROWS } from '../../src/utils/poll-fence.mjs'
import { splitPolls } from '../../src/utils/poll.mjs'

const FORM = 'Go?\n(A) yes\n(B) no'
const isForm = (body) => splitPolls(body).some((s) => s.type === 'poll')

describe('mayHavePoll: the fences that open a form', () => {
  it('a 4-backtick (and longer) fence', () => {
    assert.equal(mayHavePoll(`\`\`\`\`poll\n${FORM}\n\`\`\`\``), true)
    assert.equal(mayHavePoll(`\`\`\`\`\`\`poll\n${FORM}\n\`\`\`\`\`\``), true)
  })
  it('trailing spaces and tabs after the info string', () => {
    assert.equal(mayHavePoll(`\`\`\`poll \n${FORM}\n\`\`\``), true)
    assert.equal(mayHavePoll(`\`\`\`poll\t\n${FORM}\n\`\`\``), true)
    assert.equal(mayHavePoll(`\`\`\`poll \t \n${FORM}\n\`\`\``), true)
  })
  it('CRLF and bare CR line ends', () => {
    assert.equal(mayHavePoll(`intro\r\n\`\`\`poll\r\n${FORM.replace(/\n/g, '\r\n')}\r\n\`\`\`\r\n`), true)
    assert.equal(mayHavePoll(`intro\r\`\`\`poll\r${FORM.replace(/\n/g, '\r')}\r\`\`\``), true)
    assert.equal(mayHavePoll('```poll \t\r\n'), true)
  })
  it('the opener as the first line, the last line, or the whole body', () => {
    assert.equal(mayHavePoll(`\`\`\`poll\n${FORM}\n\`\`\``), true)
    assert.equal(mayHavePoll('text\n```poll'), true)
    assert.equal(mayHavePoll('```poll'), true)
  })
})

describe('mayHavePoll: what never opens a form', () => {
  it('null, undefined and empty input', () => {
    for (const v of [null, undefined, '', 0, false]) assert.equal(mayHavePoll(v), false, String(v))
  })
  it('a non-string body is read as its text', () => {
    assert.equal(mayHavePoll({ toString: () => '```poll\nx' }), true)
    assert.equal(mayHavePoll(42), false)
  })
  it('two backticks, an indented or mid-line opener', () => {
    assert.equal(mayHavePoll(`\`\`poll\n${FORM}\n\`\``), false)
    assert.equal(mayHavePoll(` \`\`\`poll\n${FORM}\n\`\`\``), false)
    assert.equal(mayHavePoll('a ```poll mid-line'), false)
  })
  it('another info string that starts with poll', () => {
    assert.equal(mayHavePoll(`\`\`\`polls\n${FORM}\n\`\`\``), false)
    assert.equal(mayHavePoll(`\`\`\`poll x\n${FORM}\n\`\`\``), false)
    assert.equal(mayHavePoll(`\`\`\`Poll\n${FORM}\n\`\`\``), false)
  })
})

describe('mayHavePoll never hides a form splitPolls finds', () => {
  const bodies = {
    lf: `intro\n\`\`\`poll\n${FORM}\n\`\`\`\nend`,
    crlf: `intro\r\n\`\`\`poll\r\n${FORM.replace(/\n/g, '\r\n')}\r\n\`\`\`\r\nend`,
    cr: `intro\r\`\`\`poll\r${FORM.replace(/\n/g, '\r')}\r\`\`\``,
    fourTicks: `\`\`\`\`poll\n${FORM}\n\`\`\`\``,
    trailingTab: `\`\`\`poll\t\n${FORM}\n\`\`\`\t`,
    closerAtEof: `\`\`\`poll\n${FORM}\n\`\`\``,
  }
  for (const [name, body] of Object.entries(bodies)) {
    it(name, () => {
      assert.equal(isForm(body), true, 'the parser finds a form')
      assert.equal(mayHavePoll(body), true, 'so the gate must let it through')
    })
  }
})

describe('the injection keys', () => {
  it('are distinct, namespaced strings', () => {
    assert.equal(POLL_HOST, 'spool:poll-host')
    assert.equal(POLL_ROWS, 'spool:poll-rows')
  })
})
