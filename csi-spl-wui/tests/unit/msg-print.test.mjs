// SPL-5888 (owner HUM-10, t1 703f2ce5 msg 922da756; spec 005 FR-020): Export
// to PDF of one message card (its right-click menu) and of a whole topic (the
// topic header's button). The pure parts (file name, which cards print, in
// which order) and the wiring of both entries; the browser half is
// tests/e2e/msg-export-pdf.test.mjs.
//
// Red controls (each seen RED, then reverted):
//   - msgMenuItems without the `pdf` push: "the desktop menu offers Export to PDF" fails
//   - SPL-6205, on origin/master 662d8559d: the 13 tests of the two SPL-6205
//     suites fail (no whole-topic read, no menu entry; the header button
//     printed only the cards the pane showed). Planted on this tree:
//     topicExportRows printing the held rows only (the pane's opener + 30):
//     "a topic of 45 posts prints all 45" fails, 31 of 45; readWholeTopic
//     with max = 1: "a topic longer than one hub page" fails; no page cap:
//     "a hub that never ends its pages" never settles (timeout 20 -> 124)
//   - a static `import ... from '~/utils/msg-print-run'` in MessageCard.vue:
//     "the print code loads on the click only" fails
//   - printImageSrcs awaiting `load(f)` with no timer (R7 W3): "a download
//     that never settles prints the picture's name" stays pending: not ok, exit 1
// Run: node --test tests/unit/msg-print.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { msgMenuItems } from '../../src/utils/msg-menu.mjs'
import { importTs } from './lib/load-ts.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const src = (rel) => readFileSync(join(WUI, rel), 'utf8')
const { PRINT_SLUG_MAX, printFileKey, printFileName, printImageSrcs, printSlug, readWholeTopic, topicExportRows, topicPrintRows, TOPIC_EXPORT_PAGE, TOPIC_EXPORT_PAGES_MAX } = await importTs('src/utils/msg-print.ts')

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
  it('not without `pdf`, on desktop or the phone sheet', () => {
    assert.ok(!msgMenuItems({}).some((i) => i.id === 'export-pdf'))
    assert.ok(!msgMenuItems({ touch: true }).some((i) => i.id === 'export-pdf'))
  })
  it('SPL-6110: the phone sheet (`touch`) lists it right after Add to note; Archive keeps its place', () => {
    const ids = msgMenuItems({ pdf: true, touch: true, note: true, editable: true, topic: true }).map((i) => i.id)
    assert.deepEqual(ids.slice(0, 9), ['reply', 'react', 'open', 'copy-text', 'copy', 'edit', 'archive', 'add-to-note', 'export-pdf'], ids.join())
    assert.equal(ids.at(-1), 'delete-topic')
    assert.deepEqual(msgMenuItems({ pdf: true, touch: true }).find((i) => i.id === 'export-pdf'), { id: 'export-pdf', icon: 'file-text', labelKey: 'feed.msg_menu.export_pdf' })
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

describe('Export topic to PDF: the topic card menu entry of a channel feed (SPL-6205)', () => {
  const topicItem = { id: 'export-topic-pdf', icon: 'file-text', labelKey: 'topic.export_pdf' }
  it('`topicPdf` adds Export topic to PDF right after the card\'s Export to PDF on desktop, in its place on the phone sheet; Archive and Delete keep their places', () => {
    const desk = msgMenuItems({ pdf: true, topicPdf: true, note: true, topic: true }).map((i) => i.id)
    assert.deepEqual(desk.slice(0, 5), ['open', 'copy', 'add-to-note', 'export-pdf', 'export-topic-pdf'], desk.join())
    assert.deepEqual(desk.slice(-2), ['archive', 'delete-topic'])
    const phone = msgMenuItems({ pdf: true, topicPdf: true, touch: true, note: true, editable: true, topic: true }).map((i) => i.id)
    assert.deepEqual(phone.slice(0, 9), ['reply', 'react', 'open', 'copy-text', 'copy', 'edit', 'archive', 'add-to-note', 'export-topic-pdf'], phone.join())
    assert.ok(!phone.includes('export-pdf'), 'the sheet keeps its height (phone-card-menu.test.mjs)')
    assert.ok(!msgMenuItems({ pdf: true }).some((i) => i.id === 'export-topic-pdf'), 'not without topicPdf')
    assert.deepEqual(msgMenuItems({ topicPdf: true }).find((i) => i.id === 'export-topic-pdf'), topicItem, 'the existing key, no new text')
  })
  it('MessageMenu passes `topicPdf` through and emits export-topic-pdf', () => {
    const menu = src('src/components/MessageMenu.vue')
    assert.match(menu, /topicPdf: props\.topicPdf,/)
    assert.match(menu, /else if \(id === 'export-topic-pdf'\) emit\('export-topic-pdf'\)/)
  })
  it('the card asks for it only as a topic card outside an open topic, and handles it', () => {
    const card = src('src/components/MessageCard.vue')
    assert.match(card, /const topicPdf = computed\(\(\) => Boolean\(props\.topicMenu\) && !inPane\.value && Boolean\(props\.msg\.task_id\)\)/)
    assert.match(card, /:topic-pdf="topicPdf"/)
    assert.match(card, /@export-topic-pdf="onExportTopicPdf"/)
  })
  it('the action reads the whole topic, first to last, and loads msg-print and the print run on the click only', () => {
    const act = src('src/composables/useCardMenuActions.ts')
    assert.match(act, /await topicExportRows<SpoolMessage>\(\{ taskId: String\(props\.msg\.task_id \|\| ''\), held: \[props\.msg\], getTopic, newestLast: true, isHidden: \(id\) => hidden\.has\(id\) \}\)/)
    assert.match(act, /api\.getTopic\(id, o\)/)
    assert.match(act, /await import\('~\/utils\/msg-print'\)/)
    assert.doesNotMatch(act, /^import .*'~\/utils\/msg-print(-run)?'/m, 'no static import of the print code')
  })
  it('the topic header button is gone: no export inside an open topic but a post\'s own', () => {
    assert.ok(!existsSync(join(WUI, 'src/components/TopicExportPdf.vue')))
    for (const f of ['src/components/TopicPane.vue', 'src/components/LiveTopicPane.vue']) {
      assert.doesNotMatch(src(f), /TopicExportPdf|pdf-slot|exportRows/, f)
    }
  })
})

/* SPL-6205: a hub topic of n synthetic posts, read as GET /v1/view/topics/{id}
   answers it: order=desc, at most `limit` rows (the hub caps it at 200),
   `next` = the cursor of the page's oldest row while older rows remain */
function mockHub(n, task = 'task-1') {
  const all = Array.from({ length: n }, (_, i) => ({
    msg_id: `m-${String(i).padStart(4, '0')}`,
    task_id: task,
    ts: new Date(Date.UTC(2026, 10, 21, 0, 0, i)).toISOString(),
    body: `post ${i}`,
  }))
  const desc = all.slice().reverse()
  const calls = []
  const getTopic = async (id, o = {}) => {
    calls.push({ id, ...o })
    if (id !== task) return { messages: [], next: null }
    const limit = Math.min(Number(o.limit) || 50, 200)
    const from = o.before ? desc.findIndex((m) => m.msg_id === o.before) + 1 : 0
    const page = desc.slice(from, from + limit)
    return { messages: page, next: from + limit < desc.length ? page.at(-1).msg_id : null }
  }
  return { all, desc, calls, getTopic }
}
/* what the pane holds after an open: the opener + the newest WINDOW (30) */
const paneHeld = (hub) => [hub.all[0], ...hub.desc.slice(0, 30)]

describe('Export topic to PDF: every post of the topic (SPL-6205)', () => {
  it('a topic of 45 posts prints all 45, not the 31 the pane holds', async () => {
    const hub = mockHub(45)
    const rows = await topicExportRows({ taskId: 'task-1', held: paneHeld(hub), getTopic: hub.getTopic })
    assert.equal(paneHeld(hub).length, 31, 'the pane holds 31')
    assert.equal(rows.length, 45)
    assert.deepEqual(rows.map((m) => m.msg_id), hub.desc.map((m) => m.msg_id), 'newest first by default')
  })
  it('a topic longer than one hub page: every page, read with before=<next>, until no next', async () => {
    const hub = mockHub(450)
    const rows = await topicExportRows({ taskId: 'task-1', held: paneHeld(hub), getTopic: hub.getTopic })
    assert.equal(rows.length, 450)
    assert.equal(hub.calls.length, 3, '200 + 200 + 50')
    assert.deepEqual(hub.calls.map((c) => [c.order, c.limit]), Array(3).fill(['desc', TOPIC_EXPORT_PAGE]))
    assert.equal(hub.calls[0].before, undefined)
    assert.equal(hub.calls[1].before, hub.desc[199].msg_id)
  })
  it('first to last with newestLast (the menu entry)', async () => {
    const hub = mockHub(40)
    const rows = await topicExportRows({ taskId: 'task-1', held: [], getTopic: hub.getTopic, newestLast: true })
    assert.deepEqual(rows.map((m) => m.msg_id), hub.all.map((m) => m.msg_id))
  })
  it('a card hidden on this device stays out, as in the pane', async () => {
    const hub = mockHub(40)
    const gone = new Set([hub.all[3].msg_id, hub.all[35].msg_id])
    const rows = await topicExportRows({ taskId: 'task-1', held: paneHeld(hub), getTopic: hub.getTopic, isHidden: (id) => gone.has(id) })
    assert.equal(rows.length, 38)
    assert.ok(rows.every((m) => !gone.has(m.msg_id)))
  })
  it('a held row the hub read does not return (a #lobby root, a pending send) still prints, once', async () => {
    const hub = mockHub(35)
    const root = { msg_id: 'root-x', ts: '2026-11-20T00:00:00.000Z', body: 'the clicked message' }
    const rows = await topicExportRows({ taskId: 'task-1', held: [root, root, null, ...paneHeld(hub)], getTopic: hub.getTopic })
    assert.equal(rows.length, 36)
    assert.equal(rows.at(-1).msg_id, 'root-x', 'oldest, so last when newest first')
  })
  it('the pane\'s copy of a row wins (an edit shown on screen)', () => {
    const rows = topicPrintRows([{ msg_id: 'a', ts: '1', body: 'edited' }], [{ msg_id: 'a', ts: '1', body: 'old' }])
    assert.deepEqual(rows.map((m) => m.body), ['edited'])
  })
  it('no topic id: the held rows alone, no read', async () => {
    const hub = mockHub(5)
    const rows = await topicExportRows({ taskId: '', held: hub.all, getTopic: hub.getTopic })
    assert.equal(rows.length, 5)
    assert.equal(hub.calls.length, 0)
  })
  it('a hub that never ends its pages: at most TOPIC_EXPORT_PAGES_MAX reads', async () => {
    let n = 0
    const rows = await readWholeTopic(async () => ({ messages: [{ msg_id: `x${n}` }], next: `c${++n}` }))
    assert.equal(n, TOPIC_EXPORT_PAGES_MAX)
    assert.equal(rows.length, TOPIC_EXPORT_PAGES_MAX)
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
    assert.deepEqual(lazy.sort(), ['src/composables/useCardMenuActions.ts'])
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
