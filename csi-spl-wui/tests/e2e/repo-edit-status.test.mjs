// spec 075 repo-edit T12: the status chip on the doc header walks a saved
// edit Saved · pushing -> Pushed · <sha7> (the commit link); a failed push
// shows Not pushed · retry with its reason and retry pushes it; a conflict
// shows Conflict · resolve, the side-by-side view (theirs read only, mine
// editable) and Save again (base = head) resolves it; My edits lists the
// member's edits and their agent's, retries the agent's failed one and
// shows the author notice for agent saves. Desktop light + dark, and the
// conflict view stacked on a phone. The mock hub steps its worker once per
// edits read (src/utils/docs-mock.mjs).
//
// Control: before T12 there is no [data-test=repo-edit-chip]; every chip,
// retry, conflict and My edits check fails.
//
// Run:
//   BASE_URL=<generated mock bundle> SHOT_DIR=/tmp/shots pnpm run test:e2e repo-edit-status
import { mkdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)
const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

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

async function shot(p, name) {
  if (!process.env.SHOT_DIR) return
  mkdirSync(process.env.SHOT_DIR, { recursive: true })
  await p.screenshot({ path: join(process.env.SHOT_DIR, `repo-edit-status-${name}.png`) })
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const DOC = 'csi-spl-doc/doc/md/csi-spl.feature.md'
const DENIED = 'csi-spl-doc/doc/help/how-to-post.md'
const AGENT_EDIT = 'mock-edit-agent-1'

const go = (p, path) => p.evaluate((path) => document.querySelector('#__nuxt').__vue_app__.config.globalProperties.$router.push(path), path)
const has = (p, sel) => p.$(sel).then(Boolean)
const waitFor = (p, sel, timeout = 10000) => p.waitForSelector(sel, { visible: true, timeout }).then(() => true, () => false)
const docShown = (p, path) => p.waitForFunction((want) => {
  const c = document.querySelector('[data-test=docs-content]')
  return Boolean(c && c.getAttribute('data-page') === want && document.querySelector('[data-test=docs][data-state=ready]') &&
    !c.querySelector('[data-test=repo-edit]') && !c.querySelector('[data-test=repo-conflict]') && c.querySelector('[data-testid=md-block][data-rendered=true]'))
}, { timeout: 15000 }, path).then(() => true, () => false)
const h1 = (p) => p.$eval('[data-test=docs-content]', (el) => el.querySelector('h1')?.textContent?.trim() || '').catch(() => '')
const text = (p, sel) => p.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => '')
const typeInto = (p, sel, value) => p.$eval(sel, (el, value) => {
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}, value)
/** the header chip reaches `status` */
const chipIs = (p, status, timeout = 10000) => p.waitForFunction((s) => document.querySelector('[data-test=repo-edit-status] [data-test=repo-edit-chip]')?.getAttribute('data-status') === s, { timeout }, status).then(() => true, () => false)
const chipText = (p) => text(p, '[data-test=repo-edit-status] [data-test=repo-edit-chip]')

/** Edit, type, Save; the first save of a page also consents to the notice. */
async function saveEdit(p, md) {
  await p.click('[data-test=repo-edit-open]')
  await waitFor(p, '[data-test=repo-edit-source]')
  await typeInto(p, '[data-test=repo-edit-source]', md)
  await p.click('[data-test=repo-edit-save]')
  if (await waitFor(p, '[data-test=repo-edit-notice-confirm]', 1500)) await p.click('[data-test=repo-edit-notice-confirm]')
  return docShown(p, DOC)
}

