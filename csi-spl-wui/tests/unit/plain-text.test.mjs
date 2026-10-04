import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { plainText } from '../../src/utils/plain-text.mjs'

// spec 082 AC1: a list row shows the text, never the markdown marks
describe('plainText (082 AC1)', () => {
  it('removes emphasis and keeps channel names and mentions', () => {
    assert.equal(plainText('Welcome to **#lobby**.'), 'Welcome to #lobby.')
    assert.equal(plainText('ask @c-001 in #ops'), 'ask @c-001 in #ops')
    assert.equal(plainText('*one* _two_ __three__ ~~four~~'), 'one two three four')
  })

  it('removes code ticks, link and image syntax', () => {
    assert.equal(plainText('`x`'), 'x')
    assert.equal(plainText('run ``a `b` c``'), 'run a `b` c')
    assert.equal(plainText('[docs](https://example.com)'), 'docs')
    assert.equal(plainText('see ![chart](https://example.com/c.png) now'), 'see chart now')
    assert.equal(plainText('<https://example.com>'), 'https://example.com')
  })

  it('removes block marks: quotes, headings, bullets, fences', () => {
    assert.equal(plainText('> quote'), 'quote')
    assert.equal(plainText('# Title'), 'Title')
    assert.equal(plainText('### Title ###'), 'Title')
    assert.equal(plainText('- one\n* two\n1. three'), 'one two three')
    assert.equal(plainText('- [x] done'), 'done')
    assert.equal(plainText('```sh\nls\n```'), 'ls')
  })

  it('leaves plain text that only looks like markup', () => {
    assert.equal(plainText('snake_case_name'), 'snake_case_name')
    assert.equal(plainText('2 * 3 * 4'), '2 * 3 * 4')
    assert.equal(plainText('#lobby'), '#lobby')
    assert.equal(plainText('\\*not bold\\*'), '*not bold*')
  })

  it('collapses whitespace and cuts at max with "…"', () => {
    assert.equal(plainText('  a\n\n  b  '), 'a b')
    assert.equal(plainText('a'.repeat(120), 100), 'a'.repeat(100) + '…')
    assert.equal(plainText('a'.repeat(100), 100), 'a'.repeat(100))
    assert.equal(plainText('ä'.repeat(101), 100), 'ä'.repeat(100) + '…')
    assert.equal(plainText('a'.repeat(120)), 'a'.repeat(120))
  })

  it('treats null and undefined as empty', () => {
    assert.equal(plainText(null), '')
    assert.equal(plainText(undefined, 10), '')
  })
})
