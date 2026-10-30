// Spec 155 B7 (SPL-4330): a note's links (utils/note-links.mjs). C23 the
// pasted text -> a typed link, C24 the href builder opens a link on its
// workspace's host, C25 a url link's anchor opens in a new tab with
// rel="noopener noreferrer".
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { noteLinkAnchor, noteLinkHref, noteLinkPath, noteLinkText, parseNoteLink } from '../../src/utils/note-links.mjs'

const SITE = 'https://spool.example.com'
const UUID = '0b7f2c3e-1d2a-4b5c-8d9e-0f1a2b3c4d5e'
/* the page is W1's host; W2 is another of the person's workspaces; t1 is the apex */
const W1 = { tenant: 'w1', siteUrl: SITE, apexTenant: 't1', pageOrigin: 'https://w1.spool.example.com', issuePrefix: 'SPL' }

describe('note-links: parseNoteLink (C23)', () => {
  it('topic:<uuid> is a topic of this workspace', () => {
    assert.deepEqual(parseNoteLink(`topic:${UUID}`, W1), { link: { kind: 'topic', workspace_id: 'w1', ref: UUID } })
  })
  it('SPL-12 is an issue of this workspace', () => {
    assert.deepEqual(parseNoteLink('SPL-12', W1), { link: { kind: 'issue', workspace_id: 'w1', ref: 'SPL-12' } })
  })
  it('https://<ws host>/t/<uuid> is a topic, its workspace taken from the host', () => {
    assert.deepEqual(parseNoteLink(`https://w2.spool.example.com/t/${UUID}`, W1), { link: { kind: 'topic', workspace_id: 'w2', ref: UUID } })
  })
  it('https://example.com/a is a url link', () => {
    assert.deepEqual(parseNoteLink('https://example.com/a', W1), { link: { kind: 'url', ref: 'https://example.com/a' } })
  })
  it('javascript:alert(1) is refused', () => {
    assert.deepEqual(parseNoteLink('javascript:alert(1)', W1), { error: 'not_a_link' })
  })
  it('hello is refused', () => {
    assert.deepEqual(parseNoteLink('hello', W1), { error: 'not_a_link' })
  })

  it('every Spool address of the table, locale prefix and apex included', () => {
    const at = (path) => parseNoteLink(`https://w2.spool.example.com${path}`, W1)
    assert.deepEqual(at(`/fi/m/${UUID.toUpperCase()}`), { link: { kind: 'msg', workspace_id: 'w2', ref: UUID } })
    assert.deepEqual(at('/issues?issue=SPL-7'), { link: { kind: 'issue', workspace_id: 'w2', ref: 'SPL-7' } })
    assert.deepEqual(at('/calendar?d=2026-10-30&event=ev-1'), { link: { kind: 'event', workspace_id: 'w2', ref: 'ev-1', day: '2026-10-30' } })
    assert.deepEqual(at('/docs/guides/start.md'), { link: { kind: 'doc', workspace_id: 'w2', ref: 'guides/start.md' } })
    assert.deepEqual(at('/channel/spool-hub'), { link: { kind: 'channel', workspace_id: 'w2', ref: 'spool-hub' } })
    assert.deepEqual(parseNoteLink(`${SITE}/t/${UUID}`, W1), { link: { kind: 'topic', workspace_id: 't1', ref: UUID } }, 'the apex is the apex tenant')
  })

  it('a Spool host with an unknown route, another env and a calendar link with no day stay url links', () => {
    for (const s of ['https://w2.spool.example.com/settings/notes', 'https://w2.dev.spool.example.com/t/' + UUID, 'https://w2.spool.example.com/calendar?event=ev-1']) {
      assert.equal(parseNoteLink(s, W1).link?.kind, 'url', s)
    }
  })

  it('refuses another prefix, a credential URL, data: and text with spaces', () => {
    for (const s of ['ABC-12', 'https://u:p@example.com/', 'data:text/html,x', 'see https://example.com', '', '   ']) {
      assert.deepEqual(parseNoteLink(s, W1), { error: 'not_a_link' }, s)
    }
  })

  it('a typed ref with no workspace to put it in is refused, a url is not', () => {
    const none = { siteUrl: '', issuePrefix: 'SPL' }
    assert.deepEqual(parseNoteLink(`msg:${UUID}`, none), { error: 'no_workspace' })
    assert.deepEqual(parseNoteLink('SPL-3', none), { error: 'no_workspace' })
    assert.equal(parseNoteLink('https://example.com/', none).link?.kind, 'url')
  })

  it('tenant hosts off: only the page origin is this app, in its own workspace', () => {
    const off = { tenant: 'w1', siteUrl: '', apexTenant: 't1', pageOrigin: 'http://localhost:3000' }
    assert.deepEqual(parseNoteLink(`http://localhost:3000/t/${UUID}`, off), { link: { kind: 'topic', workspace_id: 'w1', ref: UUID } })
    assert.equal(parseNoteLink(`http://localhost:4000/t/${UUID}`, off).link?.kind, 'url')
  })
})

