// CLE-3445 row E1 — editing a message, proved in a REAL browser.
//
// The owner, 2026-09-22:
//
//   "once a msg in the 3rd panel is selected, if one presses the e shortcut
//    the msg becomes once again a textbox and after once writes the new msg
//    (the old msg should be shown there) and hits the enter the msg is sent"
//
// `pnpm run typecheck` does not drive Chrome — this repo's own written lesson
// — and the unit suite drives the state machine with no DOM at all. Neither
// can tell you that pressing `e` on a focused row puts a textarea on screen
// with the old text in it. That is what this measures, in Chrome, against the
// generated bundle or a nuxi dev server, in the 3rd panel AND in the feed.
//
// It is written to FAIL LOUDLY on the one thing most likely to be got wrong.
// The pre-fill clause sits in the middle of the owner's sentence, so step 3
// asserts the textarea's value EQUALS the old body rather than asserting that
// a textarea appeared. Plant the defect and watch it go red:
//
//   PROVE_RED=prefill-empty pnpm run test:e2e:msg-edit
//
// which makes the proof itself blank the box after opening it — the same
// observable state a `beginEdit` that forgot the body would produce — so the
// gate is shown failing without editing src/. The other plants:
//
//   PROVE_RED=no-marker   the "(edited)" marker is ignored even if rendered
//   PROVE_RED=no-escape   Escape is not sent, so the original is never restored
//
// This is a `.test.mjs` and not a `.proof.mjs` on purpose: it needs no
// credentials and no live endpoint, so it runs in CI on every push
// (`10 ci: quality gate` -> `wui: browser e2e (mock, generated)`) rather than
// only when an operator remembers it. The `.proof.mjs` shelf in this directory
// is for the ones that CANNOT run there — user-menu-live, for instance, needs
// a real signed-in session.
//
// Run:
//   pnpm run test:e2e:msg-edit
//   BASE_URL=<generated bundle> pnpm run test:e2e:msg-edit     # exactly what CI does
//   OUT=/var/tmp/CLE-3445-proof pnpm run test:e2e:msg-edit     # screenshots
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { mkdirSync } from 'node:fs'
import { startServer } from './lib/server.mjs'
import { applyViewport, setPageViewport, isViewportHarnessError, CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const OUT = process.env.OUT || ''
const RED = process.env.PROVE_RED || ''
/** the lde mock #lobby task, and its root message — from HUM-1@box-wui, so editable */
const LOBBY_TASK = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const OWN_MSG = '11111111-1111-4111-8111-111111111111'
/** a message from CLE-07@box-a: not ours, and box-signed — the hub refuses both */
const THEIR_MSG = '33333333-3333-4333-8333-333333333333'
const THEIR_TASK = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
/* CLE-3446: the same CLE-07@box-a message as the ROOT of its own task - the
   3rd panel's pinned-root path, which step 8's feed path does not reach */
const BOT_MSG = '33333333-3333-4333-8333-333333333333'
const BOT_TASK = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'

if (OUT) mkdirSync(OUT, { recursive: true })

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function launch() {
  const require = createRequire(import.meta.url)
  for (const spec of [process.env.PUPPETEER_CORE, 'puppeteer-core'].filter(Boolean)) {
    try {
      const href = spec.startsWith('/') ? pathToFileURL(spec).href : pathToFileURL(require.resolve(spec)).href
      const mod = await import(href)
      const puppeteer = mod.default ?? mod
      return puppeteer.launch({
        executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
        headless: true,
        defaultViewport: null,
        args: CHROME_LAUNCH_ARGS,
      })
    } catch { /* try the next spec */ }
  }
  throw new Error('puppeteer-core not resolvable: set PUPPETEER_CORE')
}

/** The shell's own pinia stores, the way the page's click handlers reach them. */
const drive = (p, fn, arg) => p.evaluate((fn, arg) => {
  const app = document.querySelector('#__nuxt')?.__vue_app__
  const pinia = app?.config?.globalProperties?.$pinia
  if (!pinia) return 'no-pinia'
  const pane = pinia._s.get('live-pane')
  const topic = pinia._s.get('topic')
  if (!pane || !topic) return 'no-store'
  if (fn === 'openPane') {
    topic.setTarget({ taskId: arg.taskId, mode: 'message', rootMsgId: arg.msgId, parentTaskId: arg.parent }, arg.row)
    void pane.open(arg.taskId)
  }
  if (fn === 'openTask') {
    topic.setTarget({ taskId: arg, mode: 'task', rootMsgId: '', parentTaskId: '' }, null)
    void pane.open(arg)
  }
  return 'ok'
}, fn, arg)

/** The row object the pane pins as its root, read out of the main feed store. */
const rowFromStore = (p, msgId) => p.evaluate((msgId) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const main = pinia?._s.get('live-main')
  const m = main?.messages?.find((x) => x.msg_id === msgId)
  return m ? JSON.parse(JSON.stringify(m)) : null
}, msgId)

