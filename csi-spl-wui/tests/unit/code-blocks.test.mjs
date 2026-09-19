// Slack-style ``` code blocks: fence parser, render tree, composer state.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  bodyToHtml,
  closeOpenFence,
  enterAction,
  exitFence,
  fenceStateAt,
  normalizeNewlines,
  parseBody,
  tokenize,
} from '../../src/utils/code-blocks.mjs'
import { renderBody } from '../../src/utils/channel-feed.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const code = (text, lang = '', closed = true) => ({ type: 'code', text, lang, closed })
const para = (...parts) => ({ type: 'para', parts })
const txt = (text) => ({ type: 'text', text })

describe('fence parser', () => {
  it('plain text is one paragraph', () => {
    assert.deepEqual(parseBody('hello world'), [para(txt('hello world'))])
  })

  it('a fenced block on its own lines drops the fence newlines', () => {
    assert.deepEqual(parseBody('before\n```\nls -la\n  cd /x\n```\nafter'), [
      para(txt('before')),
      code('ls -la\n  cd /x'),
      para(txt('after')),
    ])
  })

  it('Slack inline form ```x``` on one line is a block', () => {
    assert.deepEqual(parseBody('run ```make test``` now'), [para(txt('run ')), code('make test'), para(txt(' now'))])
  })

  it('a language tag after the fence is a label, not content', () => {
    assert.deepEqual(parseBody('```bash\necho hi\n```'), [code('echo hi', 'bash')])
    assert.deepEqual(parseBody('```c++\nint x;\n```')[0].lang, 'c++')
  })

  it('a word on the opener line without a newline is content, not a label', () => {
    assert.deepEqual(parseBody('```echo hi```'), [code('echo hi')])
  })

  it('whitespace inside a block is preserved exactly (tabs, indents, blank lines)', () => {
    const body = 'def f():\n\tif x:\n\t\treturn  1\n\n    # four spaces\n'
    assert.equal(parseBody('```\n' + body + '```')[0].text, body.slice(0, -1))
  })

  it('markup inside a block stays literal (no bold, mention, inline code)', () => {
    const [b] = parseBody('```\n**not bold** @CLE-07 `x`\n```')
    assert.deepEqual(b, code('**not bold** @CLE-07 `x`'))
  })

  it('unclosed fence at a line start runs to the end (agent output truncated)', () => {
    assert.deepEqual(parseBody('log:\n```\nline 1\nline 2'), [para(txt('log:')), code('line 1\nline 2', '', false)])
  })

  it('unclosed fence mid-line stays literal text, as in Slack', () => {
    assert.deepEqual(parseBody('type ``` to open a block'), [para(txt('type ``` to open a block'))])
  })

  it('a fence inside inline code is content, not a fence', () => {
    assert.deepEqual(parseBody('type `` ``` `` to start'), [
      para(txt('type '), { type: 'inline', text: ' ``` ' }, txt(' to start')),
    ])
    assert.deepEqual(parseBody('use `a ``` b` ok'), [para(txt('use '), { type: 'inline', text: 'a ``` b' }, txt(' ok'))])
  })

  it('inline code does not cross a newline', () => {
    assert.deepEqual(parseBody('a `b\nc` d'), [para(txt('a `b\nc` d'))])
  })

  it('CRLF and CR bodies parse like LF', () => {
    assert.equal(normalizeNewlines('a\r\nb\rc'), 'a\nb\nc')
    assert.deepEqual(parseBody('x\r\n```js\r\nlet a = 1\r\n```\r\ny'), [para(txt('x')), code('let a = 1', 'js'), para(txt('y'))])
  })

  it('very long lines survive untouched', () => {
    const long = 'x'.repeat(20000)
    const [b] = parseBody('```\n' + long + '\n```')
    assert.equal(b.text.length, 20000)
    const t0 = Date.now()
    parseBody(('`a` ' + '`'.repeat(5) + ' ').repeat(5000))
    assert.ok(Date.now() - t0 < 2000, 'no quadratic blow-up on many backtick runs')
  })

  it('a longer fence is closed only by an equal or longer run', () => {
    assert.deepEqual(parseBody('````\na ``` b\n````'), [code('a ``` b')])
  })

  it('two blocks back to back', () => {
    assert.deepEqual(parseBody('```\na\n```\n```\nb\n```'), [code('a'), code('b')])
  })

  it('bold, mentions and inline code still render in text', () => {
    assert.deepEqual(parseBody('**hi** @CLE-07 `x`'), [
      para({ type: 'strong', text: 'hi' }, txt(' '), { type: 'mention', text: '@CLE-07' }, txt(' '), { type: 'inline', text: 'x' }),
    ])
  })

  it('tokenize keeps an empty body empty', () => {
    assert.deepEqual(tokenize(''), [])
    assert.deepEqual(parseBody(null), [])
  })
})

