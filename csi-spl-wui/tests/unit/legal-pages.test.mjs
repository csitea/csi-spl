// spec 049 FR-F7: the privacy policy and terms Meta requires before a Facebook
// Login app goes Live. Static HTML (Hosting cleanUrls serves /privacy and
// /terms), no script, so Meta's crawler reads the text without running JS.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const page = (name) => readFileSync(join(WUI, 'src/public', name), 'utf8')
const firebase = JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8'))
// the one outside page the pages may link (a plain link, nothing loaded):
// Google's policy the Limited Use statement names (spec 149 section 12)
const GOOGLE_POLICY = 'https://developers.google.com/terms/api-services-user-data-policy'
const LIMITED_USE = /use and transfer to any other app of information received from\s+Google APIs\s+adheres to the\s+<a href="https:\/\/developers\.google\.com\/terms\/api-services-user-data-policy">Google\s+API\s+Services User Data Policy<\/a>, including the Limited Use requirements\./

describe('legal pages', () => {
  for (const name of ['about.html', 'privacy.html', 'terms.html']) {
    const html = page(name)
    it(`${name} is a complete static document`, () => {
      assert.match(html, /^<!doctype html>/i)
      assert.match(html, /<title>[^<]+ - spool-hub<\/title>/)
      assert.match(html, /<h1>[^<]+<\/h1>/)
    })
    it(`${name} runs no script and loads nothing external`, () => {
      assert.doesNotMatch(html, /<script/i)
      assert.doesNotMatch(html, /\bsrc="(https?:)?\/\//i)
      assert.doesNotMatch(html, /<link\b[^>]*\bhref="(https?:)?\/\//i)
      const outside = [...html.matchAll(/\bhref="((?:https?:)?\/\/[^"]*)"/gi)].map((m) => m[1])
      assert.deepEqual(outside.filter((u) => u !== GOOGLE_POLICY), [], `${name} links outside`)
    })
    it(`${name} links both pages`, () => {
      assert.match(html, /href="\/privacy"/)
      assert.match(html, /href="\/terms"/)
    })
  }

  it('the privacy policy names the Facebook data and how to remove it', () => {
    const html = page('privacy.html')
    for (const s of ['public_profile', 'email', 'Apps and websites', 'remove spool-hub']) {
      assert.ok(html.includes(s), `privacy.html lacks "${s}"`)
    }
  })

  // spec 149 (SPL-3388): Google's review of the calendar scope reads this page.
  it('the privacy policy names the Google Calendar data and its removal', () => {
    const html = page('privacy.html')
    for (const s of ['Google Calendar', 'Spool Hub (', 'any other calendar', 'reads the events of that one calendar', 'which only you see', 'moves them to your\ntrash', 'Cloud KMS', 'revoke the access', 'not sold']) {
      assert.ok(html.includes(s), `privacy.html lacks "${s}"`)
    }
  })

  // spec 149 section 12 (SPL-6204): Google's app verification reads the home
  // page and the policy; both state the Limited Use line in Google's words
  it('the privacy policy and the About page carry the Limited Use statement', () => {
    for (const name of ['privacy.html', 'about.html']) assert.match(page(name), LIMITED_USE, name)
    assert.match(page('privacy.html'), /<h2>3\. Data from Google Calendar<\/h2>[^]*?Limited Use requirements[^]*?<h2>4\. /)
    // CONTROL: the policy without the line fails the match
    assert.doesNotMatch(page('privacy.html').replace(/Limited Use/g, 'limited use'), LIMITED_USE)
  })

  it('the About page names the app, its maker, what it does and why it asks for Google Calendar', () => {
    const html = page('about.html')
    for (const s of ['<h1>spool-hub</h1>', 'Csitea', 'people and software agents work together in\nworkspaces', 'Why spool-hub asks for Google Calendar', 'Spool Hub (your\nworkspace', 'never writes to, changes or deletes anything in a calendar other than the\none it created', 'not sold', 'href="/login"', '<meta name="description"']) {
      assert.ok(html.includes(s), `about.html lacks "${s}"`)
    }
    assert.doesNotMatch(html, /name="robots"/)
  })

  // the home URL leads to them: the prerendered product shell at / (what a
  // crawler reads without JavaScript) and the sign-in page's links row
  it('the shell at / and the sign-in links row link /about and /privacy', () => {
    const src = (p) => readFileSync(join(WUI, p), 'utf8')
    const shell = src('src/layouts/default.vue').match(/<template #fallback>[^]*?<\/template>/)?.[0] || ''
    for (const html of [shell, src('src/components/LoginLinks.vue')]) {
      assert.match(html, /<a [^>]*href="\/about"[^>]*>\{\{ \$?t\('auth\.login\.links\.about'\) \}\}<\/a>/)
      assert.match(html, /<a [^>]*href="\/privacy"[^>]*>\{\{ \$?t\('auth\.login\.links\.privacy'\) \}\}<\/a>/)
    }
  })

  it('Hosting serves them without the .html suffix', () => {
    assert.equal(firebase.hosting.cleanUrls, true)
  })
})
