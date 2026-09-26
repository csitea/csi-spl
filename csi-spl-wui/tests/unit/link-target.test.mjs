import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { linkAttrs, opensNewTab } from '../../src/utils/link-target.mjs'

describe('message links stay in this tab when they are internal', () => {
  it('spool-hub.ai and a relative path stay', () => {
    for (const href of [
      'https://spool-hub.ai/channel/x',
      'https://www.spool-hub.ai/issues',
      'http://spool-hub.ai/',
      '/channel/x',
      '#here',
    ]) {
      assert.equal(opensNewTab(href), false, href)
      assert.equal(linkAttrs(href).target, undefined, href)
    }
  })
  it('dev and any other host open in another tab', () => {
    for (const href of [
      'https://dev.spool-hub.ai/channel/x',
      'https://example.com/a',
      'https://api.spool-hub.ai/v1',
      'mailto:a@example.com',
    ]) {
      assert.equal(opensNewTab(href), true, href)
      assert.equal(linkAttrs(href).target, '_blank', href)
      assert.match(linkAttrs(href).rel, /noopener/)
    }
  })
})
