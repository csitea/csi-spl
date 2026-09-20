// Code viewing: the "3 A4" send limit, the bounded preview, grammar names,
// and the token shape the renderer receives (013 FR-016).
//
// The security assertion this file exists for: highlighting must not be able
// to turn message text into markup. Every token is checked to be a plain
// string carrying only a class name, and the joined token text is asserted
// EQUAL to the source — so a `<script>` payload survives as characters, and
// nothing is silently dropped or re-encoded on the way through the grammar.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  A4_PAGE,
  AUTODETECT_LANGS,
  MAX_SEND_PAGES,
  PREVIEW_LIMIT,
  SEND_LIMIT,
  SUPPORTED_LANGS,
  countLines,
  createTokenEmitter,
  lineText,
  measureCode,
  normalizeLang,
  overSendLimit,
  oversizeBlocks,
  plainLines,
  previewOf,
  scopeToClass,
  sendLimitError,
  tokensToLines,
} from '../../src/utils/code-view.mjs'
import { LANG_LOADERS } from '../../src/utils/code-langs.mjs'
import { __resetHighlighter, highlightLines, highlightTokens, loadGrammar, loadedGrammars } from '../../src/utils/highlighter.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const lines = (n, w = 10) => Array.from({ length: n }, () => 'x'.repeat(w)).join('\n')

describe('the "3 A4" send limit', () => {
  it('3 A4 is 150 lines / 9000 characters, derived from ONE page constant', () => {
    assert.equal(MAX_SEND_PAGES, 3)
    assert.deepEqual({ ...A4_PAGE }, { lines: 50, chars: 3000 })
    assert.deepEqual({ ...SEND_LIMIT }, { lines: 150, chars: 9000 })
  })

  it('BOUNDARY by lines: 150 sends, 151 refuses', () => {
    assert.equal(overSendLimit(lines(150, 1)), false)
    assert.equal(overSendLimit(lines(151, 1)), true)
  })

  it('BOUNDARY by characters: 9000 sends, 9001 refuses', () => {
    assert.equal(overSendLimit('y'.repeat(9000)), false)
    assert.equal(overSendLimit('y'.repeat(9001)), true)
  })

  it('a wide snippet is over even with few lines (either axis ends the page)', () => {
    const m = measureCode(lines(10, 1000))
    assert.equal(m.lines, 10)
    assert.ok(m.pages > 3, `pages=${m.pages}`)
    assert.equal(overSendLimit(lines(10, 1000)), true)
  })

  it('counts lines without inventing one for a trailing newline', () => {
    assert.equal(countLines(''), 0)
    assert.equal(countLines('a'), 1)
    assert.equal(countLines('a\n'), 1)
    assert.equal(countLines('a\nb'), 2)
    assert.equal(countLines('a\n\n'), 2)
    assert.equal(countLines('a\r\nb'), 2)
  })
})

describe('sendLimitError: what the composer refuses', () => {
  it('a body with no code block is never refused, however long', () => {
    assert.equal(sendLimitError('word '.repeat(4000)), null)
    assert.deepEqual(oversizeBlocks('plain text'), [])
  })

  it('an over-limit fenced block is refused, and the error names the limit and the actual size', () => {
    const body = '```python\n' + lines(200, 4) + '\n```'
    const err = sendLimitError(body)
    assert.ok(err, 'refused')
    assert.equal(err.key, 'code.too_big')
    assert.equal(err.params.pages, 3)
    assert.equal(err.params.lines, 150)
    assert.equal(err.params.chars, 9000)
    assert.equal(err.params.actual_lines, 200)
    assert.equal(err.blocks[0].index, 1)
    assert.equal(err.blocks[0].lang, 'python')
  })

  it('BOUNDARY through the parser: a 150-line block sends, a 151-line block does not', () => {
    assert.equal(sendLimitError('```\n' + lines(150, 1) + '\n```'), null)
    assert.ok(sendLimitError('```\n' + lines(151, 1) + '\n```'))
  })

  it('the worst block is the one reported, and every over-limit block is listed', () => {
    const body = '```\n' + lines(160, 1) + '\n```\ntext\n```sql\n' + lines(400, 1) + '\n```'
    const err = sendLimitError(body)
    assert.equal(err.blocks.length, 2)
    assert.deepEqual(err.blocks.map((b) => b.index), [1, 2])
    assert.equal(err.params.actual_lines, 400)
  })

  it('an unclosed block (an agent pasting truncated output) is measured too', () => {
    assert.ok(sendLimitError('log:\n```\n' + lines(400, 1)))
  })

  it('CONTROL: an over-limit run of INLINE code is not a block and is not refused', () => {
    assert.equal(sendLimitError('`' + 'z'.repeat(20000) + '`'), null)
  })
})

