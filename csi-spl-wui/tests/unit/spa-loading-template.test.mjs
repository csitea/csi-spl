// the 200.html loading shell's style block must be the block the
// Hosting render hashes. The render (csi-spl-orc/.../render-wui-firebase-json.sh)
// finds inline blocks with a regex, so a tag name written in a comment made it
// hash comment text, and every deployed page refused the real block
// (style-src-elem, measured on dev 1.4.2 by CLE-35067, 3 of 3 pages).
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const tpl = readFileSync(new URL('../../src/spa-loading-template.html', import.meta.url), 'utf8')
const render = readFileSync(new URL('../../../csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh', import.meta.url), 'utf8')

describe('spa loading template vs the CSP hasher', () => {
  it('the render still finds style blocks with the regex this test mirrors', () => {
    assert.match(render, /STYLE_RE = re\.compile\(r"<style\\b\[\^>\]\*>\(\.\*\?\)<\/style>", re\.S \| re\.I\)/)
  })

  it('the hasher regex yields exactly the real block, not comment text', () => {
    const blocks = [...tpl.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map((m) => m[1])
    assert.equal(blocks.length, 1)
    assert.match(blocks[0], /^\s*\.spl-boot\{/)
  })

  it('no tag name the hasher looks for appears outside its element, and no style attribute', () => {
    const outside = tpl.replace(/<style>[\s\S]*?<\/style>/, '')
    assert.doesNotMatch(outside, /<\/?(style|script)\b/i)
    assert.doesNotMatch(tpl, /\sstyle\s*=/i)
  })

  // SPL-1749 (ui panel item 3): the skeleton's sidebar is the shell's, so
  // nothing moves sideways when the shell replaces it, and the bar carries
  // no brand text the shell's top bar does not show in that place
  it('the sidebar box is --sidebar-w wide and the bar holds no brand text', () => {
    const vars = readFileSync(new URL('../../src/assets/css/variables.css', import.meta.url), 'utf8')
    const shell = vars.match(/--sidebar-w:\s*(\d+)px/)?.[1]
    const boot = tpl.match(/\.spl-boot__side\{[^}]*width:(\d+)px/)?.[1]
    assert.ok(shell, 'variables.css declares --sidebar-w')
    assert.equal(boot, shell)
    assert.doesNotMatch(tpl, /spl-boot__brand|spool-hub<\//)
  })
})
