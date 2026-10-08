// t1 3558e416: the composer's code marks - runs that cover the draft exactly.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { composerCodeRuns } from '../../src/utils/composer-code-marks.mjs'
import { parseBody, closeOpenFence } from '../../src/utils/code-blocks.mjs'

const kinds = (s) => composerCodeRuns(s).map((r) => (r.kind ? `${r.kind}:${r.text}` : r.text))

describe('composerCodeRuns', () => {
  it('marks `foobar` as inline code (owner msg 841cf92c)', () => {
    const s = 'for example this one "`foobar`" , shoud be with different code font'
    assert.deepEqual(kinds(s), ['for example this one "', 'inline:`foobar`', '" , shoud be with different code font'])
  })

  it('an unclosed ``` is a block at once, to the end of the draft, with no closer typed', () => {
    assert.deepEqual(kinds('code: ```line one\nline two'), ['code: ', 'block:```line one\nline two'])
    assert.deepEqual(kinds('```'), ['block:```'])
  })

  it('the owner\'s fence test (msg ca221ae1) is one block, mid-line opener included', () => {
    const s = 'let me test once again : \n\n\n\n```this should be code \nwhich is multiple lines \n\n```'
    assert.deepEqual(kinds(s), ['let me test once again : \n\n\n\n', 'block:```this should be code \nwhich is multiple lines \n\n```'])
    // and the SENT rule is unchanged: it posts as one code block
    assert.equal(parseBody(s).filter((b) => b.type === 'code').length, 1)
  })

  it('a closed block with a language, then text', () => {
    assert.deepEqual(kinds('```js\nx\n```\nafter'), ['block:```js\nx\n```', '\n', 'after'])
  })

  it('an unmatched single tick stays text', () => {
    assert.deepEqual(kinds('a ``b`` c `d'), ['a ', 'inline:``b``', ' c `d'])
    assert.deepEqual(kinds('plain'), ['plain'])
    assert.deepEqual(kinds(''), [])
  })

  it('the runs always join back to the draft', () => {
    for (const s of ['`a` ```b\n`c`\n``` d `e', '````\nx\n```', '```x```y```', 'a\n```\n\n', '`` ` ``']) {
      assert.equal(composerCodeRuns(s).map((r) => r.text).join(''), s, s)
    }
  })

  it('send closes a block the author left open (one block on the wire)', () => {
    const sent = closeOpenFence('```\nline 1\nline 2')
    assert.equal(parseBody(sent).length, 1)
    assert.equal(parseBody(sent)[0].type, 'code')
    assert.equal(parseBody(sent)[0].text, 'line 1\nline 2')
  })
})