describe('previewOf: the bounded card preview', () => {
  it('a short snippet is shown whole and is not marked truncated', () => {
    const p = previewOf('a\nb\nc')
    assert.equal(p.text, 'a\nb\nc')
    assert.equal(p.truncated, false)
    assert.equal(p.hiddenLines, 0)
  })

  it('past the line budget it cuts and reports what is hidden', () => {
    const p = previewOf(lines(60, 4))
    assert.equal(p.shownLines, PREVIEW_LIMIT.lines)
    assert.equal(p.totalLines, 60)
    assert.equal(p.hiddenLines, 60 - PREVIEW_LIMIT.lines)
    assert.equal(p.truncated, true)
    assert.equal(countLines(p.text), PREVIEW_LIMIT.lines)
  })

  it('the character budget also cuts, and always on a line boundary', () => {
    const p = previewOf(lines(20, 400))
    assert.ok(p.shownLines < 20, `shown=${p.shownLines}`)
    assert.ok(p.text.length <= PREVIEW_LIMIT.chars, p.text.length)
    assert.equal(p.text.includes('\n' + 'x'.repeat(399) + '\n'), p.shownLines > 2)
    assert.ok(p.text.split('\n').every((l) => l.length === 400))
  })

  it('one huge first line is still shown (wrapping, not scrolling, makes it readable)', () => {
    const p = previewOf('z'.repeat(50000))
    assert.equal(p.shownLines, 1)
    assert.equal(p.truncated, false)
    assert.equal(p.text.length, 50000)
  })

  it('the preview is a PREFIX of the source, byte for byte', () => {
    const src = lines(80, 30)
    assert.ok(src.startsWith(previewOf(src).text))
  })
})

describe('grammar names', () => {
  it('fence tags map onto grammars, case-insensitively', () => {
    assert.equal(normalizeLang('JS'), 'javascript')
    assert.equal(normalizeLang('ts'), 'typescript')
    assert.equal(normalizeLang('sh'), 'bash')
    assert.equal(normalizeLang('c++'), 'cpp')
    assert.equal(normalizeLang('yml'), 'yaml')
    assert.equal(normalizeLang(' Python '), 'python')
  })

  it('an unknown or plain tag is no grammar', () => {
    assert.equal(normalizeLang(''), '')
    assert.equal(normalizeLang('klingon'), '')
    assert.equal(normalizeLang('text'), '')
    assert.equal(normalizeLang('constructor'), '')
    assert.equal(normalizeLang('__proto__'), '')
  })

  it('the loader table and SUPPORTED_LANGS are the same set (half an addition fails here)', () => {
    assert.deepEqual(Object.keys(LANG_LOADERS).sort(), [...SUPPORTED_LANGS].sort())
  })

  it('every alias target is a supported grammar or the empty string', () => {
    for (const g of AUTODETECT_LANGS) assert.ok(SUPPORTED_LANGS.includes(g), g)
  })

  it('every grammar in the table exists on disk (a typo is a 404 at runtime otherwise)', () => {
    const dir = join(WUI, 'node_modules/highlight.js/lib/languages')
    const have = new Set(readdirSync(dir).filter((f) => f.endsWith('.js')).map((f) => f.slice(0, -3)))
    for (const g of SUPPORTED_LANGS) assert.ok(have.has(g), `highlight.js has no grammar ${g}`)
  })
})

