// CLE-3437 — the box a ``` block is typed into grows with the block.
//
// The owner asked for code formatting on ``` a second time. It was not the
// parser and it was not the renderer: both worked on every surface (measured
// live on dev a212596). It was the COMPOSER in the topic pane, which still
// sized itself from rows="2" while the top-bar Omnibox had been given
// `field-sizing: content` back in 022. A four-line block there measured
// clientHeight 44 against scrollHeight 64 — a two-line peephole with its own
// scrollbar, the first line already out of view.
//
// So the contract is: EVERY composer sizes to its content, and every one of
// them is bounded, because an unbounded textarea pushes Send off the screen.
//
// Run: node tests/unit/composer-grow.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const SRC = join(WUI, 'src')
const read = (rel) => readFileSync(join(WUI, rel), 'utf8')

/** the body of the first rule whose selector list matches `sel` exactly */
function ruleBody(css, sel) {
  const at = css.indexOf(sel + ' {')
  assert.notEqual(at, -1, `no rule for "${sel}"`)
  const open = css.indexOf('{', at)
  return css.slice(open + 1, css.indexOf('}', open))
}

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, acc)
    else if (/\.vue$/.test(name)) acc.push(p)
  }
  return acc
}

describe('composer growth (CLE-3437)', () => {
  const css = read('src/assets/css/main.css')

  it('the base composer sizes to its content, bounded', () => {
    const base = ruleBody(css, '.composer textarea')
    assert.match(base, /field-sizing:\s*content/, 'a rows="2" box cannot hold a code block')
    assert.match(base, /max-height:\s*40vh/, 'unbounded, a long block pushes Send off screen')
    assert.match(base, /overflow-y:\s*auto/, 'past the bound the block scrolls inside the box')
  })

  it('the top-bar Omnibox keeps its own bound too', () => {
    const omni = ruleBody(css, '.composer.omnibox--global textarea')
    assert.match(omni, /field-sizing:\s*content/)
    assert.match(omni, /min-height:\s*36px/)
    assert.match(omni, /max-height:\s*calc\(100vh - var\(--top-bar-h\) - 8px\)/)
    assert.match(omni, /overflow-y:\s*auto/, 'past the bound the block scrolls inside the box')
    assert.match(css, /\.composer\.omnibox--global \.composer-row\s*\{[^}]*align-self:\s*flex-start/)
    assert.match(css, /\.composer\.omnibox--global \.composer-row\s*\{[^}]*flex:\s*0 0 auto/)
    const box = read('src/components/MessageComposer.vue')
    assert.match(box, /data-test="omnibox-resize"/)
    assert.match(box, /function startResize/)
    assert.match(box, /userHeight\.value != null/)
    assert.match(box, /function collapseGlobalBox/)
    assert.match(box, /@blur="onOmniboxBlur"/)
    assert.match(box, /collapseGlobalBox\(false\)/)
    assert.match(box, /omniboxFocusHeight\(/)
    assert.doesNotMatch(box, /userHeight\.value = null/)
  })

  // The bar is a column flex item. height alone loses to min-height:auto
  // (the content size), which also beats max-height. The omnibox is a
  // one-line slot (min-height:0, max-height:100%) so a ``` block or file
  // chips overflow it downward and the shell does not move.
  // The resting field, drag handle included, is the bar minus 2px at the
  // top and 2px at the bottom. The bar's border is that bottom 1px, so the
  // padding under the field is 1px. The handle lives in the field's bottom
  // padding, and the buttons match the field instead of growing with it.
  it('the resting omnibox fills the bar with 2px above and 2px below', () => {
    assert.match(css, /--top-bar-inset-top:\s*2px/)
    assert.match(css, /--top-bar-inset-bottom:\s*1px/)
    assert.match(css, /--top-bar-border:\s*1px/)
    assert.match(css, /--omnibox-rest:\s*calc\(var\(--top-bar-h\) - var\(--top-bar-inset-top\) - var\(--top-bar-inset-bottom\) - var\(--top-bar-border\)\)/)
    const field = ruleBody(css, '.composer.omnibox--global .omnibox-field')
    assert.match(field, /min-height:\s*var\(--omnibox-rest\)/)
    assert.match(field, /padding:\s*0 8px 10px/)
    const grip = ruleBody(css, '.composer.omnibox--global .omnibox-resize')
    assert.match(grip, /position:\s*absolute/)
    assert.match(grip, /height:\s*8px/)
    const buttons = ruleBody(css, '.composer.omnibox--global .composer-row button')
    assert.match(buttons, /height:\s*var\(--omnibox-rest\)/)
    const vue = read('src/components/TopBar.vue')
    const bar = ruleBody(vue, '.top-bar')
    assert.match(bar, /padding:\s*var\(--top-bar-inset-top\) 12px var\(--top-bar-inset-bottom\)/)
    assert.match(bar, /border-bottom:\s*var\(--top-bar-border\) solid/)
  })

  it('the top bar stays --top-bar-h while the omnibox may overflow it', () => {
    const vue = read('src/components/TopBar.vue')
    const bar = ruleBody(vue, '.top-bar')
    assert.match(bar, /height:\s*var\(--top-bar-h\)/)
    assert.match(bar, /min-height:\s*var\(--top-bar-h\)/)
    assert.match(bar, /max-height:\s*var\(--top-bar-h\)/)
    assert.match(bar, /overflow:\s*visible/)
    const slot = ruleBody(vue, '.top-bar__omnibox')
    assert.match(slot, /max-height:\s*100%/)
    assert.match(slot, /min-height:\s*0/)
    assert.match(slot, /overflow:\s*visible/)
    const child = ruleBody(vue, '.top-bar__omnibox > .composer')
    assert.match(child, /flex:\s*1 1 auto/)
    assert.match(child, /flex-shrink:\s*0/)
    assert.match(child, /min-height:\s*0/)
    const phone = vue.slice(vue.indexOf('.top-bar--open .top-bar__omnibox {'))
    const phoneBody = phone.slice(0, phone.indexOf('}'))
    assert.match(phoneBody, /position:\s*absolute/)
    assert.match(phoneBody, /max-height:\s*none/)
    assert.match(phoneBody, /flex-direction:\s*row/)
    const box = read('src/components/MessageComposer.vue')
    assert.match(box, /function fitGlobalBox\(\)/)
    assert.match(box, /if \(!el \|\| !props\.global\) return/)
    assert.match(box, /el\.style\.height = 'auto'/)
  })

  // The rule above is keyed on `.composer textarea`, so it reaches a message
  // box only through MessageComposer.vue. A second, hand-rolled composer would
  // silently miss it — which is exactly how the topic pane got left behind.
  // (A textarea outside a `.composer`, like the key-paste box in
  // KeysSetting.vue, is not a message box and is none of this rule's business.)
  it('MessageComposer.vue owns the only composer textarea', () => {
    const offenders = walk(SRC)
      .filter((p) => {
        const src = readFileSync(p, 'utf8')
        return /<textarea/.test(src) && /class="[^"]*\bcomposer\b/.test(src)
      })
      .map((p) => relative(WUI, p))
      .filter((p) => !/components\/MessageComposer\.vue$/.test(p))
    assert.deepEqual(offenders, [], 'these render their own composer textarea instead of MessageComposer')
  })

  it('the top bar is the only message box; a topic has no reply field of its own', () => {
    assert.match(read('src/components/TopBar.vue'), /<MessageComposer/)
    for (const rel of [
      'src/components/TopicPane.vue',
      'src/components/LiveTopicPane.vue',
      'src/pages/t/[task_id].vue',
    ]) assert.doesNotMatch(read(rel), /<MessageComposer|<textarea/, `${rel} still has a reply box`)
  })
})
