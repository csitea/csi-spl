// SPL-982 acceptance proof against a deployed WUI (owner, prd t1 topic
// 8296eeec): on each of the four card kinds - a channel opening card
// (is_parent=1), a thread reply (is_parent=0), a DM and an issue comment -
// the header reads  name · time · [5px] · Add-emoji · [3px] · reaction chips,
// and the chips are no longer below the body. One reaction is added per kind
// through the real picker (the writes; TENANT only). With OTHER_EMAIL, a
// second member adds the same emoji to the DM card and the chip reads "<e> 2"
// with both names in its tooltip. A screenshot per kind to OUT.
//
//   BASE=https://<tenant>.<domain> TENANT=<tenant> ISSUE=<key>
//     EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> [CHANNEL=lobby]
//     [OTHER_EMAIL=<member> OTHER_PW_FILE=<0600 file>]
//     [CHROME_PATH=...] [PUPPETEER_CORE=<path>]
//     node tests/e2e/reactions-header-live.proof.mjs
//
// Writes only when the session's tenant AND the page host's tenant are
// TENANT. Passwords are read from files and never printed.
// Exit 0 = every step PASS.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { loadPuppeteer, need, sleep } from './lib/proof.mjs'

const BASE = need('BASE').replace(/\/+$/, '')
const TENANT = need('TENANT')
const ISSUE = need('ISSUE')
const OUT = need('OUT')
const CHANNEL = process.env.CHANNEL || 'lobby'
mkdirSync(OUT, { recursive: true })
const res = { base: BASE, tenant: TENANT, at: new Date().toISOString(), steps: [] }
const step = (name, ok, ev = {}) => { res.steps.push({ name, ok, ...ev }); console.log(ok ? 'PASS' : 'FAIL', name, JSON.stringify(ev)) }
async function until(fn, ms) {
  const end = Date.now() + ms
  for (;;) {
    const v = await fn().catch(() => null)
    if (v || Date.now() > end) return v
    await sleep(400)
  }
}

async function signIn(browser, email, pw) {
  const ctx = await browser.createBrowserContext()
  const p = await ctx.newPage()
  await p.setViewport({ width: 1440, height: 900 })
  await p.goto(BASE + '/login?tenant=' + encodeURIComponent(TENANT) + '&redirect=%2Flobby', { waitUntil: 'networkidle2', timeout: 60000 })
  await p.waitForSelector('[data-test=native-auth-email]', { timeout: 60000 })
  await p.type('[data-test=native-auth-email]', email)
  await p.type('[data-test=native-auth-password]', pw)
  await p.click('[data-test=native-auth-submit]')
  const ok = await p.waitForSelector('[data-test=user-menu-trigger]', { timeout: 30000 }).then(() => true, () => false)
  if (!ok) { await p.screenshot({ path: `${OUT}/signin-failed.png` }).catch(() => {}); throw new Error(`not signed in: ${email}`) }
  const where = await until(() => p.evaluate(() => {
    const app = document.querySelector('#__nuxt')?.__vue_app__
    const g = app && app.config.globalProperties
    const s = g && g.$pinia && g.$pinia.state.value.session
    const pub = (g && g.$config && g.$config.public) || null
    if (!pub || !s || !s.claims) return null
    const hosts = String(pub.tenantHosts || '0') === '1'
    let page = ''
    if (hosts) {
      const site = new URL(String(pub.siteUrl || location.origin)).hostname.toLowerCase()
      const h = location.hostname.toLowerCase()
      page = h === site ? String(pub.tenant || '') : h.endsWith('.' + site) ? h.slice(0, -site.length - 1) : '?'
    }
    return { claim: String(s.claims.t || ''), hosts, page }
  }), 15000)
  const inTenant = !!where && where.claim === TENANT && (!where.hosts || where.page === TENANT)
  if (!inTenant) throw new Error(`not in ${TENANT} (${JSON.stringify(where)}): refusing to write`)
  await sleep(1500)
  return p
}