/** The same, out of the 3rd panel's own store (live-pane). */
const rowFromPane = (p, msgId) => p.evaluate((msgId) => {
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const pane = pinia?._s.get('live-pane')
  const m = pane?.messages?.find((x) => x.msg_id === msgId)
  return m ? JSON.parse(JSON.stringify(m)) : null
}, msgId)

/** What a row on screen actually shows. `where` scopes it to the 3rd panel. */
const readRow = (p, msgId, where = '') => p.evaluate((msgId, where) => {
  const scope = where ? document.querySelector(where) : document
  const row = scope ? scope.querySelector(`article.msg[data-msg-id="${msgId}"]`) : null
  if (!row) return { found: false }
  const box = row.querySelector('[data-test=msg-edit-box]')
  const body = row.querySelector('.msg-body')
  const marker = row.querySelector('[data-test=msg-edited]')
  const error = row.querySelector('[data-test=msg-edit-error]')
  return {
    found: true,
    editing: Boolean(box),
    boxValue: box ? box.value : null,
    boxDisabled: box ? box.disabled : null,
    /* an editing row must show NO rendered body: it IS the box now */
    bodyShown: Boolean(body),
    bodyText: body ? body.textContent.trim() : '',
    marker: marker ? marker.textContent.trim() : '',
    error: error ? error.textContent.trim() : '',
    focusedIsBox: Boolean(box) && document.activeElement === box,
    focusedIsRow: document.activeElement === row,
  }
}, msgId, where)

/** Focus a row the way a Tab walk would leave it. */
const focusRow = (p, msgId, where = '') => p.evaluate((msgId, where) => {
  const scope = where ? document.querySelector(where) : document
  const row = scope ? scope.querySelector(`article.msg[data-msg-id="${msgId}"]`) : null
  if (!row) return false
  row.focus()
  return document.activeElement === row
}, msgId, where)

/** PROVE_RED=prefill-empty: blank the box the implementation just pre-filled. */
async function plantPrefill(p, msgId) {
  if (RED !== 'prefill-empty') return
  await p.evaluate((msgId) => {
    const box = document.querySelector(`article.msg[data-msg-id="${msgId}"] [data-test=msg-edit-box]`)
    if (!box) return
    const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set
    setter.call(box, '')
    box.dispatchEvent(new Event('input', { bubbles: true }))
  }, msgId)
  await sleep(150)
}

/** Who the 3rd panel's pinned root actually IS, read off the rendered card. */
const paneRootIdentity = (p) => p.evaluate(() => {
  const row = document.querySelector('[data-test=topic-section] [data-test=topic-root] article.msg')
  if (!row) return { found: false }
  const pinia = document.querySelector('#__nuxt')?.__vue_app__?.config?.globalProperties?.$pinia
  const pane = pinia?._s.get('live-pane')
  const id = row.getAttribute('data-msg-id') || ''
  const m = pane?.messages?.find((x) => x.msg_id === id) || null
  return {
    found: true,
    msg_id: id,
    from: m ? m.from : null,
    from_box: m ? m.from_box : null,
    pending: m ? Boolean(m.pending) : null,
    editing: Boolean(row.querySelector('[data-test=msg-edit-box]')),
  }
})

