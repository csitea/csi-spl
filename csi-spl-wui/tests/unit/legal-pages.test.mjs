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

describe('legal pages', () => {
  for (const name of ['privacy.html', 'terms.html']) {
    const html = page(name)
    it(`${name} is a complete static document`, () => {
      assert.match(html, /^<!doctype html>/i)
      assert.match(html, /<title>[^<]+ - spool-hub<\/title>/)
      assert.match(html, /<h1>[^<]+<\/h1>/)
    })
    it(`${name} runs no script and loads nothing external`, () => {
      assert.doesNotMatch(html, /<script/i)
      assert.doesNotMatch(html, /\b(src|href)="(https?:)?\/\//i)
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

  it('Hosting serves them without the .html suffix', () => {
    assert.equal(firebase.hosting.cleanUrls, true)
  })
})
