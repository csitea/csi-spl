// SPL-953: the attach control is the paperclip glyph only. The word stays
// as the hover title and the screen-reader name.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

function attachButton(src) {
  const at = src.indexOf('data-testid="attach"')
  assert.ok(at > 0, 'attach control missing')
  const open = src.lastIndexOf('<button', at)
  const close = src.indexOf('</button>', at)
  assert.ok(open >= 0 && close > at, 'attach button bounds')
  return src.slice(open, close + '</button>'.length)
}

describe('SPL-953 attach is the paperclip icon only', () => {
  it('the button has no visible word, and names itself on aria-label and title', () => {
    const btn = attachButton(read('src/components/MessageComposer.vue'))
    assert.match(btn, /:aria-label="t\('composer\.attach'\)"/)
    assert.match(btn, /:title="t\('composer\.attach'\)"/)
    assert.match(btn, /data-testid="attach"/)
    assert.match(btn, /@click="openFiles"/)
    const inner = btn.slice(btn.indexOf('>') + 1, btn.lastIndexOf('</button>'))
    assert.equal(inner, '<UiIcon name="paperclip" :size="18" />')
    assert.equal(inner.includes('{{'), false)
    assert.equal(btn.includes('📎'), false)
  })

  it('Tab from the textarea skips attach and reaches Send', () => {
    const src = read('src/components/MessageComposer.vue')
    const btn = attachButton(src)
    assert.match(btn, /tabindex="-1"/)
    const ta = src.indexOf('<textarea')
    const at = src.indexOf('data-testid="attach"')
    const sendAt = src.indexOf('data-testid="send"')
    assert.ok(ta > 0 && ta < at && at < sendAt, 'order is textarea, attach, send')
    const send = src.slice(src.lastIndexOf('<button', sendAt), src.indexOf('>', sendAt) + 1)
    assert.equal(/tabindex\s*=/.test(send), false, send)
    assert.equal(/\sdisabled\b|:disabled\b/.test(send), false, send)
  })

  it('uiIcons has the lucide paperclip stroke', () => {
    const src = read('src/utils/uiIcons.ts')
    assert.match(src, /paperclip:\s*\[/)
    assert.match(src, /m16 6-8\.414 8\.586a2 2 0 0 0 2\.829 2\.829/)
  })

  it('the catalogue word is unchanged and still the accessible name', () => {
    const en = JSON.parse(read('i18n/locales/en.json'))
    assert.equal(en.composer.attach, 'attach')
  })
})
