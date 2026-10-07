// Spec 103 T004 (t1 7d9e1681): the vim-nav store (stores/vim-nav.ts) and the
// vim focus ring (assets/css/vim-nav.css). The store is .ts, so the test
// transpiles it with typescript and runs it against the real pinia + vue and
// the real utils/vim-panels.mjs. Each check is a function returning the rules
// it finds broken, so the controls can prove it catches a mutated source.
//
// Run: node tests/unit/vim-store.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const PINIA = import.meta.resolve('pinia')
const VUE = import.meta.resolve('vue')

const STORE = read('src/stores/vim-nav.ts')
const CSS = read('src/assets/css/vim-nav.css')

/** The store module from TS source: bare imports pointed at real files. */
async function loadStore(src) {
  const js = ts.transpileModule(src, {
    compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 },
  }).outputText
    .replace(/from 'pinia'/, `from '${PINIA}'`)
    .replace(/from 'vue'/, `from '${VUE}'`)
    .replace(/from '~\/utils\/vim-panels\.mjs'/, `from '${pathToFileURL(join(WUI, 'src/utils/vim-panels.mjs')).href}'`)
  const mod = await import('data:text/javascript,' + encodeURIComponent(js))
  const pinia = await import(PINIA)
  pinia.setActivePinia(pinia.createPinia())
  return mod
}

/** an element answering getAttribute from a table */
const el = (attrs) => ({ getAttribute: (n) => attrs[n] ?? null })

/** The store's behaviour rules; returns the ones broken. */
async function storeBroken(src) {
  const broken = []
  const s = (await loadStore(src)).useVimNav()
  if (s.activePanel !== 0) broken.push('starts on panel 0')
  if (JSON.stringify(s.selectedKeyPerPanel) !== JSON.stringify({ 0: '', 1: '', 2: '', 3: '' })) broken.push('no keys at start')
  if (s.setPanel(4) || s.setPanel(-1) || s.activePanel !== 0) broken.push('rejects a non-panel')
  if (s.setPanel(0)) broken.push('same panel is no move')
  s.setPanel(1)
  s.setPanel(2)
  s.setPanel(3)
  if (s.activePanel !== 3 || s.history.join() !== '0,1,2') broken.push('history keeps the panels left')
  if (s.back() !== 2 || s.back() !== 1) broken.push('back retraces')
  s.setPanel(3)
  s.setPanel(2)
  if (s.back() !== 1) broken.push('back never moves right (l then h then Esc)')
  s.resetRoute()
  s.setPanel(0)
  if (s.back() !== 0) broken.push('back stops at 0')
  s.setPanel(2)
  s.resetRoute()
  if (s.back() !== 1) broken.push('back without history: one left')
  s.select(2, el({ 'data-key': 'k2', id: 'x' }))
  s.select(1, 'chan-a')
  s.select(9, 'nope')
  if (s.remembered(2) !== 'k2') broken.push('select keys an element by vimItemKey')
  if (s.remembered(1) !== 'chan-a') broken.push('select takes a key')
  if (s.remembered(9) !== '' || '9' in s.selectedKeyPerPanel) broken.push('ignores a non-panel')
  s.resetRoute()
  if (s.remembered(2) !== '' || s.history.length) broken.push('resetRoute forgets')
  for (let i = 0; i < 100; i++) s.setPanel(i % 2 ? 1 : 2)
  if (s.history.length > 32) broken.push('history is bounded')
  return broken
}

/** The ring rules (owner 2026-09-20: one colour, <= 3px); returns the ones broken. */
function cssBroken(css) {
  const broken = []
  const vars = read('src/assets/css/variables.css')
  const ring = /--vim-focus-ring:\s*([^;]+);/.exec(css)?.[1].trim() ?? ''
  if (ring !== 'var(--focus-ring-w) solid var(--focus-ring)') broken.push('ring = the one focus colour at --focus-ring-w')
  for (const m of vars.matchAll(/--focus-ring-w:\s*(\d+(?:\.\d+)?)px/g)) if (Number(m[1]) > 3) broken.push('ring <= 3px')
  const rule = /\[data-vim-selected="true"\]\s*\{([^}]*)\}/.exec(css)?.[1] ?? ''
  if (!/outline:\s*var\(--vim-focus-ring\)/.test(rule)) broken.push('vim rows wear the ring')
  if (/#[0-9a-f]{3,8}\b|rgb|hsl/i.test(css)) broken.push('no colour of its own')
  if (/\bbox-shadow\b|\bborder:/.test(rule)) broken.push('no second ring')
  const selectors = [...css.matchAll(/^([^\s/*{}][^{]*)\{/gm)].map((m) => m[1].trim())
  if (selectors.some((s) => s !== ':root' && !s.includes('[data-vim-selected="true"]'))) broken.push('vim-focused elements only')
  return broken
}

/** Files Nuxt loads eagerly must not reach the store or the sheet (160 KB initial chunk). */
function eagerBroken(files) {
  return files.filter(([, src]) => /stores\/vim-nav|vim-nav\.css/.test(src)).map(([f]) => f)
}

const EAGER = ['nuxt.config.ts', 'src/app.vue', 'src/layouts/default.vue', 'src/assets/css/main.css']

describe('103 T004: the vim-nav store', () => {
  it('panel, per-panel key and back history behave', async () => {
    assert.deepEqual(await storeBroken(STORE), [])
  })
  it('control: a back() that pops whatever came last fails', async () => {
    const mut = STORE.replace('if (from < activePanel.value) {', 'if (true) {')
    assert.notEqual(mut, STORE)
    assert.ok((await storeBroken(mut)).includes('back never moves right (l then h then Esc)'))
  })
  it('control: an unbounded history fails', async () => {
    const mut = STORE.replace('VIM_HISTORY_MAX = 32', 'VIM_HISTORY_MAX = 1e9')
    assert.notEqual(mut, STORE)
    assert.ok((await storeBroken(mut)).includes('history is bounded'))
  })
})

describe('103 T004: --vim-focus-ring', () => {
  it('one colour, 2px, on vim-selected rows only', () => {
    assert.deepEqual(cssBroken(CSS), [])
  })
  it('control: an accent colour of its own, 4px wide, fails', () => {
    const mut = CSS.replace('var(--focus-ring-w) solid var(--focus-ring)', '4px solid #3b82f6')
    assert.notEqual(mut, CSS)
    assert.deepEqual(cssBroken(mut), ['ring = the one focus colour at --focus-ring-w', 'no colour of its own'])
  })
  it('control: a rule for every focused element fails', () => {
    assert.ok(cssBroken(CSS + '\n:focus { outline: var(--vim-focus-ring); }\n').includes('vim-focused elements only'))
  })
})

describe('103 T004: nothing eager loads it (initial chunk delta 0)', () => {
  it('nuxt.config, app.vue, the default layout and main.css do not import it', () => {
    assert.deepEqual(eagerBroken(EAGER.map((f) => [f, read(f)])), [])
  })
  it('control: main.css importing the sheet fails', () => {
    assert.deepEqual(eagerBroken([['src/assets/css/main.css', "@import './vim-nav.css';\n"]]), ['src/assets/css/main.css'])
  })
})
