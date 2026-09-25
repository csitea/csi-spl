import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { matchesSearch, newestFirst, parseOmnibox, rootAndReplies, windowed } from '../../src/utils/feed.mjs'
import {
  avatarAlt, avatarAltKey, avatarDataUri, avatarFilesFromView, avatarImageUrl, avatarSvg, hashSeed, identiconSvg, isHuman, isMember,
  avatarImageMime, bytesToDataUri, loadAvatarImageUrl, loadAvatarFiles, resetAvatarFiles, robotSvg,
} from '../../src/utils/avatar.mjs'

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
    assert.deepEqual(parseOmnibox('/search:test'), { search: 'test' })
    assert.deepEqual(parseOmnibox('/s:foo'), { search: 'foo' })
    assert.deepEqual(parseOmnibox('  hello  '), { send: 'hello' })
    assert.deepEqual(parseOmnibox('/searching is fun'), { send: '/searching is fun' })
  })

  it('search matches body, author and file names, case-insensitively', () => {
    const m = { body: 'Build is GREEN', from: 'CLE-07', from_box: 'box-a', files: [{ name: 'Report.PDF' }] }
    for (const q of ['green', 'cle-07@box-a', 'report.pdf', '']) assert.equal(matchesSearch(m, q), true, q)
    assert.equal(matchesSearch(m, 'red'), false)
  })

  it('splits a topic into the oldest root and newest-first replies', () => {
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

describe('stored IdP avatars (gap A5, view-v1 §4.1 humans)', () => {
  const FID = 'ab'.repeat(32)
  const ROSTER = {
    boxes: [],
    humans: [
      { human_id: 'HUM-3', avatar_file_id: FID },
      { human_id: 'HUM-4', avatar_file_id: null },
      { human_id: 'HUM-5', avatar_file_id: '../../etc/passwd' },
      { human_id: 'CLE-07', avatar_file_id: FID },
    ],
  }

  it('keeps only member humans with a sha256 file_id', () => {
    assert.deepEqual(avatarFilesFromView(ROSTER), { 'HUM-3': FID })
    assert.deepEqual(avatarFilesFromView({ boxes: [] }), {})
    assert.deepEqual(avatarFilesFromView(null), {})
  })

  it('builds the tenant-host file URL for a HUM-* with a picture, else "" (draw the default)', () => {
    const files = avatarFilesFromView(ROSTER)
    assert.equal(avatarImageUrl('http://t1.localhost:58081/', 'HUM-3', 'box-wui', files), `http://t1.localhost:58081/v1/files/${FID}`)
    assert.equal(avatarImageUrl('', 'HUM-3', '', files), `/v1/files/${FID}`)
    for (const [id, box] of [['HUM-4', 'box-wui'], ['HUM-9', ''], ['CLE-07', 'box-a'], ['HUM-3', 'box-a'], ['constructor', '']]) {
      assert.equal(avatarImageUrl('http://h', id, box, files), '', `${id}@${box}`)
    }
    assert.equal(avatarImageUrl('http://h', 'HUM-3', '', { 'HUM-3': 'nope' }), '')
  })

  it('names who the picture is (alt text)', () => {
    assert.equal(avatarAlt('HUM-3', 'box-wui'), 'avatar of HUM-3')
    assert.equal(avatarAlt('CLE-07', 'box-a'), 'avatar of CLE-07@box-a')
    assert.equal(avatarAlt(''), 'avatar')
    assert.deepEqual(avatarAltKey('HUM-3', 'box-wui'), { key: 'feed.avatar_of', params: { who: 'HUM-3' } })
    assert.deepEqual(avatarAltKey('CLE-07', 'box-a'), { key: 'feed.avatar_of', params: { who: 'CLE-07@box-a' } })
    assert.deepEqual(avatarAltKey(''), { key: 'feed.avatar', params: {} })
  })

  it('reads the roster once per TTL for every avatar on the page, with the door credentials', async () => {
    resetAvatarFiles()
    const calls = []
    const fetchFn = async (url, opts) => {
      calls.push([url, opts])
      return { ok: true, json: async () => ROSTER }
    }
    let t = 1000
    const now = () => t
    const o = { base: 'http://t1.test/', token: 'tok', credentials: 'include', fetchFn, now }
    const [a, b] = await Promise.all([loadAvatarFiles(o), loadAvatarFiles(o)])
    assert.deepEqual(a, { 'HUM-3': FID })
    assert.equal(a, b)
    assert.equal(calls.length, 1)
    assert.equal(calls[0][0], 'http://t1.test/v1/view/roster')
    assert.equal(calls[0][1].credentials, 'include')
    assert.equal(calls[0][1].headers.authorization, 'Bearer tok')
    t += 60_001
    await loadAvatarFiles(o)
    assert.equal(calls.length, 2)
  })

  it('falls back to no pictures on 401 / network error, never rejects', async () => {
    resetAvatarFiles()
    assert.deepEqual(await loadAvatarFiles({ base: 'http://a', fetchFn: async () => ({ ok: false, status: 401 }) }), {})
    assert.deepEqual(await loadAvatarFiles({ base: 'http://b', fetchFn: async () => { throw new Error('down') } }), {})
    assert.deepEqual(await loadAvatarFiles({ base: 'http://c', fetchFn: null }), {})
    resetAvatarFiles()
  })

  it('recognises png / jpeg / gif / webp by magic bytes, nothing else', () => {
    assert.equal(avatarImageMime(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 13, 10])), 'image/png')
    assert.equal(avatarImageMime(new Uint8Array([0xff, 0xd8, 0xff, 0xe0])), 'image/jpeg')
    assert.equal(avatarImageMime(new TextEncoder().encode('GIF89a')), 'image/gif')
    assert.equal(avatarImageMime(new TextEncoder().encode('RIFF\0\0\0\0WEBPVP8 ')), 'image/webp')
    for (const bad of ['<svg xmlns="http://www.w3.org/2000/svg"/>', '<html>', '']) {
      assert.equal(avatarImageMime(new TextEncoder().encode(bad)), '', bad)
    }
  })

  it('shows the picture as a data: URL (deployed CSP img-src is self data:), once per URL; 404 / non-image / error -> default', async () => {
    resetAvatarFiles()
    const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])
    const calls = []
    const fetchFn = async (url, opts) => {
      calls.push([url, opts])
      if (url.endsWith('/404')) return { ok: false, status: 404 }
      if (url.endsWith('/html')) return { ok: true, arrayBuffer: async () => new TextEncoder().encode('<html>').buffer }
      if (url.endsWith('/boom')) throw new Error('down')
      return { ok: true, arrayBuffer: async () => PNG.buffer }
    }
    const o = { fetchFn }
    const u = `http://t1.test/v1/files/${FID}`
    const want = `data:image/png;base64,${Buffer.from(PNG).toString('base64')}`
    assert.equal(await loadAvatarImageUrl(u, o), want)
    assert.equal(await loadAvatarImageUrl(u, o), want)
    assert.equal(calls.length, 1)
    assert.equal(calls[0][1].credentials, 'omit')
    // 017 FR-SEC-002: in the session door the member cookie rides along.
    assert.equal(await loadAvatarImageUrl(`${u}?s`, { ...o, credentials: 'include' }), want)
    assert.equal(calls[1][1].credentials, 'include')
    for (const tail of ['404', 'html', 'boom']) assert.equal(await loadAvatarImageUrl(`http://t1.test/${tail}`, o), '', tail)
    assert.equal(await loadAvatarImageUrl('', o), '')
    resetAvatarFiles()
  })

  it('CLE-3406: never a blob: URL - every deployed CSP img-src is exactly self + data:', () => {
    const render = readFileSync(new URL('../../../csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh', import.meta.url), 'utf8')
    assert.match(render, /"img-src 'self' data:",/)
    const src = readFileSync(new URL('../../src/utils/avatar.mjs', import.meta.url), 'utf8')
    assert.equal(/createObjectURL/.test(src), false, 'avatar.mjs makes a blob: URL the deployed CSP blocks')
  })

  it('bytesToDataUri survives a picture at the 256 KiB hub cap (chunked)', () => {
    const big = new Uint8Array(256 << 10).map((_, i) => i & 0xff)
    const uri = bytesToDataUri(big, 'image/png')
    assert.ok(uri.startsWith('data:image/png;base64,'))
    assert.deepEqual(Buffer.from(uri.split(',')[1], 'base64'), Buffer.from(big))
  })
})

describe('H5: door-off guests (GST-<n>) are humans but never members', () => {
  it('draws a guest as a human and never gives it a member picture', () => {
    const fid = 'a'.repeat(64)
    assert.equal(isHuman('GST-1'), true)
    assert.equal(isMember('GST-1'), false)
    assert.equal(isMember('HUM-1'), true)
    assert.equal(avatarImageUrl('http://h', 'GST-1', 'box-wui', { 'GST-1': fid }), '')
    assert.equal(avatarImageUrl('http://h', 'HUM-1', 'box-wui', { 'HUM-1': fid }), `http://h/v1/files/${fid}`)
    assert.deepEqual(avatarFilesFromView({ humans: [{ human_id: 'GST-1', avatar_file_id: fid }] }), {})
  })
})
