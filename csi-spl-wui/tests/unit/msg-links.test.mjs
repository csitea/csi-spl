// CLE-3494 — link-like text in a message body becomes a clickable link, in
// the middle topic cards and the right thread / topic panes alike (both render
// through MessageBody.vue -> parseBody).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import { bodyToHtml, linkParts, parseBody, stripBidiControls } from '../../src/utils/code-blocks.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const para = (...parts) => ({ type: 'para', parts })
const txt = (text) => ({ type: 'text', text })
const link = (text, href = text) => ({ type: 'link', text, href })

describe('link parts', () => {
  it('http and https links', () => {
    assert.deepEqual(parseBody('see http://example.com/a?b=1#c now'), [
      para(txt('see '), link('http://example.com/a?b=1#c'), txt(' now')),
    ])
    assert.deepEqual(parseBody('https://example.com'), [para(link('https://example.com'))])
  })

  it('www. host links to https, shown as written', () => {
    assert.deepEqual(parseBody('go to www.example.com/x'), [
      para(txt('go to '), link('www.example.com/x', 'https://www.example.com/x')),
    ])
  })

  it('a bare email links to mailto:', () => {
    assert.deepEqual(parseBody('mail first.last+x@example.co.uk please'), [
      para(txt('mail '), link('first.last+x@example.co.uk', 'mailto:first.last+x@example.co.uk'), txt(' please')),
    ])
  })

  it('trailing punctuation stays outside the link', () => {
    for (const p of ['.', ',', ';', ':', '!', '?', ')', ']', "'", '"', '...', ').']) {
      assert.deepEqual(parseBody(`at https://example.com/x${p}`), [
        para(txt('at '), link('https://example.com/x'), txt(p)),
      ], `trailing ${JSON.stringify(p)}`)
    }
    assert.deepEqual(parseBody('(see https://example.com/x)'), [
      para(txt('(see '), link('https://example.com/x'), txt(')')),
    ])
    assert.deepEqual(parseBody('mail a@example.com.'), [
      para(txt('mail '), link('a@example.com', 'mailto:a@example.com'), txt('.')),
    ])
  })

  it('a balanced paren stays inside', () => {
    assert.deepEqual(parseBody('https://en.wikipedia.org/wiki/Foo_(bar) ok'), [
      para(link('https://en.wikipedia.org/wiki/Foo_(bar)'), txt(' ok')),
    ])
    assert.deepEqual(parseBody('(https://en.wikipedia.org/wiki/Foo_(bar))'), [
      para(txt('('), link('https://en.wikipedia.org/wiki/Foo_(bar)'), txt(')')),
    ])
  })

  it('a URL in inline code or a fenced block stays text', () => {
    assert.deepEqual(parseBody('run `curl https://example.com` now'), [
      para(txt('run '), { type: 'inline', text: 'curl https://example.com' }, txt(' now')),
    ])
    assert.deepEqual(parseBody('```\nhttps://example.com\n```'), [
      { type: 'code', text: 'https://example.com', lang: '', closed: true },
    ])
  })

  it('javascript:, data:, vbscript:, file: stay text', () => {
    for (const s of [
      'javascript:alert(1)',
      'JavaScript:alert(document.cookie)',
      'data:text/html;base64,PHNjcmlwdD4=',
      'vbscript:msgbox(1)',
      'file:///etc/passwd',
      'javascript://example.com/%0aalert(1)',
      'javascript:https://example.com',
      'ftp://example.com/x',
    ]) {
      const parts = parseBody(s).flatMap((b) => b.parts)
      assert.ok(parts.every((p) => p.type !== 'link'), `${s} -> ${JSON.stringify(parts)}`)
    }
  })

  it('every href is http, https or mailto', () => {
    const body = 'a https://x.io b www.y.io c z@w.io d http://q.io/p?x=<y> e javascript:void(0)'
    const hrefs = parseBody(body).flatMap((b) => b.parts).filter((p) => p.type === 'link').map((p) => p.href)
    assert.equal(hrefs.length, 4)
    for (const h of hrefs) assert.match(h, /^(https?:\/\/|mailto:)/)
  })

  it('a scheme without a host is not a link', () => {
    assert.deepEqual(parseBody('https:// and http://.'), [para(txt('https:// and http://.'))])
  })

  it('a mention next to a URL stays a mention', () => {
    assert.deepEqual(parseBody('@CLE-12 https://example.com @GRK-3@box'), [
      para(
        { type: 'mention', text: '@CLE-12' },
        txt(' '),
        link('https://example.com'),
        txt(' '),
        { type: 'mention', text: '@GRK-3@box' },
      ),
    ])
    assert.deepEqual(parseBody('@CLE-12@box.example.com'), [
      para({ type: 'mention', text: '@CLE-12@box' }, txt('.example.com')),
    ])
  })

  it('two URLs in one line', () => {
    assert.deepEqual(parseBody('https://a.example.com and www.b.example.com/x'), [
      para(link('https://a.example.com'), txt(' and '), link('www.b.example.com/x', 'https://www.b.example.com/x')),
    ])
  })

  it('bold text is still bold', () => {
    assert.deepEqual(parseBody('**hi** https://x.io'), [
      para({ type: 'strong', text: 'hi' }, txt(' '), link('https://x.io')),
    ])
  })

  it('linkParts on plain text', () => {
    assert.deepEqual(linkParts('no links here'), [txt('no links here')])
  })

  it('bodyToHtml escapes the href and the text', () => {
    assert.equal(
      bodyToHtml('x https://e.io/?a="b"&c'),
      'x <a class="msg-link" href="https://e.io/?a=&quot;b&quot;&amp;c" target="_blank" rel="noopener noreferrer nofollow">https://e.io/?a=&quot;b&quot;&amp;c</a>',
    )
  })
})

