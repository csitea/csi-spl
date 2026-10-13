// SPL-1609 (owner HUM-10, t1 51363151): an email address or a phone number in
// a message opens the app the reader picked in Settings -> Behaviour. The
// values are pinned equal to the hub's (auth.ViewPrefs) and to rdb 0187's
// CHECKs; never picked = Gmail in the browser / WhatsApp (owner f8d7f523,
// 81228b5b). A phone number links only standing on its own: a commit hash,
// a date, a time, an order number and a version stay text.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  EMAIL_CLIENTS, PHONE_APPS, parseEmailClient, parsePhoneApp,
  emailHref, phoneHref, contactHref, phoneParts, phoneBlocks,
} from '../../src/utils/contact-links.mjs'
import { parseBody } from '../../src/utils/code-blocks.mjs'
import { markdownTree } from '../../src/utils/markdown.mjs'
import { linkOpen } from '../../src/utils/link-target.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')
const links = (blocks) => blocks.flatMap((b) => (b.parts || (b.items || []).flatMap((i) => i.parts) || [])).filter((p) => p.type === 'link')
function mdLinks(nodes, out = []) {
  for (const n of nodes) if (typeof n !== 'string') { if (n.tag === 'a') out.push(n.attrs.href); mdLinks(n.children, out) }
  return out
}

describe('the two settings', () => {
  it('hub, rdb 0187 and the WUI admit the same values, default first', () => {
    assert.deepEqual([...EMAIL_CLIENTS], ['gmail', 'system', 'outlook-web', 'outlook', 'thunderbird'])
    assert.deepEqual([...PHONE_APPS], ['whatsapp', 'tel', 'viber', 'telegram', 'signal', 'teams'])
    const go = read('../csi-spl-api/src/go/spool-hub-api/internal/auth/handler.go')
    assert.match(go, /PrefEmailClient: +\{"gmail", "system", "outlook-web", "outlook", "thunderbird"\}/)
    assert.match(go, /PrefPhoneApp: +\{"whatsapp", "tel", "viber", "telegram", "signal", "teams"\}/)
    const sql = read('../csi-spl-rdb/src/sql/postgres/spool-hub/0187_human_contact_links.sql')
    assert.match(sql, /email_client IN \('gmail','system','outlook-web','outlook','thunderbird'\)/)
    assert.match(sql, /phone_app IN \('whatsapp','tel','viber','telegram','signal','teams'\)/)
  })
  it('anything unknown or never picked reads as the default', () => {
    for (const raw of [null, undefined, '', 'Gmail', 'proton']) assert.equal(parseEmailClient(raw), 'gmail')
    for (const raw of [null, undefined, '', 'WhatsApp', 'skype']) assert.equal(parsePhoneApp(raw), 'whatsapp')
    assert.equal(parseEmailClient('thunderbird'), 'thunderbird')
    assert.equal(parsePhoneApp('signal'), 'signal')
  })
  it('every locale names both settings, each value and the hint', () => {
    for (const code of readdirSync(join(WUI, 'i18n/locales')).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5))) {
      const s = JSON.parse(read(`i18n/locales/${code}.json`)).settings
      for (const [k, vals] of [['email_client', EMAIL_CLIENTS], ['phone_app', PHONE_APPS]]) {
        assert.ok(s[k].label && s[k].hint, `${code} ${k}`)
        for (const v of vals) assert.ok(s[k][v.replace('-', '_')], `${code} ${k}.${v}`)
      }
    }
  })
})

describe('email links per client', () => {
  const to = 'mailto:person@example.com'
  it('no stored choice = the Gmail compose url', () => {
    assert.equal(emailHref(to, null), 'https://mail.google.com/mail/?view=cm&fs=1&to=person%40example.com')
    assert.equal(contactHref(to, {}), 'https://mail.google.com/mail/?view=cm&fs=1&to=person%40example.com')
  })
  it('Outlook on the web is its compose deeplink', () => {
    assert.equal(emailHref(to, 'outlook-web'), 'https://outlook.office.com/mail/deeplinkcompose?to=person%40example.com')
  })
  it('control: system, desktop Outlook and Thunderbird keep the mailto: link', () => {
    for (const c of ['system', 'outlook', 'thunderbird']) assert.equal(emailHref(to, c), 'mailto:person@example.com', c)
  })
  it('keeps subject, body and cc, url-encoded', () => {
    const m = 'mailto:a@example.com?subject=Hello%20there%20%26%20more&body=line%201%0Aline%202&cc=b@example.com'
    assert.equal(emailHref(m, 'gmail'),
      'https://mail.google.com/mail/?view=cm&fs=1&to=a%40example.com&su=Hello%20there%20%26%20more&body=line%201%0Aline%202&cc=b%40example.com')
    assert.equal(emailHref(m, 'outlook-web'),
      'https://outlook.office.com/mail/deeplinkcompose?to=a%40example.com&subject=Hello%20there%20%26%20more&body=line%201%0Aline%202&cc=b%40example.com')
    assert.equal(emailHref(m, 'system'), m)
  })
  it('the web composers open as an external new tab, noopener', () => {
    const o = linkOpen(emailHref(to, 'gmail'), 'https://acme.example.com')
    assert.equal(o.target, '_blank')
    assert.match(o.rel, /noopener/)
  })
  it('not an email link: left as it is', () => {
    assert.equal(contactHref('https://example.com/a', { email_client: 'gmail' }), 'https://example.com/a')
    assert.equal(emailHref('mailto:', 'gmail'), null)
  })
})