const server = await startServer()
const browser = await launch()
try {
  for (const theme of ['light', 'dark']) {
    console.log(`-- 1440x900 ${theme}`)
    const p = await browser.newPage()
    await p.setViewport({ width: 1440, height: 900 })
    await p.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }])
    await p.evaluateOnNewDocument((t) => { try { localStorage.setItem('spool-theme', t) } catch { /* private mode */ } }, theme)
    await p.goto(server.base + '/docs/' + DOC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    ok(`${theme}: the editable doc opens with Edit`, await docShown(p, DOC) && await waitFor(p, '[data-test=repo-edit-open]'))
    await sleep(500)
    ok(`${theme}: CONTROL a doc with no edit shows no chip`, !(await has(p, '[data-test=repo-edit-chip]')))

    /* 1. a save: Saved · pushing -> Pushed · <sha7> */
    ok(`${theme}: setup - the edit is saved`, await saveEdit(p, `# Pushed ${theme}\n`))
    ok(`${theme}: the chip says Saved · pushing`, await waitFor(p, '[data-test=repo-edit-chip][data-status=queued], [data-test=repo-edit-chip][data-status=pushing]', 3000) && (await chipText(p)) === 'Saved · pushing', await chipText(p))
    await shot(p, `${theme}-pushing`)
    ok(`${theme}: the chip turns Pushed`, await chipIs(p, 'pushed'))
    const sha7 = await text(p, '[data-test=repo-edit-chip-commit]')
    ok(`${theme}: Pushed · <sha7>`, /^[0-9a-f]{7}$/.test(sha7) && (await chipText(p)) === `Pushed · ${sha7}`, await chipText(p))
    const href = await p.$eval('[data-test=repo-edit-chip-commit]', (e) => e.getAttribute('href') || '').catch(() => '')
    ok(`${theme}: the sha links to its commit when the repository url is set`, href === '' || new RegExp(`/commit/${sha7}[0-9a-f]{33}$`).test(href), href)
    await shot(p, `${theme}-pushed`)

    /* 2. a failed push: Not pushed · retry, with the reason; retry pushes it */
    ok(`${theme}: setup - an edit whose push fails`, await saveEdit(p, '# Fails once MOCK-FAIL\n'))
    ok(`${theme}: the chip turns Not pushed · retry`, await chipIs(p, 'failed') && (await chipText(p)) === 'Not pushed · retry', await chipText(p))
    ok(`${theme}: the failed chip carries the reason`, ((await p.$eval('[data-test=repo-edit-chip]', (e) => e.getAttribute('title') || '').catch(() => '')).includes('503')))
    await shot(p, `${theme}-failed`)
    await p.click('[data-test=repo-edit-chip-retry]')
    ok(`${theme}: retry queues it again: Saved · pushing`, await waitFor(p, '[data-test=repo-edit-chip][data-status=queued], [data-test=repo-edit-chip][data-status=pushing]', 3000))
    ok(`${theme}: then Pushed`, await chipIs(p, 'pushed'))

    /* 3. a conflict: Conflict · resolve, side by side, Save again */
    ok(`${theme}: setup - an edit that meets a conflict`, await saveEdit(p, '# Mine MOCK-CONFLICT\n\nMy line.\n'))
    ok(`${theme}: the chip turns Conflict · resolve`, await chipIs(p, 'conflict') && (await chipText(p)) === 'Conflict · resolve', await chipText(p))
    await p.click('[data-test=repo-edit-chip-resolve]')
    ok(`${theme}: resolve opens the conflict view`, await waitFor(p, '[data-test=repo-conflict-mine]') && (await p.evaluate(() => location.search)).includes('conflict='))
    const theirs = await p.$eval('[data-test=repo-conflict-theirs]', (e) => ({ v: e.value, ro: e.readOnly, x: e.getBoundingClientRect().left })).catch(() => ({}))
    const mine = await p.$eval('[data-test=repo-conflict-mine]', (e) => ({ v: e.value, ro: e.readOnly, x: e.getBoundingClientRect().left })).catch(() => ({}))
    ok(`${theme}: theirs is master now, read only`, (theirs.v || '').includes('Changed on master meanwhile') && theirs.ro === true)
    ok(`${theme}: mine is the saved edit, editable`, (mine.v || '').includes('MOCK-CONFLICT') && mine.ro === false)
    ok(`${theme}: side by side on a desktop (theirs, then mine)`, theirs.x < mine.x, { theirs: theirs.x, mine: mine.x })
    ok(`${theme}: CONTROL no Edit while resolving`, !(await has(p, '[data-test=repo-edit-open]')))
    await shot(p, `${theme}-conflict`)
    await typeInto(p, '[data-test=repo-conflict-mine]', `# Resolved ${theme}\n\nBoth lines.\n`)
    await p.click('[data-test=repo-conflict-save]')
    ok(`${theme}: Save again leaves the view with the resolved text`, await docShown(p, DOC) && (await h1(p)) === `Resolved ${theme}`, await h1(p))
    ok(`${theme}: the address drops the conflict`, !(await p.evaluate(() => location.search)).includes('conflict='))
    ok(`${theme}: the resolution is pushed`, await chipIs(p, 'pushed'))

    /* 4. My edits: own and the agent's, retry, the identity notice */
    await p.click('[data-test=repo-edits-open]')
    ok(`${theme}: My edits opens`, await waitFor(p, '[data-test=repo-edits-row]'))
    const rows = await p.$$eval('[data-test=repo-edits-row]', (els) => els.map((e) => ({ id: e.getAttribute('data-edit'), status: e.getAttribute('data-status'), by: e.querySelector('[data-test=repo-edits-by]')?.textContent.trim() })))
    ok(`${theme}: it lists the member's edits newest first`, rows.length === 5 && rows[0].by === 'By you' && rows[0].status === 'pushed', rows)
    ok(`${theme}: the resolved conflict is folded into the resolution`, rows.some((r) => r.status === 'superseded'), rows)
    const agent = rows.find((r) => r.id === AGENT_EDIT)
    ok(`${theme}: and their agent's edit, failed`, agent?.by === 'By agent c-101' && agent.status === 'failed', agent)
    ok(`${theme}: the failed agent edit shows its reason`, (await text(p, `[data-test=repo-edits-row][data-edit=${AGENT_EDIT}] [data-test=repo-edits-reason]`)).includes('503'))
    await shot(p, `${theme}-mine`)
    await p.click(`[data-test=repo-edits-row][data-edit=${AGENT_EDIT}] [data-test=repo-edit-chip-retry]`)
    ok(`${theme}: retry from My edits pushes the agent's edit`, await p.waitForFunction((id) => document.querySelector(`[data-test=repo-edits-row][data-edit=${id}]`)?.getAttribute('data-status') === 'pushed', { timeout: 10000 }, AGENT_EDIT).then(() => true, () => false))
    await p.click('[data-test=repo-edits-identity]')
    ok(`${theme}: Review my author identity shows the notice`, await waitFor(p, '[data-test=repo-edit-notice]') && (await text(p, '[data-test=repo-edit-notice-identity]')) === 'FirstName LastName <member@example.com>')
    await p.click('[data-test=repo-edit-notice-confirm]')
    ok(`${theme}: confirming records it`, await waitFor(p, '[data-test=repo-edits-identity-ok]', 5000) && !(await has(p, '[data-test=repo-edit-notice]')))
    await p.click('[data-test=repo-edits-close]')
    ok(`${theme}: back to the doc`, await docShown(p, DOC) && !(await has(p, '[data-test=repo-edits]')))

    /* CONTROL a denied doc has no chip and no Edit */
    await go(p, '/docs/' + DENIED)
    await docShown(p, DENIED)
    await sleep(400)
    ok(`${theme}: CONTROL a denied doc shows no chip`, !(await has(p, '[data-test=repo-edit-chip]')) && !(await has(p, '[data-test=repo-edit-open]')))
    await p.close()
  }

  console.log('-- 390x844 light (phone)')
  const p = await browser.newPage()
  await p.setViewport({ width: 390, height: 844, isMobile: true, hasTouch: true })
  await p.goto(server.base + '/docs/' + DOC, { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  await docShown(p, DOC)
  await waitFor(p, '[data-test=repo-edit-open]')
  await saveEdit(p, '# Phone MOCK-CONFLICT\n')
  ok('phone: the chip turns Conflict', await chipIs(p, 'conflict'))
  await p.click('[data-test=repo-edit-chip-resolve]')
  await waitFor(p, '[data-test=repo-conflict-mine]')
  const box = await p.evaluate(() => {
    const a = document.querySelector('[data-test=repo-conflict-theirs]').getBoundingClientRect()
    const b = document.querySelector('[data-test=repo-conflict-mine]').getBoundingClientRect()
    return { stacked: b.top >= a.bottom, overflow: document.documentElement.scrollWidth > document.documentElement.clientWidth }
  })
  ok('phone: theirs and mine stack', box.stacked, box)
  ok('phone: no horizontal scroll', !box.overflow, box)
  await shot(p, 'phone-conflict')
  await p.close()
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `repo-edit-status: ${failed} FAILED` : `repo-edit-status: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
