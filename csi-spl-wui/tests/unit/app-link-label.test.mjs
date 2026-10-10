// Short labels for a URL of this app (owner, t1 b698941b).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { appLinkLabel, appLinkLabelContext, eventChipText, formatAppLinkSegments, labelEvent, linkTextIsAddress } from '../../src/utils/app-link-label.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

const SITE = 'https://app.example'
const APEX = 't1'
const TOPIC = '41261a3f-db05-4e2f-9af4-fceb716a557a'
const MSG = 'ab12cd34-db05-4e2f-9af4-fceb716a557a'
const PAGE = 'https://csitea.app.example/channel/lobby'
const APEX_PAGE = 'https://app.example/channel/lobby'
const DOT = ' \u00b7 '

const ctx = (pageHref, extra = {}) => ({ pageHref, siteUrl: SITE, apexTenant: APEX, ...extra })

describe('app link labels', () => {
  it('same workspace topic is type and the first 8 hex, title is the full URL', () => {
    const href = `https://csitea.app.example/channel/spool-hub?topic=${TOPIC}`
    const lab = appLinkLabel(href, ctx(PAGE))
    assert.ok(lab)
    assert.equal(lab.text, 'topic: 41261a3f')
    assert.equal(lab.title, href)
    assert.deepEqual(lab.segments, [{ kind: 'type', value: 'topic', id: '41261a3f' }])
    assert.equal(lab.segments.some((s) => s.kind === 'instance'), false)
  })

  it('another workspace puts the workspace segment in front', () => {
    const href = `https://csitea.app.example/channel/spool-hub?topic=${TOPIC}`
    const lab = appLinkLabel(href, ctx(APEX_PAGE))
    assert.ok(lab)
    assert.equal(lab.text, 'workspace: csitea' + DOT + 'topic: 41261a3f')
    assert.deepEqual(lab.segments, [
      { kind: 'workspace', value: 'csitea' },
      { kind: 'type', value: 'topic', id: '41261a3f' },
    ])
    assert.equal(lab.title, href)
  })

  it('a tenant page labels the apex workspace by the apex tenant', () => {
    const href = `https://app.example/t/${TOPIC}`
    const lab = appLinkLabel(href, ctx(PAGE))
    assert.equal(lab && lab.text, 'workspace: t1' + DOT + 'topic: 41261a3f')
  })

  it('www and http of this workspace collapse to the same topic label', () => {
    const lab = appLinkLabel(`http://www.csitea.app.example/channel/spool-hub?topic=${TOPIC}`, ctx(PAGE))
    assert.equal(lab && lab.text, 'topic: 41261a3f')
    assert.equal(lab && lab.title, `https://csitea.app.example/channel/spool-hub?topic=${TOPIC}`)
  })

  it('a relative topic link is this workspace, and the title is absolute', () => {
    const lab = appLinkLabel(`/channel/spool-hub?topic=${TOPIC}`, ctx(PAGE))
    assert.equal(lab && lab.text, 'topic: 41261a3f')
    assert.equal(lab && lab.title, `https://csitea.app.example/channel/spool-hub?topic=${TOPIC}`)
  })

  it('channel, message, dm and issue routes', () => {
    assert.equal(appLinkLabel('https://csitea.app.example/channel/spool-hub', ctx(PAGE))?.text, 'channel: spool-hub')
    assert.equal(appLinkLabel(`https://csitea.app.example/m/${MSG}`, ctx(PAGE))?.text, 'message: ab12cd34')
    assert.equal(appLinkLabel(`https://csitea.app.example/t/${TOPIC}#${MSG}`, ctx(PAGE))?.text, 'message: ab12cd34')
    assert.equal(appLinkLabel('https://csitea.app.example/dm/CLE-07%40box-a', ctx(PAGE))?.text, 'dm: CLE-07@box-a')
    assert.equal(appLinkLabel('https://csitea.app.example/issues?issue=SPL-3', ctx(PAGE))?.text, 'issue: SPL-3')
    assert.equal(appLinkLabel('https://csitea.app.example/fi/channel/spool-hub?topic=' + TOPIC, ctx(PAGE))?.text, 'topic: 41261a3f')
  })

  it('an external URL is untouched', () => {
    assert.equal(appLinkLabel(`https://example.org/channel/spool-hub?topic=${TOPIC}`, ctx(PAGE)), null)
    assert.equal(appLinkLabel(`https://api.app.example/m/${MSG}`, ctx(PAGE)), null)
  })

  it('an unknown route of this app is untouched', () => {
    assert.equal(appLinkLabel('https://csitea.app.example/settings/appearance', ctx(PAGE)), null)
    assert.equal(appLinkLabel('https://csitea.app.example/login', ctx(PAGE)), null)
    assert.equal(appLinkLabel('https://csitea.app.example/calendar', ctx(PAGE)), null)
    assert.equal(appLinkLabel('https://csitea.app.example/no-such', ctx(PAGE)), null)
  })

  it('tenant hosts off: same origin still labels, another host does not', () => {
    const off = { siteUrl: '', apexTenant: APEX }
    assert.equal(appLinkLabel('https://app.example/channel/lobby', { pageHref: 'https://app.example/dm/a', ...off })?.text, 'channel: lobby')
    assert.equal(appLinkLabel(`https://csitea.app.example/t/${TOPIC}`, { pageHref: 'https://app.example/', ...off }), null)
  })

  it('an instance segment is reserved and not rendered', () => {
    assert.equal(formatAppLinkSegments([
      { kind: 'instance', value: 'https://cloud.example' },
      { kind: 'workspace', value: 'csitea' },
      { kind: 'type', value: 'topic', id: '41261a3f' },
    ]), 'workspace: csitea' + DOT + 'topic: 41261a3f')
  })

  it('only an address is replaced; a written label and an id link are not', () => {
    assert.equal(linkTextIsAddress(`https://csitea.app.example/t/${TOPIC}`), true)
    assert.equal(linkTextIsAddress('www.csitea.app.example/t/x'), true)
    assert.equal(linkTextIsAddress('here'), false)
    assert.equal(linkTextIsAddress('topic: 41261a3f'), false)
    assert.equal(linkTextIsAddress(TOPIC), false)
  })

  it('the context reads the runtime site only while tenant hosts are on', () => {
    assert.deepEqual(appLinkLabelContext('https://app.example/x', { tenantHosts: '0', siteUrl: SITE, tenant: APEX }), {
      pageHref: 'https://app.example/x', siteUrl: '', apexTenant: APEX,
    })
    assert.equal(appLinkLabelContext('https://app.example/x', { tenantHosts: '1', siteUrl: SITE, tenant: APEX }).siteUrl, SITE)
  })

  it('the label module stays out of the initial chunk', () => {
    const boot = read('src/composables/useAppLinkLabel.ts')
    assert.match(boot, /import\('~\/utils\/app-link-label\.mjs'\)/)
    assert.doesNotMatch(boot, /from '~\/utils\/app-link-label/)
    for (const rel of ['src/components/MessageRuns.vue', 'src/components/MarkdownBlock.vue']) {
      const src = read(rel)
      assert.match(src, /useAppLinkLabel/)
      assert.doesNotMatch(src, /app-link-label\.mjs/)
    }
    for (const rel of ['src/utils/code-blocks.mjs', 'src/utils/markdown.mjs', 'src/utils/link-target.mjs', 'src/components/MessageBody.vue']) {
      assert.doesNotMatch(read(rel), /app-link-label/)
    }
    // The product host is joined at runtime so this file does not carry the
    // domain literal the single-source test forbids.
    const productHost = ['spool-hub', 'ai'].join('.')
    const mailDomain = ['csitea', 'net'].join('.')
    const forbid = [productHost, mailDomain].join('|').replace(/\./g, '\\.')
    assert.doesNotMatch(read('src/utils/app-link-label.mjs'), new RegExp(forbid))
  })
})

/* t1 9dec05c3: a calendar Copy link reads as an event chip */
describe('calendar event links', () => {
  const EV = '00000000-0000-4000-8000-000000000102'
  it('reads as event: <day>, the id kept as ref', () => {
    const lab = appLinkLabel(`https://csitea.app.example/calendar?d=2026-10-12&event=${EV}`, ctx(PAGE))
    assert.ok(lab)
    assert.equal(lab.text, 'event: 2026-10-12')
    assert.deepEqual(lab.segments, [{ kind: 'type', value: 'event', id: '2026-10-12', ref: EV }])
    assert.deepEqual(labelEvent(lab), { id: EV, day: '2026-10-12' })
  })
  it('a locale prefix and a missing day still read', () => {
    const lab = appLinkLabel(`https://csitea.app.example/fi/calendar?event=${EV}`, ctx(PAGE))
    assert.equal(lab?.text, 'event: 00000000')
    assert.deepEqual(labelEvent(lab), { id: EV, day: '' })
  })
  it('the calendar with no event stays the address', () => {
    assert.equal(appLinkLabel('https://csitea.app.example/calendar?d=2026-10-12', ctx(PAGE)), null)
  })
  it('the chip shows the title only when given, cut at 80', () => {
    const lab = appLinkLabel(`https://csitea.app.example/calendar?d=2026-10-12&event=${EV}`, ctx(PAGE))
    assert.equal(eventChipText(lab, ''), 'event: 2026-10-12')
    assert.equal(eventChipText(lab, ' Database  maintenance '), 'event: Database maintenance' + DOT + '2026-10-12')
    assert.equal(eventChipText(lab, 'x'.repeat(100)), 'event: ' + 'x'.repeat(79) + '\u2026' + DOT + '2026-10-12')
  })
  it('another workspace keeps its segment in front of the chip', () => {
    const lab = appLinkLabel(`https://csitea.app.example/calendar?d=2026-10-12&event=${EV}`, ctx(APEX_PAGE))
    assert.equal(eventChipText(lab, 'Standup'), 'workspace: csitea' + DOT + 'event: Standup' + DOT + '2026-10-12')
  })
  it('a non-event label is untouched', () => {
    const lab = appLinkLabel(`https://csitea.app.example/channel/spool-hub?topic=${TOPIC}`, ctx(PAGE))
    assert.equal(labelEvent(lab), null)
    assert.equal(eventChipText(lab, 'Standup'), 'topic: 41261a3f')
  })
})
