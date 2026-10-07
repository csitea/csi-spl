// Owner t1 a1bce52e: a release-note URL of any env of this spool is an
// internal link (this page's /releases/<ref>, no host), and it has a preview.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'

import { localReleasePath, releaseRefOfPath, spoolBaseHost } from '../../src/utils/release-link.mjs'
import { classifyHref, linkOpen, openMessageLink, sameTabPath } from '../../src/utils/link-target.mjs'
import { appLinkLabel } from '../../src/utils/app-link-label.mjs'
import { bodyPreviewRefs, previewTarget, RELEASE_ID_PREFIX } from '../../src/utils/link-preview.mjs'
import { parseBody } from '../../src/utils/code-blocks.mjs'
import { mockReleaseNotes, releasePreviews } from '../../src/utils/release-notes-api.mjs'

const PRD = 'https://app.example'
const DEV = 'https://dev.app.example'
const T2 = 'https://acme.app.example'
const SHA = '9f175b2e1c0d4a3b8e7f6a5b4c3d2e1f0a9b8c7d'

describe('release-link: which URLs are a release note of this spool', () => {
  it('the base drops a leading env label', () => {
    assert.equal(spoolBaseHost(DEV, ''), 'app.example')
    assert.equal(spoolBaseHost(PRD, ''), 'app.example')
    assert.equal(spoolBaseHost(T2, PRD), 'app.example')
    assert.equal(spoolBaseHost('', ''), '')
  })

  it('reads a sha, a short sha, a version and a locale prefix', () => {
    assert.equal(releaseRefOfPath('/releases/' + SHA), SHA)
    assert.equal(releaseRefOfPath('/releases/9F175B2'), '9f175b2')
    assert.equal(releaseRefOfPath('/fi/releases/v1.3.5'), 'v1.3.5')
    assert.equal(releaseRefOfPath('/releases/v1.3.5-c2/'), 'v1.3.5-c2')
    assert.equal(releaseRefOfPath('/releases/abc'), '')
    assert.equal(releaseRefOfPath('/releases/' + SHA + '/x'), '')
    assert.equal(releaseRefOfPath('/x/releases/' + SHA), '')
  })

  it('dev, prd and a tenant host map to the page path; other hosts do not', () => {
    for (const host of [PRD, DEV, T2, 'https://www.app.example', 'http://dev.app.example']) {
      assert.equal(localReleasePath(new URL(host + '/releases/' + SHA), PRD, ''), '/releases/' + SHA, host)
      assert.equal(localReleasePath(new URL(host + '/releases/' + SHA), DEV, ''), '/releases/' + SHA, host)
    }
    assert.equal(localReleasePath(new URL('https://example.com/releases/' + SHA), PRD, ''), null)
    assert.equal(localReleasePath(new URL('https://evilapp.example/releases/' + SHA), PRD, ''), null)
    assert.equal(localReleasePath(new URL(DEV + '/releases/' + SHA + '?x=1'), PRD, ''), null)
    assert.equal(localReleasePath(new URL(DEV + '/channel/lobby'), PRD, ''), null)
  })
})

describe('link-target: a release note opens in this tab', () => {
  it('the dev release URL seen from prd is internal, href = the page path', () => {
    assert.deepEqual(classifyHref(DEV + '/releases/' + SHA, PRD, ''), { href: '/releases/' + SHA, internal: true })
    assert.deepEqual(linkOpen(DEV + '/releases/' + SHA, PRD, ''), { href: '/releases/' + SHA, internal: true })
    assert.equal(sameTabPath(DEV + '/releases/' + SHA, PRD + '/channel/lobby'), '/releases/' + SHA)
  })

  it('the apex release URL seen from a tenant host is this tab, not another origin', () => {
    assert.deepEqual(classifyHref(PRD + '/releases/' + SHA, T2, PRD), { href: '/releases/' + SHA, internal: true })
  })

  it('a phone tap navigates instead of opening a tab', () => {
    let path = null
    let ext = null
    const opened = openMessageLink(DEV + '/releases/' + SHA, PRD + '/channel/lobby', (p) => { path = p }, (u) => { ext = u })
    assert.equal(opened, true)
    assert.equal(path, '/releases/' + SHA)
    assert.equal(ext, null)
  })

  it('without a page origin an absolute release URL stays external', () => {
    assert.deepEqual(classifyHref(DEV + '/releases/' + SHA), { href: DEV + '/releases/' + SHA, internal: false })
  })

  it('another env issue link stays external', () => {
    assert.equal(classifyHref(DEV + '/issues?issue=SPL-1', PRD, '').internal, false)
  })
})

describe('app-link-label: a release URL reads release: <8 hex>, no host', () => {
  it('the dev URL on the prd page', () => {
    const l = appLinkLabel(DEV + '/releases/' + SHA, { pageHref: PRD + '/channel/lobby' })
    assert.equal(l && l.text, 'release: ' + SHA.slice(0, 8))
    assert.ok(!l.text.includes('app.example'))
  })

  it('a version stays whole', () => {
    assert.equal(appLinkLabel(PRD + '/releases/v1.3.5', { pageHref: PRD + '/' })?.text, 'release: v1.3.5')
  })
})

describe('link-preview: a release URL is a preview ref', () => {
  it('previewTarget names release:<ref>', () => {
    assert.equal(previewTarget(DEV + '/releases/' + SHA, PRD), RELEASE_ID_PREFIX + SHA)
    assert.equal(previewTarget('/releases/v1.3.5', PRD), RELEASE_ID_PREFIX + 'v1.3.5')
  })

  it('a body of dev and prd links to the same sha is one card', () => {
    const body = `released\n- dev ${DEV}/releases/${SHA}\n- prd ${PRD}/releases/${SHA}\n`
    assert.deepEqual(bodyPreviewRefs(parseBody(body), body, PRD).map((r) => r.id), [RELEASE_ID_PREFIX + SHA])
  })

  it('releasePreviews builds a card from the note and skips an unknown ref', async () => {
    const sha = '00000001'.repeat(5)
    const get = async (path) => mockReleaseNotes(path, 'v1.0.0')
    const res = await releasePreviews([RELEASE_ID_PREFIX + sha, RELEASE_ID_PREFIX + 'fffffff'], get)
    assert.equal(res.previews.length, 1)
    const c = res.previews[0]
    assert.equal(c.id, RELEASE_ID_PREFIX + sha)
    assert.equal(c.kind, 'release')
    assert.match(c.title, /^mock change 1:/)
    assert.ok(c.excerpt)
    assert.equal(c.meta, 'v1.0.0 · 00000001')
  })
})