/* the header geometry of one card */
const header = (card) => card.evaluate((a) => {
  const t = a.querySelector('.msg-time')
  const e = a.querySelector('[data-testid=msg-emoji-btn] svg')
  const chips = [...a.querySelectorAll('.msg-meta [data-testid=msg-reaction]')]
  const c = chips[0]
  const body = a.querySelector('.msg-body, .card-body')
  const tr = t && t.getBoundingClientRect()
  const er = e && e.getBoundingClientRect()
  const cr = c && c.getBoundingClientRect()
  return {
    emojiGap: tr && er ? Math.round(er.left - tr.right) : null,
    chipGap: er && cr ? Math.round(cr.left - er.right) : null,
    chipLevel: er && cr ? Math.abs(Math.round((cr.top + cr.height / 2) - (er.top + er.height / 2))) : null,
    chips: chips.map((x) => ({ text: x.textContent.replace(/\s+/g, ' ').trim(), count: x.dataset.count, title: x.getAttribute('title') })),
    chipsInHeader: chips.length > 0 && chips.every((x) => !!x.closest('.msg-meta')),
    belowBody: !!(body && [...a.querySelectorAll('[data-testid=msg-reaction]')].some((x) => x.getBoundingClientRect().top > body.getBoundingClientRect().top)),
  }
})

/* add one reaction through the picker, unless this viewer already has one */
async function react(p, card) {
  const mine = await card.evaluate((a) => !!a.querySelector('[data-testid=msg-reaction][data-mine="true"]'))
  if (mine) return 'had'
  await (await card.$('[data-testid=msg-emoji-btn]')).click()
  await p.waitForSelector('[data-testid=emoji-picker]', { visible: true, timeout: 8000 })
  await p.click('[data-testid=emoji-grid] button')
  await until(() => card.evaluate((a) => !!a.querySelector('[data-testid=msg-reaction][data-mine="true"]')), 15000)
  await sleep(500)
  return 'added'
}

async function kind(p, label, card, shot) {
  if (!card) { step(`${label}: a card was found`, false); return null }
  const how = await react(p, card)
  const h = await header(card)
  step(`${label}: name · time · 5px · emoji · 3px · chips, chips in the header and not below the body`,
    h.emojiGap >= 3 && h.emojiGap <= 7 && h.chipGap >= 1 && h.chipGap <= 5 && h.chipLevel <= 4 && h.chipsInHeader && !h.belowBody, { how, ...h })
  step(`${label}: a one-person chip is the emoji alone; a chip of 2+ shows its count`,
    h.chips.every((c) => (Number(c.count) >= 2) === /\d/.test(c.text)), { chips: h.chips })
  await card.evaluate((a) => a.scrollIntoView({ block: 'center' }))
  await sleep(300)
  await card.screenshot({ path: `${OUT}/${shot}.png` })
  return h
}

