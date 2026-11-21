// Spec 033 T025 (K.2, SPL-5884): the seven new message kind colours.
//
// 1. Each of the seven bare glyphs (feature, bug, question, idea, decision,
//    docs) and the alert's fill have a --color-kind-* token in one :root and
//    one :root[data-theme^="light"] block of variables.css.
// 2. Contrast in all 8 themes (WCAG 1.4.11, 3:1 non-text): a bare glyph
//    against --color-bg-2; the alert, a filled badge, by its glyph
//    (--color-kind-alert-fg) against its fill (--color-kind-alert). The
//    light alert fill is yellow (owner Q1 A: "a yellow badge") and cannot
//    clear 3:1 on the pale light surfaces, so its glyph carries the meaning.
// 3. main.css draws each kind with its token; alert is filled.
//
// Each block carries a control: the nearest input that must fail.
// Run: node tests/unit/kind-tokens.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const VARS = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
const MAIN = readFileSync(join(WUI, 'src/assets/css/main.css'), 'utf8')

const GLYPHS = ['feature', 'bug', 'question', 'idea', 'decision', 'docs']
const THEMES = ['', 'dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']

function blocksOf(css) {
  return [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^}]*)\}/g)].map((m) => ({
    sels: m[1].split(',').map((s) => s.trim()),
    decls: Object.fromEntries([...m[2].matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)].map((d) => [d[1], d[2].trim()])),
  }))
}

function applies(sel, theme) {
  if (sel === ':root') return true
  const eq = sel.match(/^:root\[data-theme="([^"]+)"\]$/)
  if (eq) return eq[1] === theme
  const pre = sel.match(/^:root\[data-theme\^="([^"]+)"\]$/)
  return Boolean(pre && theme.startsWith(pre[1]))
}

/** the token's value in `theme`: the last block that applies wins, var() resolved */
function token(blocks, theme, name, depth = 0) {
  let v
  for (const b of blocks) if (b.sels.some((s) => applies(s, theme)) && name in b.decls) v = b.decls[name]
  assert.ok(v !== undefined, `${theme || 'default'}: ${name} is not defined`)
  assert.ok(depth < 8, `${name}: var() loop`)
  return v.replace(/var\((--[a-z0-9-]+)\)/g, (_, n) => token(blocks, theme, n, depth + 1))
}

function luminance(hex) {
  const m = String(hex).match(/^#([0-9a-f]{6})$/i)
  assert.ok(m, `not an opaque hex colour: ${hex}`)
  const [r, g, b] = [0, 2, 4]
    .map((i) => parseInt(m[1].slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return (hi + 0.05) / (lo + 0.05)
}

/** every pair under 3:1 in `theme` */
function lowPairs(blocks, theme) {
  const out = []
  const bg = token(blocks, theme, '--color-bg-2')
  for (const k of GLYPHS) {
    const c = contrast(token(blocks, theme, `--color-kind-${k}`), bg)
    if (c < 3) out.push({ theme: theme || 'default', kind: k, ratio: +c.toFixed(2) })
  }
  const a = contrast(token(blocks, theme, '--color-kind-alert-fg'), token(blocks, theme, '--color-kind-alert'))
  if (a < 3) out.push({ theme: theme || 'default', kind: 'alert', ratio: +a.toFixed(2) })
  return out
}

const BLOCKS = blocksOf(VARS)

describe('kind tokens: one set per theme family (spec 033 K.2)', () => {
  it('each token is set in :root and in :root[data-theme^="light"], and the two differ', () => {
    const root = BLOCKS.filter((b) => b.sels.includes(':root'))
    const light = BLOCKS.filter((b) => b.sels.includes(':root[data-theme^="light"]'))
    for (const k of [...GLYPHS, 'alert', 'alert-fg']) {
      const name = `--color-kind-${k}`
      const d = root.find((b) => name in b.decls)?.decls[name]
      const l = light.find((b) => name in b.decls)?.decls[name]
      assert.ok(d, `${name} in :root`)
      assert.ok(l, `${name} in :root[data-theme^="light"]`)
      if (k !== 'alert-fg') assert.notEqual(d, l, `${name}: the light family needs its own`)
    }
  })
})

describe('kind contrast >= 3:1 in all 8 themes (WCAG 1.4.11)', () => {
  for (const th of THEMES) {
    it(`${th || 'default'}: each glyph on --color-bg-2, the alert glyph on its fill`, () => {
      assert.deepEqual(lowPairs(BLOCKS, th), [])
    })
  }
  it('control: a white alert glyph on the light yellow fill fails', () => {
    const bad = blocksOf(`${VARS}\n:root[data-theme^="light"] { --color-kind-alert-fg: #ffffff; }`)
    assert.ok(lowPairs(bad, 'light').some((r) => r.kind === 'alert'), JSON.stringify(lowPairs(bad, 'light')))
  })
  it('control: the dark docs grey on a light page fails', () => {
    const bad = blocksOf(`${VARS}\n:root[data-theme^="light"] { --color-kind-docs: #a0a0a0; }`)
    assert.ok(lowPairs(bad, 'light-yellow').some((r) => r.kind === 'docs'))
  })
})

describe('main.css draws each kind with its token', () => {
  const rule = (k) => MAIN.match(new RegExp(`\\.kind-${k}\\s*\\{([^}]*)\\}`))?.[1] || ''
  for (const k of GLYPHS) {
    it(`.kind-${k} is a bare glyph in var(--color-kind-${k})`, () => {
      assert.match(rule(k), new RegExp(`(^|;)\\s*color:\\s*var\\(--color-kind-${k}\\)`))
      assert.doesNotMatch(rule(k), /background/)
    })
  }
  it('.kind-alert is filled: its glyph in --color-kind-alert-fg on --color-kind-alert, and keeps its frame', () => {
    assert.match(rule('alert'), /(^|;)\s*color:\s*var\(--color-kind-alert-fg\)/)
    assert.match(rule('alert'), /background:\s*var\(--color-kind-alert\)/)
    assert.match(MAIN, /\.kind--icon:not\(\.kind-blocker\):not\(\.kind-alert\)\s*\{\s*border-color:\s*transparent/)
  })
})
