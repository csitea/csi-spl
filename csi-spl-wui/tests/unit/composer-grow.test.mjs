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
    assert.match(omni, /max-height:\s*40vh/)
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
