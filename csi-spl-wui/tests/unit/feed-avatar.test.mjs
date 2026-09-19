import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { matchesSearch, newestFirst, parseOmnibox, rootAndReplies, windowed } from '../../src/utils/feed.mjs'
import { avatarDataUri, avatarSvg, hashSeed, identiconSvg, isHuman, robotSvg } from '../../src/utils/avatar.mjs'

const M = (id, ts, extra = {}) => ({ msg_id: id, ts, body: `b-${id}`, from: 'HUM-1', ...extra })

describe('feed (013 reverse prepend)', () => {
  it('orders newest first, stable on ties', () => {
    const rows = newestFirst([M('a', '1'), M('c', '3'), M('b', '2'), M('d', '3')])
    assert.deepEqual(rows.map((m) => m.msg_id), ['d', 'c', 'b', 'a'])
  })

  it('prefers received_at over ts', () => {
    const rows = newestFirst([M('x', '9', { received_at: '1' }), M('y', '2')])
    assert.deepEqual(rows.map((m) => m.msg_id), ['y', 'x'])
  })

  it('windows and reports older rows', () => {
    const rows = [1, 2, 3, 4, 5].map((n) => M(String(n), String(n)))
    assert.deepEqual(windowed(rows, 2).rows.length, 2)
    assert.equal(windowed(rows, 2).hasOlder, true)
    assert.equal(windowed(rows, 5).hasOlder, false)
  })

  it('parses the Omnibox: /search filters, anything else sends', () => {
    assert.deepEqual(parseOmnibox('/search build green'), { search: 'build green' })
    assert.deepEqual(parseOmnibox('/s x'), { search: 'x' })
    assert.deepEqual(parseOmnibox('/search'), { search: '' })
    assert.deepEqual(parseOmnibox('  hello  '), { send: 'hello' })
    assert.deepEqual(parseOmnibox('/searching is fun'), { send: '/searching is fun' })
  })

  it('search matches body, author and file names, case-insensitively', () => {
    const m = { body: 'Build is GREEN', from: 'CLE-07', from_box: 'box-a', files: [{ name: 'Report.PDF' }] }
    for (const q of ['green', 'cle-07@box-a', 'report.pdf', '']) assert.equal(matchesSearch(m, q), true, q)
    assert.equal(matchesSearch(m, 'red'), false)
  })

  it('splits a thread into the oldest root and newest-first replies', () => {
    const { root, replies } = rootAndReplies([M('b', '2'), M('a', '1'), M('c', '3')])
    assert.equal(root.msg_id, 'a')
    assert.deepEqual(replies.map((m) => m.msg_id), ['c', 'b'])
    assert.deepEqual(rootAndReplies([]), { root: null, replies: [] })
  })
})

describe('avatars (SPEC-spool-avatars §2)', () => {
  it('humans get an identicon, agents a robot', () => {
    assert.equal(isHuman('HUM-1'), true)
    assert.equal(isHuman('CLE-07'), false)
    assert.equal(avatarSvg('HUM-1', 'box-wui'), identiconSvg('HUM-1@box-wui'))
    assert.equal(avatarSvg('CLE-07', 'box-a'), robotSvg('CLE-07@box-a'))
  })

  it('is deterministic per id@box and distinct across ids', () => {
    assert.equal(robotSvg('CLE-07@box-a'), robotSvg('CLE-07@box-a'))
    const set = new Set(['CLE-01', 'CLE-02', 'GRK-03', 'AGY-04', 'CLE-07@box-a', 'CLE-07@box-b'].map((k) => robotSvg(k)))
    assert.equal(set.size, 6)
    assert.notEqual(hashSeed('a'), hashSeed('b'))
  })

  it('tints the chassis by prefix', () => {
    assert.match(robotSvg('CLE-07'), /hsl\((1[5-9]\d) /)
    assert.match(robotSvg('GRK-03'), /hsl\(([0-9]|[1-4]\d) /)
    assert.match(robotSvg('AGY-02'), /hsl\((2[5-9]\d) /)
  })

  it('is a self-contained SVG data URI without user text', () => {
    const uri = avatarDataUri('CLE-07', 'box"><script>')
    assert.ok(uri.startsWith('data:image/svg+xml;utf8,'))
    const svg = decodeURIComponent(uri.split(',').slice(1).join(','))
    assert.equal(svg.includes('script'), false)
    assert.equal(svg.includes('box'), false)
    assert.ok(svg.startsWith('<svg') && svg.endsWith('</svg>'))
  })
})