describe('phone links per app', () => {
  const tel = 'tel:+358401234567'
  it('no stored choice = WhatsApp', () => {
    assert.equal(phoneHref(tel, undefined), 'https://wa.me/358401234567')
    assert.equal(contactHref(tel, { email_client: 'system' }), 'https://wa.me/358401234567')
  })
  it('each app its own link', () => {
    assert.equal(phoneHref(tel, 'tel'), 'tel:+358401234567')
    assert.equal(phoneHref(tel, 'viber'), 'viber://chat?number=%2B358401234567')
    assert.equal(phoneHref(tel, 'telegram'), 'https://t.me/+358401234567')
    assert.equal(phoneHref(tel, 'signal'), 'sgnl://signal.me/#p/+358401234567')
    assert.equal(phoneHref(tel, 'teams'), 'https://teams.microsoft.com/l/call/0/0?users=4:+358401234567')
  })
  it('a tel: written with spaces or dashes normalises to E.164', () => {
    assert.equal(phoneHref('tel:+1-555-123-4567', 'tel'), 'tel:+15551234567')
    assert.equal(phoneHref('tel:+12', 'tel'), null)
  })
  it('every app link is one the renderers open (linkOpen)', () => {
    for (const a of PHONE_APPS) assert.ok(linkOpen(phoneHref(tel, a), 'https://acme.example.com'), a)
  })
})

describe('recognising a phone number in text', () => {
  const hrefs = (s) => phoneParts(s).filter((p) => p.type === 'link').map((p) => [p.text, p.href])
  it('a +number with spaces or dashes, standing on its own', () => {
    assert.deepEqual(hrefs('call +358 40 123 4567 today'), [['+358 40 123 4567', 'tel:+358401234567']])
    assert.deepEqual(hrefs('US office: +1-555-123-4567.'), [['+1-555-123-4567', 'tel:+15551234567']])
    assert.deepEqual(hrefs('(+44 20 7946 0958)'), [['+44 20 7946 0958', 'tel:+442079460958']])
    assert.deepEqual(hrefs('+3584012345'), [['+3584012345', 'tel:+3584012345']])
  })
  it('controls stay text: a sha, a date, a time, an order number, a version, an offset', () => {
    for (const s of [
      'landed in 935ca65cf0a1b2c3',
      'on 2026-10-13 at 10:45',
      'at 2026-10-13T06:18:14+03:00',
      'order #12345678 shipped',
      'order 1234567890',
      'version v1.2.3 and 10.4.1234567',
      'tz +02:00',
      'score +12',
      'a+3584012345 glued',
      'id 3584012345+3584012345',
      '+3584012345678901234 too long',
      'x/+3584012345',
    ]) assert.deepEqual(hrefs(s), [], s)
  })
  it('in a body: plain text links; code, urls and ids do not', () => {
    const b = parseBody('ring +358 40 123 4567 or see https://example.com/+358401234567 and `+358401234567`')
    assert.deepEqual(links(b).map((p) => p.href), ['tel:+358401234567', 'https://example.com/+358401234567'])
    assert.deepEqual(links(parseBody('```\n+358401234567\n```')), [])
    assert.deepEqual(links(parseBody('- item +358 40 123 4567')).map((p) => p.href), ['tel:+358401234567'])
  })
  it('phoneBlocks leaves code blocks and existing links alone', () => {
    const blocks = [{ type: 'code', text: '+358401234567' }, { type: 'para', parts: [{ type: 'link', text: '+358401234567', href: 'https://x.example' }] }]
    assert.deepEqual(phoneBlocks(blocks), blocks)
  })
  it('in markdown: text links, a mailto: link stays one, code does not link', () => {
    const tree = markdownTree('call +358 40 123 4567, mail [me](mailto:me@example.com?subject=Hi) or `+358401234567`')
    assert.deepEqual(mdLinks(tree), ['tel:+358401234567', 'mailto:me@example.com?subject=Hi'])
  })
})
