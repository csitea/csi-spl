// W12 (spec 047, SPL-1166): Tenant settings -> Agents carries "Connect an
// agent" - the block to paste (claude mcp add included), the Cursor
// mcp.json and the first prompt - and each seated agent an "Add to #lobby".
// The mock tenant has seated agents, so the guide starts closed ("Connect
// another agent"); editing the agent id rewrites every line; a bad id says so.
//
// Control: before W12 the Agents page has no [data-test=connect-agent].
//
// Run:
//   pnpm run test:e2e connect-agent
//   BASE_URL=<generated bundle> pnpm run test:e2e connect-agent
import { createRequire } from 'node:module'
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

/* select the whole field first: a triple click does not select an input's text everywhere */
async function setField(p, sel, value) {
  await p.$eval(sel, (el) => { el.focus(); el.select() })
  await p.keyboard.press('Backspace')
  await p.type(sel, value)
  await new Promise((r) => setTimeout(r, 200))
}

const scriptText = (p) => p.$eval('[data-test=connect-agent-script] pre, [data-test=connect-agent-script] code', (el) => el.textContent || '').catch(() => '')

/* spec 061 FR-004: the mock ids are legacy (CLE-01, GRK-7); pin the browser's
   agent-id clock before LEGACY_ID_UNTIL so the run never turns red at it */
const pinAgentIdClock = (p) => p.evaluateOnNewDocument(() => { globalThis.SPOOL_AGENT_ID_NOW = '2026-10-02T12:00:00Z' })

const server = await startServer()
const browser = await launch()
try {
  for (const vp of [{ name: '1280', width: 1280, height: 900, mobile: false }, { name: '390', width: 390, height: 800, mobile: true }]) {
    console.log(`-- ${vp.name}`)
    const p = await browser.newPage()
    await pinAgentIdClock(p)
    await p.setViewport({ width: vp.width, height: vp.height, isMobile: vp.mobile, hasTouch: vp.mobile })
    await p.goto(server.base + '/tenant-settings/agents', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
    const guide = await p.waitForSelector('[data-test=connect-agent]', { timeout: 15000 }).catch(() => null)
    ok('the Agents page carries Connect an agent', Boolean(guide))
    if (!guide) { await p.close(); continue }
    const rows = await p.$$eval('[data-test=tenant-agent-row]', (r) => r.length)
    const open = await guide.evaluate((d) => d.open)
    ok('with agents seated the guide starts closed', rows > 0 && open === false, { rows, open })
    await p.click('[data-test=connect-agent-summary]')
    await p.waitForSelector('[data-test=connect-agent-script]', { visible: true, timeout: 5000 }).catch(() => {})
    const s = await scriptText(p)
    /* the clone url is cnf env.wui.repo_clone_url; the e2e bundle bakes an example (wf 10) */
    const clone = await p.evaluate(() => String((window.__NUXT__?.config?.public?.repoCloneUrl) || ''))
    ok('the bundle names a clone url (NUXT_PUBLIC_REPO_CLONE_URL baked for e2e)', Boolean(clone), clone)
    ok('the block builds, seats, connects and adds the MCP', Boolean(clone) && s.includes(`git clone --depth 1 '${clone}' ~/.spool/src`) &&
      /spool hub-pin --box "\$SPOOL_BOX_ID" --pubkey "\$\(spool keygen\)" --root-key "\$HOME\/Downloads\/mock\.root\.key"/.test(s) &&
      /nohup spool hub-run/.test(s) && /claude mcp add spool -- bash -c '\. ~\/\.spool\/env && exec spool mcp --as c-001'/.test(s), s.slice(0, 120))
    ok('it names this tenant', /SPOOL_TENANT='mock'/.test(s))
    const copy = await p.$('[data-test=connect-agent-script] [data-testid=code-copy]')
    ok('the block has a copy button', Boolean(copy))
    await setField(p, '[data-test=connect-agent-id]', 'grk-7')
    const s2 = await scriptText(p)
    ok('the agent id rewrites the block (upper-cased)', /mkdir -p "\$SPOOL_ROOT\/GRK-7"/.test(s2) && /spool mcp --as GRK-7/.test(s2))
    const prompt = await p.$eval('[data-test=connect-agent-prompt]', (el) => el.textContent || '').catch(() => '')
    ok('the first prompt names the agent', /You are GRK-7 on spool/.test(prompt))
    await p.click('[data-test=connect-agent-cursor] summary')
    const cursor = await p.$eval('[data-test=connect-agent-cursor]', (el) => el.textContent || '')
    ok('Cursor gets an mcp.json', /mcpServers/.test(cursor) && /exec spool mcp --as GRK-7/.test(cursor))
    /* spec 061: a new-form id stays lower case (C-004 typed reads c-004) */
    await setField(p, '[data-test=connect-agent-id]', 'C-004')
    const s3 = await scriptText(p)
    ok('a c-NNN id rewrites the block, lower case', /mkdir -p "\$SPOOL_ROOT\/c-004"/.test(s3) && /spool mcp --as c-004/.test(s3))
    await setField(p, '[data-test=connect-agent-id]', 'nope')
    ok('a bad id says so and hides the lines', Boolean(await p.waitForSelector('[data-test=connect-agent-invalid]', { timeout: 3000 }).catch(() => null)) &&
      !(await p.$('[data-test=connect-agent-script]')))
    const help = await p.$eval('[data-test=connect-agent-help]', (a) => new URL(a.href).pathname).catch(() => '')
    ok('it links the help page', help === '/help/connect-an-agent', help)
    const add = await p.$('[data-test=tenant-agent-lobby-add]')
    ok('a seated agent has Add to #lobby', Boolean(add))
    if (add) {
      await add.click()
      ok('it lands in #lobby', Boolean(await p.waitForSelector('[data-test=tenant-agent-lobby-ok]', { timeout: 5000 }).catch(() => null)))
    }
    const sw = await p.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1)
    ok('no sideways scroll', sw)
    await p.close()
  }
} finally {
  await browser.close()
  await server.stop()
}

const failed = results.filter((r) => !r.ok).length
console.log(failed ? `connect-agent: ${failed} FAILED` : `connect-agent: all ${results.length} passed`)
process.exit(failed ? 1 : 0)