describe('tokens: lines in, lines out, nothing becomes markup', () => {
  it('scopeToClass matches what highlight.js own renderer would emit', () => {
    assert.equal(scopeToClass('keyword'), 'hljs-keyword')
    assert.equal(scopeToClass('title.function_'), 'hljs-title function__')
    assert.equal(scopeToClass('comment.line'), 'hljs-comment line_')
    assert.equal(scopeToClass('language:xml'), 'language-xml')
    assert.equal(scopeToClass('keyword', 'x-'), 'x-keyword')
  })

  it('the emitter appends flat runs and inherits open scopes — it builds no HTML', () => {
    const E = createTokenEmitter()
    const e = new E({ classPrefix: 'hljs-' })
    e.addText('a ')
    e.startScope('string')
    e.addText('b')
    e.startScope('subst')
    e.addText('c')
    e.endScope()
    e.endScope()
    e.finalize()
    assert.deepEqual(e.tokens, [
      { text: 'a ', cls: '' },
      { text: 'b', cls: 'hljs-string' },
      { text: 'c', cls: 'hljs-string hljs-subst' },
    ])
    // the one place HTML could have been built returns nothing, on purpose
    assert.equal(e.toHTML(), '')
  })

  it('the emitter joins adjacent runs of the same scope and drops empty text', () => {
    const E = createTokenEmitter()
    const e = new E({})
    e.addText('a')
    e.addText('')
    e.addText('b')
    assert.deepEqual(e.tokens, [{ text: 'ab', cls: '' }])
  })

  it('an embedded language keeps both scopes (CSS inside HTML)', () => {
    const E = createTokenEmitter()
    const outer = new E({})
    const inner = new E({})
    inner.startScope('keyword')
    inner.addText('color')
    inner.endScope()
    outer.startScope('tag')
    outer.__addSublanguage(inner, 'css')
    assert.deepEqual(outer.tokens, [{ text: 'color', cls: 'hljs-tag language-css hljs-keyword' }])
  })

  it('tokensToLines splits on newlines and keeps blank lines', () => {
    assert.deepEqual(tokensToLines([{ text: 'a\n\nb', cls: 'k' }]), [
      [{ text: 'a', cls: 'k' }],
      [],
      [{ text: 'b', cls: 'k' }],
    ])
  })

  it('a token that ends on a newline does not open an empty last line', () => {
    assert.equal(tokensToLines([{ text: 'a\n', cls: '' }]).length, 1)
    assert.equal(plainLines('a\nb\n').length, 2)
    assert.equal(plainLines('').length, 1)
  })

  it('CONTROL: the joined token text equals the source exactly', () => {
    const src = 'def f():\n\n\treturn "x"\n'
    assert.equal(plainLines(src).map(lineText).join('\n'), src.replace(/\n$/, ''))
  })
})

describe('the highlighter (highlight.js + our emitter): tokens, never markup', () => {
  it('a known fence tag highlights, and every token is a plain string plus a class', async () => {
    __resetHighlighter()
    const toks = await highlightTokens('def f(x):\n    return 1', 'py')
    assert.ok(toks.length > 1, 'more than one token = it highlighted')
    for (const t of toks) {
      assert.equal(typeof t.text, 'string')
      assert.equal(typeof t.cls, 'string')
      assert.deepEqual(Object.keys(t).sort(), ['cls', 'text'])
      assert.match(t.cls, /^[A-Za-z0-9 _-]*$/, t.cls)
    }
    assert.equal(toks.map((t) => t.text).join(''), 'def f(x):\n    return 1')
  })

  it('CONTROL: a <script> payload stays text — no markup, no entity rewriting', async () => {
    __resetHighlighter()
    const payload = '<script>alert(1)</script><img src=x onerror="alert(2)">'
    const src = `const a = "${payload}" // ${payload}\n${payload}`
    for (const lang of ['js', '', 'html', 'unknownlang']) {
      const toks = await highlightTokens(src, lang)
      assert.equal(toks.map((t) => t.text).join(''), src, `lang=${lang}`)
      for (const t of toks) assert.equal(/[<>]/.test(t.cls), false, t.cls)
    }
  })

  it('an unknown grammar falls back to plain text rather than throwing', async () => {
    __resetHighlighter()
    const toks = await highlightTokens('hello', 'klingon')
    assert.deepEqual(toks, [{ text: 'hello', cls: '' }])
  })

  it('auto-detect only guesses between grammars this page has ALREADY loaded', async () => {
    __resetHighlighter()
    assert.deepEqual(loadedGrammars(), [])
    // nothing loaded yet -> plain, no network, no new chunk
    assert.deepEqual(await highlightTokens('SELECT 1 FROM t', ''), [{ text: 'SELECT 1 FROM t', cls: '' }])
    await loadGrammar('sql')
    assert.deepEqual(loadedGrammars(), ['sql'])
    const toks = await highlightTokens('SELECT a, b FROM t WHERE a = 1', '')
    assert.ok(toks.some((t) => t.cls.includes('hljs-keyword')), JSON.stringify(toks))
  })

  it('CONTROL: prose is left plain rather than coloured as the one loaded grammar', async () => {
    __resetHighlighter()
    await loadGrammar('sql')
    const prose = 'the quick brown fox jumps over the lazy dog'
    assert.deepEqual(await highlightTokens(prose, ''), [{ text: prose, cls: '' }])
  })

  it('highlightLines returns one row per source line, losing nothing', async () => {
    __resetHighlighter()
    const src = 'a = 1\n\nb = "two"\n\tc'
    const rows = await highlightLines(src, 'python')
    assert.equal(rows.length, 4)
    assert.equal(rows.map(lineText).join('\n'), src)
    assert.deepEqual(rows[1], [])
  })

  it('an empty snippet needs no engine at all', async () => {
    __resetHighlighter()
    assert.deepEqual(await highlightTokens('', 'js'), [])
    assert.deepEqual(loadedGrammars(), [])
  })
})

