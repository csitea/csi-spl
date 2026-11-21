// SPL-6218 (epic SPL-2403): the issue-epic panel's dots keep their own
// identity colours (CLE-77915), apart from spec 033 K.2's message-kind tokens.
//
// variables.css once defined --color-kind-feature twice: #14b8a6 for the epic
// panel's feature dot, then spec 033's message-kind colour in later :root
// blocks. The later blocks win, so the dot lost its teal. The panel now reads
// its own token, which no later block overrides.
//
// 1. Each dot of IssueEpicsPanel.vue resolves, in all 8 themes, to its
//    identity colour: epic #8b5cf6, feature #14b8a6.
// 2. The panel reads no spec 033 message-kind token (--color-kind-<kind>).
//
// Each block carries a control: the nearest input that must fail.
// Run: node tests/unit/epic-feature-token.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const VARS = readFileSync(join(WUI, 'src/assets/css/variables.css'), 'utf8')
const PANEL = readFileSync(join(WUI, 'src/components/IssueEpicsPanel.vue'), 'utf8')

const THEMES = ['', 'dark', 'light', 'light-violet', 'light-green', 'light-yellow', 'light-orange', 'light-red']
const FEATURE_DOT = '.epic-row__kind[data-kind="feature"]'
const WANT = { '.epic-row__kind': '#8b5cf6', [FEATURE_DOT]: '#14b8a6' }
const MESSAGE_KINDS = ['feature', 'bug', 'alert', 'question', 'idea', 'decision', 'docs']

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

/** the token's value in `theme`: the last block that applies wins */
function token(blocks, theme, name) {
  let v
  for (const b of blocks) if (b.sels.some((s) => applies(s, theme)) && name in b.decls) v = b.decls[name]
  assert.ok(v !== undefined, `${theme || 'default'}: ${name} is not defined`)
  return v.toLowerCase()
}

/** the var() each panel dot rule paints its background with */
function dotVars(vue) {
  const out = {}
  for (const m of vue.matchAll(/^(\.epic-row__kind[^{]*)\{[^}]*background:\s*var\((--[a-z0-9-]+)\)/gm)) out[m[1].trim()] = m[2]
  return out
}

/** every dot whose colour in some theme is not its identity colour */
function wrongDots(css, vue) {
  const blocks = blocksOf(css)
  const vars = dotVars(vue)
  const out = []
  for (const [sel, want] of Object.entries(WANT)) {
    assert.ok(vars[sel], `IssueEpicsPanel.vue: no background var() for ${sel}`)
    for (const t of THEMES) {
      const got = token(blocks, t, vars[sel])
      if (got !== want) out.push({ theme: t || 'default', sel, token: vars[sel], got, want })
    }
  }
  return out
}

describe('epic panel dots keep their identity colours (SPL-6218)', () => {
  it('each dot resolves to its colour in all 8 themes', () => {
    assert.deepEqual(wrongDots(VARS, PANEL), [])
  })
  it('control: a later :root block overriding the feature dot token fails in every theme', () => {
    const name = dotVars(PANEL)[FEATURE_DOT]
    const bad = wrongDots(`${VARS}\n:root { ${name}: #8c9eff; }`, PANEL)
    assert.equal(bad.length, THEMES.length)
  })
  it('control: a light-only override fails in the light themes alone', () => {
    const name = dotVars(PANEL)[FEATURE_DOT]
    const bad = wrongDots(`${VARS}\n:root[data-theme^="light"] { ${name}: #3f51b5; }`, PANEL)
    assert.deepEqual(bad.map((b) => b.theme), THEMES.filter((t) => t.startsWith('light')))
  })
})

describe('the epic panel reads no message-kind token (spec 033 K.2)', () => {
  const kindTokens = (vue) => Object.values(dotVars(vue)).filter((v) => MESSAGE_KINDS.some((k) => v === `--color-kind-${k}`))
  it('no dot paints with a --color-kind-<message kind> token', () => {
    assert.deepEqual(kindTokens(PANEL), [])
  })
  it('control: a feature dot reading --color-kind-feature is caught', () => {
    const bad = PANEL.replace(/(\.epic-row__kind\[data-kind="feature"\][^{]*\{[^}]*background:\s*var\()--[a-z0-9-]+/, '$1--color-kind-feature')
    assert.deepEqual(kindTokens(bad), ['--color-kind-feature'])
  })
})
