// SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020): Export
// to PDF of one message card (its right-click menu) and of a whole topic (the
// topic header's button). The pure parts (file name, which cards print, in
// which order) and the wiring of both entries; the browser half is
// tests/e2e/msg-export-pdf.test.mjs.
//
// Red controls (each seen RED, then reverted):
//   - msgMenuItems without the `pdf` push: "the desktop menu offers Export to PDF" fails
//   - rowsInShownOrder returning every row: "only the cards shown" fails
//   - a static `import ... from '~/utils/msg-print-run'` in MessageCard.vue:
//     "the print code loads on the click only" fails
//   - printImageSrcs awaiting `load(f)` with no timer (R7 W3): "a download
//     that never settles prints the picture's name" stays pending: not ok, exit 1
// Run: node --test tests/unit/msg-print.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import { importTs } from './lib/load-ts.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const { PRINT_SLUG_MAX, printFileKey, printFileName, printImageSrcs, printSlug, rowsInShownOrder } = await importTs('src/utils/msg-print.ts')

describe('Export to PDF: the file name', () => {
  it('slugs the topic title: lower case, one dash per gap, no dash at the ends', () => {
    assert.equal(printSlug('  Deploy: WUI v1.2 -- failed!  '), 'deploy-wui-v1-2-failed')
    assert.equal(printSlug('Тема за износ'), 'тема-за-износ', 'any script keeps its letters')
    assert.equal(printSlug(''), 'topic')
    assert.equal(printSlug('!!!'), 'topic')
    assert.equal(printSlug(null), 'topic')
  })

  it('cuts a long title to PRINT_SLUG_MAX characters, never ending on a dash', () => {
    const slug = printSlug('word '.repeat(40))
    assert.ok(Array.from(slug).length <= PRINT_SLUG_MAX, slug)
    assert.ok(!slug.endsWith('-'), slug)
  })

  it('one card is <topic-title>-<msg8>, a topic <topic-title> (the browser adds .pdf)', () => {
    assert.equal(printFileName('Release notes', '5d1f2a9c-0b1e-4c4a-9d7e-2f0a1b2c3d4e'), 'release-notes-5d1f2a9c')
    assert.equal(printFileName('Release notes'), 'release-notes')
    assert.equal(printFileName('Release notes', ''), 'release-notes')
  })
})

describe('Export to PDF: which cards a topic prints', () => {
  const rows = [
    { msg_id: 'a', body: 'root' },
    { msg_id: 'b', body: 'one' },
    { msg_id: 'c', body: 'two' },
    { msg_id: 'd', body: 'not shown (a search hides it)' },
  ]
  it('only the cards shown, in the order shown', () => {
    assert.deepEqual(rowsInShownOrder(['c', 'a', 'b'], rows).map((m) => m.msg_id), ['c', 'a', 'b'])
  })
  it('an id twice prints once; an id with no message, or an empty one, prints nothing', () => {
    assert.deepEqual(rowsInShownOrder(['a', 'a', 'zz', '', 'b'], [...rows, null, { body: 'no id' }]).map((m) => m.msg_id), ['a', 'b'])
    assert.deepEqual(rowsInShownOrder(null, rows), [])
    assert.deepEqual(rowsInShownOrder(['a'], null), [])
  })
  it('a picture is keyed by its file id, else sha256, path, name', () => {
    assert.equal(printFileKey({ file_id: 'f1', sha256: 's', name: 'n.png' }), 'f1')
    assert.equal(printFileKey({ sha256: 's', name: 'n.png' }), 's')
    assert.equal(printFileKey({ name: 'n.png' }), 'n.png')
    assert.equal(printFileKey(null), '')
  })
})

describe('Export to PDF: the card menu entry', () => {
  it('the desktop menu offers Export to PDF after Copy link and Add to note, before Edit', () => {
    const ids = msgMenuItems({ pdf: true, note: true, editable: true }).map((i) => i.id)
    assert.deepEqual(ids, ['open', 'copy', 'add-to-note', 'export-pdf', 'edit', 'delete'])
    assert.deepEqual(msgMenuItems({ pdf: true }).find((i) => i.id === 'export-pdf'), { id: 'export-pdf', icon: 'file-text', labelKey: 'feed.msg_menu.export_pdf' })
  })
  it('a topic card offers it too, without changing where Archive and Delete sit', () => {
    const ids = msgMenuItems({ pdf: true, topic: true }).map((i) => i.id)
    assert.ok(ids.includes('export-pdf'), ids.join())
    assert.deepEqual(ids.slice(-2), ['archive', 'delete-topic'])
  })
  it('not without `pdf`, and not on the phone sheet (its rows are measured to fit)', () => {
    assert.ok(!msgMenuItems({}).some((i) => i.id === 'export-pdf'))
    assert.ok(!msgMenuItems({ pdf: true, touch: true }).some((i) => i.id === 'export-pdf'))
  })
  it('MessageMenu passes `pdf` through and emits export-pdf; the card asks for it and handles it', () => {
    const menu = src('src/components/MessageMenu.vue')
    assert.match(menu, /pdf: props\.pdf,/)
    assert.match(menu, /else if \(id === 'export-pdf'\) emit\('export-pdf'\)/)
    const card = src('src/components/MessageCard.vue')
    assert.match(card, /<LazyMessageMenu[\s\S]*?\n\s+pdf\n[\s\S]*?@export-pdf="onExportPdf"/)
    assert.match(src('src/composables/useCardMenuActions.ts'), /rows: \[props\.msg\]/, 'the card prints itself alone')
  })
})