describe('MessageBody.vue renders a link part', () => {
  const src = readFileSync(join(WUI, 'src/components/MessageRuns.vue'), 'utf8')
  const body = readFileSync(join(WUI, 'src/components/MessageBody.vue'), 'utf8')

  it('an anchor uses the shared target: external gets a new tab and no opener', () => {
    assert.match(src, /<a\s[^>]*v-else-if="p\.type === 'link'"/)
    assert.match(src, /:href="p\.href"/)
    assert.match(src, /link-target\.mjs/)
    assert.match(src, /followSameTabLink/)
    assert.match(src, /class="msg-link"/)
    assert.doesNotMatch(src, /target="_blank"/)
    const helper = readFileSync(join(WUI, 'src/utils/link-target.mjs'), 'utf8')
    assert.match(helper, /noopener noreferrer nofollow/)
  })

  it('a click, a double-click or a key on the link never reaches the row', () => {
    assert.match(src, /@click\.stop/)
    assert.match(src, /@dblclick\.stop/)
    assert.match(src, /@keydown\.enter\.stop/)
  })

  it('no v-html', () => {
    assert.doesNotMatch(src, /v-html/)
    assert.doesNotMatch(body, /v-html/)
    assert.match(body, /MessageRuns/)
  })

  it('CLE-34987: link text is bidi-isolated', () => {
    assert.match(src, /\.msg-link \{[^}]*unicode-bidi: isolate/)
  })
})

describe('bidi controls', () => {
  // built from code points: a literal override in this file would itself be the trojan-source shape
  const BIDI = [0x061c, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e, 0x2066, 0x2067, 0x2068, 0x2069].map((c) => String.fromCharCode(c))
  const RLO = String.fromCharCode(0x202e)

  it('a link ends before a bidi control, so the control is never inside link text or href', () => {
    for (const b of BIDI) {
      const parts = linkParts(`https://evil.example/${b}gpj.doog x`)
      const l = parts.find((p) => p.type === 'link')
      assert.ok(l, JSON.stringify(b))
      assert.equal(l.text, 'https://evil.example/')
      assert.equal(l.href.includes(b), false)
    }
  })

  it('an ordinary link is unchanged (control: the class is not over-broad)', () => {
    assert.deepEqual(linkParts('https://example.com/a-b_c~d?e=f'), [link('https://example.com/a-b_c~d?e=f')])
  })

  it('stripBidiControls drops every one and nothing else', () => {
    assert.equal(stripBidiControls(`Ada${BIDI.join('')} Lovelace`), 'Ada Lovelace')
    assert.equal(stripBidiControls(`${RLO}nimda`), 'nimda')
    const he = String.fromCharCode(0x05e9, 0x05dc, 0x05d5, 0x05dd)
    assert.equal(stripBidiControls(`${he} Z`), `${he} Z`)
    assert.equal(stripBidiControls(undefined), '')
  })

  it('the source carries no literal bidi control (escapes only)', () => {
    const code = readFileSync(join(WUI, 'src/utils/code-blocks.mjs'), 'utf8')
    for (const b of BIDI) assert.equal(code.includes(b), false, b.charCodeAt(0).toString(16))
  })
})