/**
 * PROVE_RED=keep-editor — put the bot root back into the exact observable
 * state the defect produced, without editing src/.
 *
 * The FIRST version of this plant pressed `e` on the bot root and the gate
 * stayed green, because pressing `e` there is the thing the fix legitimately
 * refuses: the plant was asking for the defect through the front door, which
 * is locked. A plant that cannot fail is the same vacuous pass this gate
 * exists to catch, so it is written against the OBSERVABLE state instead.
 *
 * What the real defect looked like, measured in Chrome before the fix:
 *   {"editing":true,"boxValue":"Welcome to **#lobby**. This is the lde mock
 *    feed.","root":{"msg_id":"33333333-…"}}
 * i.e. a [data-test=msg-edit-box] inside the bot's pinned root, holding the
 * PREVIOUS row's body. That is what this injects.
 *
 * Note that the natural red is the stronger evidence and it is on the record:
 * this assertion failed on the unfixed tree with exactly the output above and
 * passed once TopicPane / LiveTopicPane / t/[task_id] keyed the mount. The
 * plant is here so the gate can be re-demonstrated later, not as its proof.
 */
async function plantKeepEditor(p) {
  if (RED !== 'keep-editor') return
  await p.evaluate(() => {
    const row = document.querySelector('[data-test=topic-section] [data-test=topic-root] article.msg')
    if (!row || row.querySelector('[data-test=msg-edit-box]')) return
    const body = row.querySelector('.msg-body')
    const box = document.createElement('textarea')
    box.setAttribute('data-test', 'msg-edit-box')
    box.className = 'msg-edit-box'
    box.value = 'Welcome to **#lobby**. This is the lde mock feed.'
    if (body) body.replaceWith(box)
    else row.appendChild(box)
  })
  await sleep(300)
}