describe('never markup (SEC)', () => {
  const evil = '<script>alert(1)</script><img src=x onerror=alert(1)>'
  it('payload outside and inside a block stays a string', () => {
    const tree = parseBody(evil + '\n```html\n' + evil + '\n```')
    assert.equal(tree[0].parts[0].text, evil)
    assert.equal(tree[1].text, evil)
  })

  it('bodyToHtml and renderBody escape every payload', () => {
    for (const html of [bodyToHtml(evil + '```' + evil + '````' + evil + '`'), renderBody(evil + '\n```\n' + evil + '\n```')]) {
      assert.equal(html.includes('<script'), false)
      assert.equal(html.includes('<img'), false)
      assert.ok(html.includes('&lt;script&gt;'))
    }
  })

  it('a language tag cannot break out of its attribute', () => {
    assert.equal(parseBody('```"onx=1\nx\n```')[0].lang, '')
  })

  it('MessageBody.vue renders with text interpolation, never v-html', () => {
    const src = readFileSync(join(WUI, 'src/components/MessageBody.vue'), 'utf8')
    assert.equal(/v-html|innerHTML/.test(src), false)
    const card = readFileSync(join(WUI, 'src/components/MessageCard.vue'), 'utf8')
    assert.equal(/v-html/.test(card), false, 'MessageCard no longer uses v-html')
  })

  it('code block CSS scrolls inside the block only (no page x-scroll)', () => {
    const css = readFileSync(join(WUI, 'src/components/MessageBody.vue'), 'utf8')
    assert.ok(/overflow-x:\s*auto/.test(css))
    assert.ok(css.includes('max-width: 100%'))
    assert.equal(/\b100vw\b/.test(css), false)
  })
})

describe('composer state', () => {
  it('typing ``` opens a block, typing ``` again closes it', () => {
    assert.equal(fenceStateAt('hi', 2).inCode, false)
    assert.equal(fenceStateAt('``', 2).inCode, false)
    assert.equal(fenceStateAt('```', 3).inCode, true)
    assert.equal(fenceStateAt('say ```', 7).inCode, true, 'mid-line opener counts in the composer')
    assert.equal(fenceStateAt('```\nfoo\n``', 10).inCode, true)
    assert.equal(fenceStateAt('```\nfoo\n```', 11).inCode, false)
  })

  it('state follows the caret, not the end of the text', () => {
    const s = 'a\n```\nb\n```\nc'
    assert.equal(fenceStateAt(s, s.indexOf('b')).inCode, true)
    assert.equal(fenceStateAt(s, s.length).inCode, false)
  })

  it('inline code in the composer never opens a block', () => {
    assert.equal(fenceStateAt('`a ``` b`', 9).inCode, false)
  })

  it('reports the language of the open block', () => {
    assert.deepEqual(fenceStateAt('```py\nx', 7), { inCode: true, lang: 'py' })
  })

  it('Enter: newline in a block, send outside, Ctrl/Cmd+Enter always sends', () => {
    assert.equal(enterAction({}), 'send')
    assert.equal(enterAction({ shift: true }), 'newline')
    assert.equal(enterAction({ inCode: true }), 'newline')
    assert.equal(enterAction({ inCode: true, mod: true }), 'send')
    assert.equal(enterAction({ mod: true }), 'send')
  })

  it('Esc exits the block with a closing fence on its own line', () => {
    assert.deepEqual(exitFence('```\nfoo', 7), { text: '```\nfoo\n```\n', cursor: 12 })
    assert.deepEqual(exitFence('```\nfoo\n', 8), { text: '```\nfoo\n```\n', cursor: 12 })
    const r = exitFence('```\nfoo\nbar', 7)
    assert.equal(r.text, '```\nfoo\n```\nbar')
    assert.equal(fenceStateAt(r.text, r.cursor).inCode, false)
  })

  it('send closes a block the author left open; balanced text is untouched', () => {
    assert.equal(closeOpenFence('```\nls'), '```\nls\n```')
    assert.equal(closeOpenFence('```\nls\n'), '```\nls\n```')
    assert.equal(closeOpenFence('a ```b``` c'), 'a ```b``` c')
    assert.equal(closeOpenFence('plain'), 'plain')
    assert.deepEqual(parseBody(closeOpenFence('see ```x')), [para(txt('see ')), code('x')])
  })

  it('pasted multi-line code keeps its whitespace on the wire', () => {
    const pasted = '```\n  a\n\tb\n\n    c   \n```'
    assert.equal(closeOpenFence(pasted), pasted)
    assert.equal(parseBody(pasted)[0].text, '  a\n\tb\n\n    c   ')
  })
})
