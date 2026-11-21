// spec 149 section 12 (SPL-6204): the home page Google's OAuth app
// verification reads. /about is static HTML (src/public/about.html), read
// WITHOUT JavaScript: it names the app and Csitea, says why it asks for
// Google Calendar and links /privacy and /terms; the privacy policy carries
// the Limited Use line. The home URL leads there: the prerendered shell at /
// (no JavaScript) and the sign-in page's links row (JavaScript on) link it.
// CONTROL: a path with no file of its own is the app shell, not the About text.
//
//   BASE_URL=<generated mock bundle> node tests/e2e/about-page.test.mjs
import { startServer } from './lib/server.mjs'
import { CHROME_LAUNCH_ARGS } from './lib/viewport.mjs'
import { loadPuppeteer } from './lib/proof.mjs'

const NAV_TIMEOUT = Number(process.env.NAV_TIMEOUT ?? 60000)

const results = []
const ok = (name, pass, ev) => {
  results.push({ name, ok: pass })
  console.log(`  ${pass ? 'OK  ' : 'FAIL'} ${name}${ev === undefined ? '' : ' ' + JSON.stringify(ev)}`)
}

const server = await startServer()
const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome',
  headless: true,
  defaultViewport: { width: 1440, height: 900 },
  args: CHROME_LAUNCH_ARGS,
})
const read = (p) => p.evaluate(() => ({
  h1: document.querySelector('h1')?.textContent || '',
  text: document.body?.innerText || '',
  links: [...document.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')),
}))
try {
  const bare = await browser.newPage()
  await bare.setJavaScriptEnabled(false)
  let res = await bare.goto(server.base + '/about', { waitUntil: 'load', timeout: NAV_TIMEOUT })
  let page = await read(bare)
  ok('1 /about answers 200 and names the app without JavaScript', res?.status() === 200 && page.h1 === 'spool-hub', { status: res?.status(), h1: page.h1 })
  ok('2 it names Csitea and why it asks for Google Calendar', page.text.includes('Csitea') && page.text.includes('Why spool-hub asks for Google Calendar') && page.text.includes('Limited Use requirements'), { len: page.text.length })
  ok('3 it links /privacy and /terms', page.links.includes('/privacy') && page.links.includes('/terms'), page.links)

  await Promise.all([bare.waitForNavigation({ waitUntil: 'load', timeout: NAV_TIMEOUT }), bare.click('a[href="/privacy"]')])
  page = await read(bare)
  ok('4 its privacy link opens the policy, Limited Use in section 3', page.h1 === 'Privacy policy' && /3\. Data from Google Calendar[\s\S]*Limited Use requirements[\s\S]*4\. Why/.test(page.text), { h1: page.h1, url: bare.url() })

  await bare.goto(server.base + '/', { waitUntil: 'load', timeout: NAV_TIMEOUT })
  page = await read(bare)
  ok('5 the shell at / links /about and /privacy without JavaScript', page.links.includes('/about') && page.links.includes('/privacy'), page.links)

  res = await bare.goto(server.base + '/about-nothing-here', { waitUntil: 'load', timeout: NAV_TIMEOUT })
  page = await read(bare)
  ok('6 CONTROL: a path with no file is the app shell, not the About page', page.h1 !== 'spool-hub' && !page.text.includes('Why spool-hub asks for Google Calendar'), { status: res?.status(), h1: page.h1 })

  const app = await browser.newPage()
  const errors = []
  app.on('pageerror', (e) => errors.push(String(e && e.message)))
  await app.goto(server.base + '/login', { waitUntil: 'networkidle2', timeout: NAV_TIMEOUT })
  const about = await app.waitForSelector('[data-test=login-link-about]', { visible: true, timeout: NAV_TIMEOUT }).catch(() => null)
  const href = about ? await about.evaluate((a) => [a.getAttribute('href'), a.textContent.trim()]) : null
  const privacy = await app.$eval('[data-test=login-link-privacy]', (a) => a.getAttribute('href')).catch(() => '')
  ok('7 the sign-in page shows About and Privacy links', !!href && href[0] === '/about' && href[1] === 'About' && privacy === '/privacy', { href, privacy })
  if (about) await Promise.all([app.waitForNavigation({ waitUntil: 'load', timeout: NAV_TIMEOUT }), about.click()])
  page = await read(app)
  ok('8 the About link opens the static page', new URL(app.url()).pathname === '/about' && page.h1 === 'spool-hub', { url: app.url(), h1: page.h1 })
  ok('9 no page error', errors.length === 0, errors)
} finally {
  await browser.close()
  await server.stop()
}
const failed = results.filter((x) => !x.ok).length
console.log(`about-page: ${results.length - failed}/${results.length} passed`)
process.exit(failed ? 1 : 0)