describe('no eval and no injected stylesheet (CSP: no unsafe-eval / unsafe-inline)', () => {
  const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
  /** Comments explain what the code does NOT do, so they are not evidence either way. */
  const code = (rel) => read(rel).replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

  it('our modules never eval and never write a <style> or innerHTML', () => {
    for (const f of ['src/utils/code-view.mjs', 'src/utils/highlighter.mjs', 'src/utils/code-langs.mjs']) {
      const src = code(f)
      assert.equal(/\beval\s*\(|new Function|innerHTML|insertAdjacentHTML|document\.write/.test(src), false, f)
    }
    // CONTROL: the stripper does not simply blank the file
    assert.ok(code('src/utils/highlighter.mjs').includes('highlightTokens'))
  })

  it('the highlight.js runtime we ship never evals either', () => {
    const src = read('node_modules/highlight.js/lib/core.js')
    assert.equal(/\beval\s*\(|new Function\s*\(/.test(src), false)
    assert.equal(/WebAssembly/.test(src), false)
    // and the emitter we hand it never produces a markup string
    assert.equal(/<span|innerHTML/.test(code('src/utils/code-view.mjs')), false)
  })

  it('the grammars are lazy: every loader is a literal import() the bundler can split', () => {
    const src = read('src/utils/code-langs.mjs')
    const literal = [...src.matchAll(/\(\) => import\('highlight\.js\/lib\/languages\/([a-z0-9]+)'\)/g)].map((m) => m[1])
    assert.deepEqual(literal.sort(), [...SUPPORTED_LANGS].sort())
    // a computed specifier would pull every grammar into the graph
    assert.equal(/import\(\s*[`'"][^`'"]*\$\{|import\(\s*\w/.test(src), false)
  })

  it('nothing imports highlight.js statically (that would put it in the main bundle)', () => {
    for (const f of ['src/utils/highlighter.mjs', 'src/utils/code-langs.mjs', 'src/utils/code-view.mjs']) {
      assert.equal(/^\s*import\s[^\n]*from\s*['"](lowlight|highlight\.js)/m.test(read(f)), false, f)
    }
  })

  it('lowlight is NOT a dependency: its only entry re-exports every grammar', () => {
    // measured 2026-09-20: keeping it cost one 806 KB chunk in the initial graph
    const pkg = JSON.parse(read('package.json'))
    assert.equal('lowlight' in (pkg.dependencies || {}), false)
    assert.equal('lowlight' in (pkg.devDependencies || {}), false)
    assert.ok(pkg.dependencies['highlight.js'], 'highlight.js is a direct, pinned dependency')
  })
})