const puppeteer = await loadPuppeteer()
const browser = await puppeteer.launch({ executablePath: process.env.CHROME_PATH || '/usr/bin/google-chrome', headless: true, args: ['--no-sandbox', '--disable-dev-shm-usage'] })
try {
  res.build = await (await fetch(BASE + '/build.json')).json()
  const p = await signIn(browser, need('EMAIL'), readFileSync(need('PW_FILE'), 'utf8').trim())
  step('signed in, session and page host in TENANT', true)

  // 1. a channel opening card (is_parent=1) that has replies, so 2. can open its thread
  await p.goto(BASE + '/channel/' + encodeURIComponent(CHANNEL), { waitUntil: 'networkidle2', timeout: 60000 })
  await until(async () => (await p.$$eval('article.msg', (els) => els.length)) > 0, 20000)
  await sleep(1000)
  const opener = await p.evaluateHandle(() => [...document.querySelectorAll('article.msg')].find((a) => /^[1-9]\d* >>$/.test((a.querySelector('[data-test=topic-replies]')?.textContent || '').trim())) || document.querySelector('article.msg'))
  await kind(p, '1 opening card (is_parent=1)', opener.asElement(), 'k1-opening-card')

  // 2. a reply (is_parent=0) in that card's thread
  const link = await opener.asElement().$('[data-test=topic-replies]')
  if (link) await link.click()
  const reply = await until(async () => {
    const h = await p.evaluateHandle(() => {
      const pane = document.querySelector('[data-test=topic-section]')
      const cards = pane ? [...pane.querySelectorAll('article.msg')] : []
      return cards.length > 1 ? cards[cards.length - 1] : null
    })
    return h.asElement()
  }, 20000)
  await kind(p, '2 thread reply (is_parent=0)', reply, 'k2-thread-reply')

  // 3. a DM
  await p.click('[data-testid=sidebar-tab-dm]').catch(() => {})
  await sleep(800)
  const dmHrefs = await p.evaluate(() => [...new Set([...document.querySelectorAll('a[href*="/dm/"]')].map((x) => x.getAttribute('href')))])
  let dmCard = null
  let dmHref = ''
  for (const h of dmHrefs.slice(0, 12)) {
    await p.goto(new URL(h, BASE).href, { waitUntil: 'networkidle2', timeout: 60000 })
    dmCard = await until(async () => (await p.$('article.msg')), 6000)
    if (dmCard) { dmHref = h; break }
  }
  res.dm = dmHref
  await kind(p, '3 direct message', dmCard, 'k3-dm')
  /* read now: the handle dies when the page navigates on */
  const dmMine = dmCard ? await dmCard.evaluate((a) => ({
    emoji: a.querySelector('[data-testid=msg-reaction][data-mine="true"]')?.dataset.emoji || '',
    msgId: a.dataset.msgId || '',
  })) : { emoji: '', msgId: '' }

  // 4. an issue comment
  await p.goto(BASE + `/issues?issue=${encodeURIComponent(ISSUE)}`, { waitUntil: 'networkidle2', timeout: 60000 })
  const comment = await until(async () => (await p.$('[data-test=issues-comment]')), 20000)
  await kind(p, '4 issue comment', comment, 'k4-issue-comment')

  // 4b. a phone: the DM thread with its chips never scrolls the page sideways
  if (dmHref) {
    await p.setViewport({ width: 390, height: 844 })
    await p.goto(new URL(dmHref, BASE).href, { waitUntil: 'networkidle2', timeout: 60000 })
    await until(async () => (await p.$('article.msg [data-testid=msg-reaction]')), 10000)
    const xs = await p.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
    const over = await p.$$eval('article.msg', (els) => els.filter((a) => a.scrollWidth > a.clientWidth + 1).length)
    step('4b phone (390px): the chips never widen a card or scroll the page', xs <= 0 && over === 0, { xscroll: xs, cardsOverflowing: over })
    await p.screenshot({ path: `${OUT}/k4b-phone-dm.png` })
    await p.setViewport({ width: 1440, height: 900 })
  }

  // 5. two people, one emoji: the chip counts them and names both
  if (process.env.OTHER_EMAIL) {
    const q = await signIn(browser, process.env.OTHER_EMAIL, readFileSync(need('OTHER_PW_FILE'), 'utf8').trim())
    await q.goto(new URL(dmHref || '/lobby', BASE).href, { waitUntil: 'networkidle2', timeout: 60000 })
    const { emoji, msgId } = dmMine
    const other = await until(async () => q.$(`article.msg[data-msg-id="${msgId}"]`), 15000)
    let two = null
    if (other && emoji) {
      const chip = await other.$(`[data-testid=msg-reaction][data-emoji="${emoji}"]`)
      if (chip && !(await chip.evaluate((x) => x.dataset.mine === 'true'))) await chip.click()
      two = await until(() => other.evaluate((a, e) => {
        const c = a.querySelector(`[data-testid=msg-reaction][data-emoji="${e}"]`)
        return c && Number(c.dataset.count) >= 2 ? { text: c.textContent.replace(/\s+/g, ' ').trim(), title: c.getAttribute('title') } : null
      }, emoji), 15000)
      if (two) await other.screenshot({ path: `${OUT}/k5-two-people.png` })
    }
    step('5 two people, one emoji: the chip reads "<emoji> 2" and its tooltip names both',
      !!two && /\s2$/.test(two.text) && (two.title || '').split(', ').length >= 2, { two, dm: dmHref })
    await q.close()
  }
} catch (e) {
  step('no exception', false, { error: String(e && e.message || e).slice(0, 300) })
} finally {
  await browser.close()
  writeFileSync(`${OUT}/results.json`, JSON.stringify(res, null, 1))
}
const bad = res.steps.filter((s) => !s.ok).length
console.log(`${res.steps.length - bad}/${res.steps.length} PASS; build ${res.build && res.build.commit}`)
process.exit(bad ? 1 : 0)