describe('Export to PDF: the topic entry', () => {
  it('both topic panes mount the lazy header button with the pane title and rows', () => {
    for (const f of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
      assert.match(src(f), /<span class="pdf-slot"><LazyTopicExportPdf :title="titleText \|\| t\('topic\.title'\)" :rows="exportRows" \/><\/span>/, f)
    }
  })
  it('the button is a labelled <button>, so Tab reaches it and Enter or Space runs it', () => {
    const btn = src('src/components/TopicExportPdf.vue')
    assert.match(btn, /<button[\s\S]*?type="button"[\s\S]*?:aria-label="t\('topic\.export_pdf'\)"/)
    assert.match(btn, /rowsInShownOrder<SpoolMessage>\(shownIds\(\)/)
  })
})

describe('Export to PDF: the pictures, each download bounded (FR-020 item 5)', () => {
  const files = [{ file_id: 'ok', name: 'a.png' }, { file_id: 'hung', name: 'b.png' }, { file_id: 'bad', name: 'c.png' }, { file_id: 'none', name: 'd.png' }]
  const load = (f) => (f.file_id === 'ok' ? Promise.resolve('data:image/png;base64,AA')
    : f.file_id === 'hung' ? new Promise(() => {})
      : f.file_id === 'bad' ? Promise.reject(new Error('403')) : Promise.resolve(''))
  it('a download that never settles prints the picture\'s name: the map comes back on time without it', { timeout: 2000 }, async () => {
    const t0 = Date.now()
    const srcs = await printImageSrcs(files, load, 100)
    assert.deepEqual(srcs, { ok: 'data:image/png;base64,AA' }, 'only the picture that loaded; the hung, failed and empty ones print their names')
    assert.ok(Date.now() - t0 < 1000, `settled in ${Date.now() - t0} ms`)
  })
  it('a load that throws at once is a missing picture, not a failed export', async () => {
    assert.deepEqual(await printImageSrcs([{ file_id: 'x' }], () => { throw new Error('sync') }, 100), {})
  })
  it('the print run fetches its pictures through printImageSrcs with the 15 s bound', () => {
    const run = src('src/utils/msg-print-run.ts')
    assert.match(run, /const IMG_WAIT_MS = 15000/)
    assert.match(run, /return printImageSrcs\(files, \(f\) => imageSrc\(f, api\), IMG_WAIT_MS\)/)
  })
  it('a newer export supersedes one still waiting: one print block, one print (R7 N2)', () => {
    const run = src('src/utils/msg-print-run.ts')
    assert.match(run, /const run = \+\+latest/)
    assert.equal((run.match(/if \(run !== latest\)/g) || []).length, 2, 'checked after the downloads and after the render settles')
  })
})

describe('Export to PDF: weight and print', () => {
  const walk = (dir) => readdirSync(join(WUI, dir), { withFileTypes: true }).flatMap((d) =>
    d.isDirectory() ? walk(`${dir}/${d.name}`) : /\.(vue|ts|mjs)$/.test(d.name) ? [`${dir}/${d.name}`] : [])
  it('the print code loads on the click only: no static import of msg-print-run or MessagePrint', () => {
    const offenders = walk('src').filter((f) => f !== 'src/utils/msg-print-run.ts'
      && /^\s*import\s[^(]*from\s+['"](~\/utils\/msg-print-run|~\/components\/MessagePrint\.vue)['"]/m.test(src(f)))
    assert.deepEqual(offenders, [])
    const lazy = walk('src').filter((f) => /import\('~\/utils\/msg-print-run'\)/.test(src(f)))
    assert.deepEqual(lazy.sort(), ['src/components/TopicExportPdf.vue', 'src/composables/useCardMenuActions.ts'])
  })
  it('while printing only the print block shows; on screen it never does', () => {
    const print = src('src/components/MessagePrint.vue')
    assert.match(print, /\.msg-print-host \{ display: none; \}/)
    assert.match(print, /@page msg-print \{/, 'a named page (R7 N1)')
    assert.doesNotMatch(print, /@page \{/, 'no unnamed @page: a later print of the WUI keeps the browser\'s own page')
    assert.match(print, /@media print \{[\s\S]*html\.msg-printing body > \*:not\(\.msg-print-host\) \{ display: none !important; \}/)
  })
  it('the print waits for every picture (a broken one keeps its alt text) and names the document', () => {
    const run = src('src/utils/msg-print-run.ts')
    assert.match(run, /img\.addEventListener\('error'/)
    assert.match(run, /document\.title = printFileName\(job\.title, job\.msgId\)/)
    assert.match(src('src/components/MessagePrint.vue'), /<img :src="srcs\[fileKey\(f\)\]" :alt="f\.name">/)
  })
  it('every locale names both entries', () => {
    for (const f of readdirSync(join(WUI, 'i18n/locales')).filter((n) => n.endsWith('.json'))) {
      const d = JSON.parse(src(`i18n/locales/${f}`))
      assert.ok(String(d.feed?.msg_menu?.export_pdf || '').includes('PDF'), `${f} feed.msg_menu.export_pdf`)
      assert.ok(String(d.topic?.export_pdf || '').includes('PDF'), `${f} topic.export_pdf`)
    }
  })
})
