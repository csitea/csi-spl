// SPL-6139 (owner HUM-10, t1 60bf4e56, msg 2dda6b09): the Qto doc view's page
// background. -doc-background.ts reads and writes the viewer's choice
// (localStorage, try/catch), the page's Document actions menu opens the
// dialog, every theme in DOC_BGS has its page class and its swatch, and the
// default is a white page under a light app theme.
//
// Run: node tests/unit/doc-background.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import ts from 'typescript'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const DIR = join(WUI, 'src/components/workspace-docs')
const read = (name) => readFileSync(join(DIR, name), 'utf8')

async function load() {
  const tmp = mkdtempSync(join(tmpdir(), 'doc-bg-'))
  try {
    const js = ts.transpileModule(read('-doc-background.ts'), { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022 } }).outputText
    writeFileSync(join(tmp, 'doc-background.mjs'), js)
    return await import(pathToFileURL(join(tmp, 'doc-background.mjs')).href)
  } finally {
    rmSync(tmp, { recursive: true, force: true })
  }
}

const bg = await load()

function memStore() {
  const m = new Map()
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), m }
}
const throwing = { getItem() { throw new Error('denied') }, setItem() { throw new Error('denied') } }

describe('doc background: the stored choice', () => {
  it('defaults to auto, with nothing stored or a value it does not know', () => {
    const s = memStore()
    assert.equal(bg.readDocBg(s), 'auto')
    s.setItem(bg.DOC_BG_KEY, 'neon')
    assert.equal(bg.readDocBg(s), 'auto')
  })
  it('round-trips every theme', () => {
    const s = memStore()
    for (const { id } of bg.DOC_BGS) {
      assert.equal(bg.writeDocBg(id, s), true)
      assert.equal(bg.readDocBg(s), id)
    }
  })
  it('a storage that throws (private window) reads the default and reports the write lost', () => {
    assert.equal(bg.readDocBg(throwing), 'auto')
    assert.equal(bg.writeDocBg('paper', throwing), false)
  })
})

describe('doc background: wiring', () => {
  const view = read('WorkspaceDocView.vue')
  const sheet = read('-doc-background.css')
  const page = read('WorkspaceDocsPage.vue')
  const dlg = read('WorkspaceDocBackgroundDialog.vue')
  it('every theme has its page class and its swatch class', () => {
    for (const { id } of bg.DOC_BGS) {
      if (id !== 'auto') assert.match(sheet, new RegExp(`\\.wsdoc--bg-${id}\\b`), `page class ${id}`)
      assert.match(dlg, new RegExp(`\\.wsdoc-bg-dlg__swatch--${id} \\{`), `swatch ${id}`)
    }
  })
  it('the default is a white page under a light app theme only', () => {
    assert.match(sheet, /:root\[data-theme\^='light'\] \.wsdoc--bg-auto \{ --color-bg: #ffffff;/)
  })
  it('the doc view root carries the class, the page menu opens the dialog', () => {
    assert.match(view, /<style src="\.\/-doc-background\.css"><\/style>/)
    assert.match(view, /'wsdoc--bg-' \+ \(background \|\| 'auto'\)/)
    assert.match(page, /id: 'background', icon: 'palette', labelKey: 'ws_doctree\.doc_bg\.menu'/)
    assert.match(page, /else if \(id === 'background'\) bgOpen\.value = true/)
    assert.match(page, /:background="docBg"/)
    assert.match(page, /docBg\.value = readDocBg\(\)/)
  })
  it('every label key is in en.json', () => {
    const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8')).ws_doctree.doc_bg
    for (const { labelKey } of bg.DOC_BGS) assert.ok(en[labelKey.split('.').pop()], labelKey)
    for (const k of ['menu', 'title', 'note', 'done']) assert.ok(en[k], k)
  })
})