describe('note-links: the href builder (C24)', () => {
  const topic = (ws) => ({ kind: 'topic', workspace_id: ws, ref: UUID })
  it('a topic link into W2 opened from W1 opens on W2\'s host', () => {
    assert.deepEqual(noteLinkHref(topic('w2'), W1), { href: `https://w2.spool.example.com/t/${UUID}`, external: false, here: false, path: `/t/${UUID}` })
  })
  it('twin: a W1 link stays on this host', () => {
    assert.deepEqual(noteLinkHref(topic('w1'), W1), { href: `https://w1.spool.example.com/t/${UUID}`, external: false, here: true, path: `/t/${UUID}` })
  })
  it('the apex tenant opens on the apex', () => {
    assert.equal(noteLinkHref(topic('t1'), W1).href, `${SITE}/t/${UUID}`)
  })
  it('the row lookup (resolveTyped) wins when it answers on the same host; the locale prefix is added', () => {
    const typed = () => ({ href: `https://w1.spool.example.com/channel/dev?topic=${UUID}` })
    assert.equal(noteLinkHref(topic('w1'), { ...W1, typed }).href, `https://w1.spool.example.com/channel/dev?topic=${UUID}`)
    const elsewhere = () => ({ href: `https://w9.spool.example.com/t/${UUID}` })
    assert.equal(noteLinkHref(topic('w1'), { ...W1, typed: elsewhere }).href, `https://w1.spool.example.com/t/${UUID}`)
    assert.equal(noteLinkHref(topic('w1'), { ...W1, pathFor: (p) => '/fi' + p }).href, `https://w1.spool.example.com/fi/t/${UUID}`)
  })
  it('each kind\'s path', () => {
    assert.equal(noteLinkPath({ kind: 'msg', ref: UUID }), `/m/${UUID}`)
    assert.equal(noteLinkPath({ kind: 'issue', ref: 'SPL-12' }), '/issues?issue=SPL-12')
    assert.equal(noteLinkPath({ kind: 'event', ref: 'ev 1', day: '2026-10-30' }), '/calendar?d=2026-10-30&event=ev%201')
    assert.equal(noteLinkPath({ kind: 'doc', ref: 'a/b c.md' }), '')
    assert.equal(noteLinkPath({ kind: 'doc', ref: 'a/b.md' }), '/docs/a/b.md')
    assert.equal(noteLinkPath({ kind: 'channel', ref: 'spool-hub' }), '/channel/spool-hub')
    assert.equal(noteLinkPath({ kind: 'topic', ref: 'not-a-uuid' }), '')
  })
  it('tenant hosts off: this workspace opens here, another stays text', () => {
    const off = { tenant: 'w1', siteUrl: '', apexTenant: 't1', pageOrigin: 'http://localhost:3000' }
    assert.equal(noteLinkHref(topic('w1'), off).href, `http://localhost:3000/t/${UUID}`)
    assert.equal(noteLinkHref(topic('w2'), off).href, '')
  })
})

describe('note-links: the anchor (C25)', () => {
  it('a url link opens in a new tab with rel="noopener noreferrer"', () => {
    assert.deepEqual(noteLinkAnchor({ kind: 'url', ref: 'https://example.com/a' }, W1), { href: 'https://example.com/a', target: '_blank', rel: 'noopener noreferrer' })
  })
  it('twin: an app link opens in this tab', () => {
    assert.deepEqual(noteLinkAnchor({ kind: 'issue', workspace_id: 'w1', ref: 'SPL-12' }, W1), { href: 'https://w1.spool.example.com/issues?issue=SPL-12' })
  })
  it('a stored url that is not http(s) never becomes an anchor', () => {
    assert.equal(noteLinkAnchor({ kind: 'url', ref: 'javascript:alert(1)' }, W1), null)
  })
})

describe('note-links: the text shown', () => {
  it('the label, else a short ref', () => {
    assert.equal(noteLinkText({ kind: 'topic', ref: UUID, label: 'Plan' }), 'Plan')
    assert.equal(noteLinkText({ kind: 'topic', ref: UUID, label: '' }), UUID.slice(0, 8))
    assert.equal(noteLinkText({ kind: 'event', ref: 'ev-1', day: '2026-10-30' }), '2026-10-30')
    assert.equal(noteLinkText({ kind: 'url', ref: 'https://example.com/a' }), 'https://example.com/a')
  })
})