const srv = await startServer()
const browser = await launch()
let page
try {
  page = await browser.newPage()
  page.setDefaultNavigationTimeout(NAV_TIMEOUT)
  const consoleErrors = []
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 240)) })
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + String(e).slice(0, 240)))

  const vp = { name: 'desktop 1280x800', width: 1280, height: 800 }
  await setPageViewport(page, vp)
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await applyViewport(page, vp)
  await page.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"]`, { timeout: NAV_TIMEOUT })
  await sleep(600)

  /* ---- 1. the 3rd panel: open the topic rooted at our own message ------ */
  const row = await rowFromStore(page, OWN_MSG)
  ok('the lobby feed holds our own message', Boolean(row), { msg_id: row && row.msg_id, from: row && row.from, from_box: row && row.from_box })
  await drive(page, 'openPane', { taskId: OWN_MSG, msgId: OWN_MSG, parent: LOBBY_TASK, row })
  await page.waitForSelector('[data-test=topic-section] [data-test=topic-root] article.msg', { timeout: NAV_TIMEOUT })
  await sleep(800)
  const PANE = '[data-test=topic-section] [data-test=topic-root]'
  let seen = await readRow(page, OWN_MSG, PANE)
  /*
   * The ORIGINAL is read from the STORE, not from `.msg-body`.
   *
   * The first version of this proof compared the textarea against the
   * rendered text and failed with
   *   expected "Welcome to #lobby. …"  got "Welcome to **#lobby**. …"
   * — the editor was right and the assertion was wrong: MessageBody renders
   * markdown, so `.msg-body` shows `#lobby` where the stored body says
   * `**#lobby**`. An editor must open on the SOURCE, because that is what the
   * author typed and what they are about to send back.
   */
  const ORIGINAL = String(row && row.body)
  const RENDERED = seen.bodyText
  ok('the 3rd panel is rooted at that message', seen.found && !seen.editing && RENDERED.length > 0, { body: RENDERED.slice(0, 60) })
  ok('the stored body really does differ from the rendered one (so the check above has teeth)',
    ORIGINAL !== RENDERED, { stored: ORIGINAL.slice(0, 50), rendered: RENDERED.slice(0, 50) })
  ok('it shows no "(edited)" marker before anything was edited', seen.marker === '', { marker: seen.marker })
  if (OUT) await page.screenshot({ path: `${OUT}/1-pane-before.png` })

  /* ---- 2. `e` on the focused row turns it into a textbox --------------- */
  const focused = await focusRow(page, OWN_MSG, PANE)
  ok('the row takes keyboard focus', focused)
  await page.keyboard.press('e')
  await sleep(400)
  await plantPrefill(page, OWN_MSG)
  seen = await readRow(page, OWN_MSG, PANE)
  ok('pressing e turns the message into a textbox', seen.editing, { editing: seen.editing })
  ok('the rendered body is replaced by the box, not shown beside it', seen.editing && !seen.bodyShown, { bodyShown: seen.bodyShown })
  ok('the caret is IN the box, so typing goes there', seen.focusedIsBox, { focusedIsBox: seen.focusedIsBox })

  /* ---- 3. THE ONE THAT MATTERS: the old msg is shown there ------------- */
  ok('the box is PRE-FILLED with the old message, as SOURCE not as rendered markdown',
    seen.boxValue === ORIGINAL,
    { expected: ORIGINAL.slice(0, 60), got: String(seen.boxValue).slice(0, 60), plant: RED || 'none' })

  /* ---- 4. Escape restores the original and hands focus back ------------ */
  await page.keyboard.type(' SCRIBBLE')
  await sleep(150)
  if (RED !== 'no-escape') await page.keyboard.press('Escape')
  await sleep(400)
  seen = await readRow(page, OWN_MSG, PANE)
  ok('Escape closes the editor', !seen.editing, { editing: seen.editing })
  ok('Escape restores the ORIGINAL body — the scribble is gone', seen.bodyText === RENDERED,
    { expected: RENDERED.slice(0, 60), got: seen.bodyText.slice(0, 60) })
  ok('Escape gives the keyboard back to the row', seen.focusedIsRow, { focusedIsRow: seen.focusedIsRow })
  if (OUT) await page.screenshot({ path: `${OUT}/2-after-escape.png` })

  /* ---- 5. type a new message and press Enter --------------------------- */
  const NEW = `edited by CLE-3445 ${Date.now().toString(36)}`
  await focusRow(page, OWN_MSG, PANE)
  await page.keyboard.press('e')
  await sleep(400)
  await page.keyboard.down('Control')
  await page.keyboard.press('KeyA')
  await page.keyboard.up('Control')
  await page.keyboard.type(NEW)
  await sleep(150)
  seen = await readRow(page, OWN_MSG, PANE)
  ok('the box holds what was typed', seen.boxValue === NEW, { got: String(seen.boxValue).slice(0, 60) })
  await page.keyboard.press('Enter')
  await page.waitForFunction((id, want) => {
    const b = document.querySelector(`[data-test=topic-section] [data-test=topic-root] article.msg[data-msg-id="${id}"] .msg-body`)
    return Boolean(b && b.textContent.includes(want))
  }, { polling: 'mutation', timeout: 20000 }, OWN_MSG, NEW).catch(() => {})
  await sleep(500)
  seen = await readRow(page, OWN_MSG, PANE)
  ok('Enter sends it: the editor closes', !seen.editing, { editing: seen.editing, error: seen.error })
  ok('the row now shows the NEW message', seen.bodyText === NEW, { expected: NEW, got: seen.bodyText.slice(0, 60) })
  const markerSeen = RED === 'no-marker' ? '' : seen.marker
  ok('the row is marked as edited', markerSeen.length > 0, { marker: seen.marker, plant: RED || 'none' })
  if (OUT) await page.screenshot({ path: `${OUT}/3-after-edit.png` })

  /* ---- 6. the same row in the FEED behind the panel was updated too ---- */
  const inFeed = await readRow(page, OWN_MSG, '.feed-col')
  ok('the same message in the feed shows the new body (one edit, every copy)',
    inFeed.found && inFeed.bodyText === NEW, { found: inFeed.found, got: inFeed.bodyText.slice(0, 60) })
  ok('and it carries the edited marker there too', inFeed.marker.length > 0, { marker: inFeed.marker })

  /* ---- 7. it is in the DATA, not only in the DOM ------------------------ */
  /*
   * NOT a page reload, and the reason is a property of the harness rather
   * than of the feature: the mock tenant's store is `cloneMock()` inside the
   * spool-client module, so a reload builds a fresh client and every edit is
   * gone. That says nothing about the WUI. Durability across a reload is a
   * HUB property and is not provable here — see the header note about the
   * endpoint not being deployed.
   *
   * What IS provable is that the edit reached the data layer rather than
   * only the rendered row: re-read the topic through the client's own API
   * and look at the body it answers with.
   */
  const reread = await page.evaluate(async (id, task) => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const pinia = app?.config?.globalProperties?.$pinia
    const main = pinia?._s.get('live-main')
    if (!main) return { ok: false, why: 'no store' }
    await main.catchUpAfterReconnect()
    const m = main.messages.find((x) => x.msg_id === id)
    return { ok: true, body: m ? m.body : null, edited_at: m ? m.edited_at : null, task }
  }, OWN_MSG, LOBBY_TASK)
  ok('a fresh read from the API returns the NEW body and the edit marker',
    reread.ok && reread.body === NEW && Boolean(reread.edited_at),
    { body: reread.body && reread.body.slice(0, 60), edited_at: reread.edited_at, why: reread.why })

  /* ---- 8. `e` is NOT offered on somebody else's message ---------------- */
  /* author-only, no time window (message-edit-v1 §4): the hub answers 403
     not_author / 409 not_editable for one of these, so offering the shortcut
     would open an editor that cannot save */
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await drive(page, 'openTask', THEIR_TASK)
  await sleep(1500)
  const theirFocused = await focusRow(page, THEIR_MSG, '[data-test=topic-section]')
  if (theirFocused) {
    await page.keyboard.press('e')
    await sleep(400)
    const theirs = await readRow(page, THEIR_MSG, '[data-test=topic-section]')
    ok("pressing e on somebody else's message does NOT open an editor", !theirs.editing, { editing: theirs.editing })
  } else {
    ok("pressing e on somebody else's message does NOT open an editor", false, { reason: 'their row was not on screen to focus' })
  }

  /* ---- 8.1 CLE-3446: an OPEN editor must not survive a root swap ------- */
  /*
   * THE OWNER'S BUG, 2026-09-22: "the editing of the msg appears whenever the
   * bot is sending" - and "of course msgs sent by bots should not be editable".
   *
   * Step 8 above navigates first (`page.goto`), which throws the MessageCard
   * away and builds a fresh one. That is why it passed all day while the owner
   * was looking at the defect: the path it exercises is not the path the 3rd
   * panel uses. The pinned root is mounted as
   * `<MessageCard v-if="root" :msg="root">` with NO `:key` (TopicPane.vue,
   * LiveTopicPane.vue, pages/t/[task_id].vue), so swapping the topic PATCHES
   * one instance instead of replacing it, and the card's local `edit` ref - an
   * open textarea - rides across onto a row `canEdit()` says false for.
   *
   * So this asserts the state AFTER a swap with the editor open, with no
   * navigation in between. Plant the defect and watch it go red:
   *
   *   PROVE_RED=keep-editor pnpm run test:e2e:msg-edit
   *
   * which re-opens the editor on the bot root after the swap, reproducing the
   * un-keyed card's behaviour without editing src/.
   */
  await page.goto(`${srv.base}/lobby`, { waitUntil: 'networkidle2' })
  await page.waitForSelector('.spool-shell', { timeout: NAV_TIMEOUT })
  await page.waitForSelector(`article.msg[data-msg-id="${OWN_MSG}"]`, { timeout: NAV_TIMEOUT })
  await sleep(600)
  const ownRow2 = await rowFromStore(page, OWN_MSG)

  /* Learn the bot row first, from the store, so the swap below carries a REAL
     row rather than one this test invented. CLE-07@box-a fails both clauses of
     the published predicate (`m.from === <my HUM-id> && m.from_box === 'box-wui'`). */
  await drive(page, 'openTask', THEIR_TASK)
  await sleep(1200)
  const botRow = await rowFromPane(page, BOT_MSG)
  ok('8.1 setup: the bot row is real and fails BOTH clauses of the predicate',
    Boolean(botRow) && botRow.from === 'CLE-07' && botRow.from_box === 'box-a',
    { from: botRow && botRow.from, from_box: botRow && botRow.from_box })

  await drive(page, 'openPane', { taskId: OWN_MSG, msgId: OWN_MSG, parent: LOBBY_TASK, row: ownRow2 })
  await page.waitForSelector(`${PANE} article.msg`, { timeout: NAV_TIMEOUT })
  await sleep(800)
  await focusRow(page, OWN_MSG, PANE)
  await page.keyboard.press('e')
  await sleep(400)
  const armed = await readRow(page, OWN_MSG, PANE)
  ok('8.1 setup: the editor is open on our OWN root row', armed.editing, { editing: armed.editing })

  /* Swap the pinned root to the BOT message, the way clicking a row does:
     a MESSAGE-rooted target plus pane.open(). `taskId` is reassigned without
     ever passing through null (stores/live.ts open()), so the pane's <aside>
     is never torn down -- which is the whole point: a remount would build a
     fresh MessageCard and hide the defect, exactly as step 8's page.goto does. */
  await drive(page, 'openPane', { taskId: BOT_MSG, msgId: BOT_MSG, parent: THEIR_TASK, row: botRow })
  await sleep(1500)
  await plantKeepEditor(page)
  const swapped = await readRow(page, BOT_MSG, PANE)
  const botIdentity = await paneRootIdentity(page)
  ok('8.1 setup: the 3rd panel is now rooted at the BOT message',
    swapped.found && botIdentity.msg_id === BOT_MSG, { found: swapped.found, root: botIdentity })

  /* THE ASSERTION the owner is waiting on */
  ok('CLE-3446: no editor is left open on the bot message after the root swap',
    swapped.found && !swapped.editing,
    { editing: swapped.editing, boxValue: swapped.boxValue, root: botIdentity, plant: RED || 'none' })

  /* and `e` still must not open one on it */
  const botFocused = await focusRow(page, BOT_MSG, PANE)
  if (botFocused) {
    await page.keyboard.press('e')
    await sleep(400)
    const afterE = await readRow(page, BOT_MSG, PANE)
    ok('CLE-3446: pressing e on the bot root does NOT open an editor', !afterE.editing, { editing: afterE.editing })
  } else {
    ok('CLE-3446: pressing e on the bot root does NOT open an editor', false, { reason: 'the bot root was not focusable' })
  }

  /* ---- 9. nothing the browser REFUSED, and no script blew up ---------- */
  /*
   * Deliberately narrow, because this gate runs in CI and a gate that goes
   * red for somebody else's reason is worse than no gate.
   *
   * What is asserted: CSP violations, and page errors (an exception that
   * escaped). Those are this lane's business — a new inline handler or a new
   * style would trip the deployed CSP, and the editor is new DOM.
   *
   * What is NOT asserted: failed resource loads. The harness's own stub API
   * answers 401 / 404 by design, and a local run without the stub produces
   * 502s; neither says anything about editing a message. `console-errors`
   * is its own gate on trunk and owns that question already — restating it
   * here would only mean two jobs going red for one unrelated cause.
   */
  const RESOURCE = /Failed to load resource/i
  const csp = consoleErrors.filter((m) => /Content Security Policy|Refused to/i.test(m))
  const pageErrors = consoleErrors.filter((m) => m.startsWith('pageerror:'))
  ok('no CSP violation and no uncaught page error', csp.length === 0 && pageErrors.length === 0,
    { csp: csp.slice(0, 2), pageErrors: pageErrors.slice(0, 2),
      resource_errors_not_asserted: consoleErrors.filter((m) => RESOURCE.test(m)).length })
} catch (e) {
  if (isViewportHarnessError(e)) ok('harness: the viewport was applied', false, { error: String(e.message) })
  else ok('the proof ran to the end', false, { error: String(e && e.message ? e.message : e).slice(0, 300) })
} finally {
  await browser.close()
  await srv.stop()
}

const bad = results.filter((r) => !r.ok)
console.log(`\n${results.length - bad.length}/${results.length} OK${RED ? `  (PROVE_RED=${RED})` : ''}`)
if (bad.length) console.log('FAILED:\n' + bad.map((b) => '  - ' + b.name).join('\n'))
process.exit(bad.length ? 1 : 0)
