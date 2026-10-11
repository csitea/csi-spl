// Owner t1 afb06ae8 (HUM-10): "It should convert the Git commit hashes to
// links to github.com." ... "not really logs, but release log." ... "Both on
// mobile and on desktop". And t1 da98036e (msg 8bfe3812): "shorten the hash
// links ... to 8 characters and add three dots."
//
// The repository is <repoWebUrl><repoCommitPath><sha> (cnf env.wui.repo_*;
// the e2e bundle bakes example values, wf 10's mock generate). At 1440x900
// and 390x844:
//   1 /releases/<sha> opens the note: its sha is a link to the commit, in a
//     new tab (rel noopener), reading <8>... with the full sha on hover
//   2 back in the list, a row's sha is a link to its commit, the topmost
//     element under the finger (above the phone row's tap layer)
//   3 neither view scrolls sideways
//   4 a message: a bare https://.../releases/<40 hex> url and a
//     [<40 hex>](url) link both read <8>..., the href and the hover keep it;
//     controls: an 8-char link text and a word link text stay as written
//
// Run: BASE_URL=<generated mock bundle> node tests/e2e/release-commit-links.test.mjs
import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
/* the mock tenant's newest change (release-notes-api.mjs mockNote(0)) */
const SHA = '00000001'.repeat(5)
const FULL = '785470e9c0a1b2c3d4e5f60718293a4b5c6d7e8f'
const SHORT = FULL.slice(0, 8) + '...'
const OTHER = 'https://dev.example.org/releases/' + FULL
const COMMIT = 'https://git.example.org/acme/spool/commit/'

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${pass || ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const row = (n, body) => ({
  v: 1, files: [], channel: 'lobby', parent_task_id: null, from: 'HUM-1', from_box: 'box-wui', to: '@channel', to_box: 'box-wui',
  kind: 'note', is_parent: 1, msg_id: `f4110000-0000-4000-8000-00000000000${n}`, task_id: `f4120000-0000-4000-8000-00000000000${n}`,
  body, ts: `2026-12-31T23:5${n}:00Z`,
})
const MSGS = [
  row(1, `released ${OTHER} today`),
  row(2, `see [${FULL}](${COMMIT}${FULL}), [deadbeef](${COMMIT}deadbeef) and [the notes](${OTHER})`),
]

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

async function until(p, fn, arg, ms = 15000) {
  const start = Date.now()
  let last = null
  while (Date.now() - start < ms) {
    last = await p.evaluate(fn, arg).catch(() => null)
    if (last) return last
    await sleep(200)
  }
  return last
}

/* one link's facts, whether it is the element under its own centre, and
   whether the page or the dialog body scrolls sideways */
const facts = (p, sel) => p.evaluate((s) => {
  const a = document.querySelector(s)
  const body = document.querySelector('[data-testid=ui-dialog-body]')
  const sx = document.scrollingElement || document.documentElement
  const out = {
    overflow: sx.scrollWidth > window.innerWidth + 1 || Boolean(body && body.scrollWidth > body.clientWidth + 1),
  }
  if (!a) return { ...out, found: false }
  a.scrollIntoView({ block: 'center' })
  const r = a.getBoundingClientRect()
  const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
  return {
    ...out,
    found: true,
    tag: a.tagName.toLowerCase(),
    text: (a.textContent || '').trim(),
    href: a.getAttribute('href') || '',
    target: a.getAttribute('target') || '',
    rel: a.getAttribute('rel') || '',
    title: a.getAttribute('title') || '',
    onTop: Boolean(at && at.closest('a') === a),
    inView: r.right <= window.innerWidth + 1 && r.left >= -1,
  }
}, sel)

const linkOk = (f, sha, text) => f && f.found && f.tag === 'a' && f.href === COMMIT + sha && f.target === '_blank' && /\bnoopener\b/.test(f.rel) && f.text === text

const srv = await startServer()
const browser = await launch()
try {
  for (const vp of [{ name: '1440', width: 1440, height: 900, mobile: false }, { name: '390', width: 390, height: 844, mobile: true }]) {
    const p = await browser.newPage()
    p.setDefaultNavigationTimeout(NAV_TIMEOUT)
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    const errors = []
    p.on('pageerror', (e) => errors.push(String(e).slice(0, 300)))
    await p.evaluateOnNewDocument((rows) => {
      try { localStorage.setItem('spool.mock.extra-messages', JSON.stringify(rows)) } catch { /* private mode */ }
    }, MSGS)

    /* 1: the note's sha */
    await p.goto(`${srv.base}/releases/${SHA}`, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const shown = await until(p, (sha) => document.querySelector('[data-test=release-note]')?.getAttribute('data-sha') === sha, SHA, 30000)
    ok(`${vp.name} 1a /releases/<sha> shows that note`, Boolean(shown))
    const head = await facts(p, '[data-test=release-note-sha-link]')
    ok(`${vp.name} 1b the note's sha links to its commit, new tab, noopener`, linkOk(head, SHA, SHA.slice(0, 8) + '...'), head)
    ok(`${vp.name} 1c it reads <8>..., the hover keeps the full sha`, head.text === SHA.slice(0, 8) + '...' && head.title === SHA, head)
    ok(`${vp.name} 1d the note does not scroll sideways`, head.overflow === false, head)

    /* 2: a commit-list sha */
    await p.click('[data-test=release-note-back]').catch(() => {})
    await until(p, () => document.querySelectorAll('[data-test=release-row]').length > 0, null, 15000)
    const listed = await facts(p, `[data-test=release-row] [data-test=release-row-sha-link][href$="${SHA}"]`)
    ok(`${vp.name} 2a a row's sha links to its commit, new tab, noopener`, linkOk(listed, SHA, SHA.slice(0, 7)), listed)
    ok(`${vp.name} 2b the sha link is the element under the finger, on screen`, listed.onTop === true && listed.inView === true, listed)
    ok(`${vp.name} 3 the list does not scroll sideways`, listed.overflow === false, listed)

    /* 4: message links that read as a full hash */
    await p.goto(`${srv.base}/channel/lobby`, { waitUntil: 'domcontentloaded', timeout: NAV_TIMEOUT })
    const msgs = await until(p, (ids) => {
      const out = ids.map((id) => [...document.querySelectorAll(`article.msg[data-msg-id="${id}"] a.msg-link`)]
        .map((a) => ({ text: (a.textContent || '').trim(), href: a.getAttribute('href') || '', title: a.getAttribute('title') || '' })))
      return out[0].length >= 1 && out[1].length >= 3 ? out : null
    }, MSGS.map((m) => m.msg_id), 30000)
    const [bare, md] = msgs || [[], []]
    const bareLink = bare.find((a) => a.href === OTHER)
    ok(`${vp.name} 4a a bare /releases/<40 hex> url reads <8>..., href and hover full`, Boolean(bareLink && bareLink.text === SHORT && bareLink.title === FULL), bare)
    const mdLink = md.find((a) => a.href === COMMIT + FULL)
    ok(`${vp.name} 4b a [<40 hex>](url) link reads <8>..., href and hover full`, Boolean(mdLink && mdLink.text === SHORT && mdLink.title === FULL), md)
    const notesLink = md.find((a) => a.href === OTHER)
    ok(`${vp.name} 4c control: an 8-char and a word link text stay`, md.some((a) => a.text === 'deadbeef') && Boolean(notesLink && notesLink.text === 'the notes'), md)
    ok(`${vp.name} no page error`, errors.length === 0, errors)
    await p.close()
  }
} finally {
  await browser.close()
  await srv.stop()
}

const failed = results.filter((r) => !r.ok)
console.log(`\nrelease-commit-links: ${results.length - failed.length}/${results.length} passed`)
if (failed.length) {
  for (const f of failed) console.log(`  FAILED: ${f.name}`)
  process.exit(1)
}
