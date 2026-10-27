// Spec 090 T037 (SPL-3872): one-click share links for Facebook, Viber,
// WhatsApp and Instagram. The golden strings are the hub's
// (internal/hub/marketing_share_links_test.go): both sides encode alike.
//
// Run: node tests/unit/marketing-share-links.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { INSTAGRAM_OPEN, VIBER_MAX_TEXT, marketingShareLinks, shareEscape, viberText } from '../../src/utils/marketing-share-links.mjs'
import { blogShareHref } from '../../src/utils/blog-share.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

const link = 'https://blog.example.com/blog/2026-10-26-kids-human-experience'
const title = 'Лагер 🏕️ & деца (2027)!' // Cyrillic, an emoji with a variation selector, & ( ) !
const text = '%D0%9B%D0%B0%D0%B3%D0%B5%D1%80%20%F0%9F%8F%95%EF%B8%8F%20%26%20%D0%B4%D0%B5%D1%86%D0%B0%20%282027%29%21%20https%3A%2F%2Fblog.example.com%2Fblog%2F2026-10-26-kids-human-experience'

// Why a share URL is not safely percent-encoded: a raw space or non-ASCII, or no parse.
function encodedWhy(raw) {
  if (/[^\x21-\x7e]/.test(raw)) return `raw character in ${raw}`
  try { new URL(raw) } catch (e) { return String(e) }
  return ''
}

const l = marketingShareLinks({ url: link, title, summary: 'Летен лагер 2027.', images: ['https://blog.example.com/blog/img/k.webp'] })
const golden = {
  facebook: 'https://www.facebook.com/sharer/sharer.php?u=https%3A%2F%2Fblog.example.com%2Fblog%2F2026-10-26-kids-human-experience',
  whatsapp: `https://wa.me/?text=${text}`,
  viber: `viber://forward?text=${text}`,
}
for (const [app, want] of Object.entries(golden)) {
  ok(`${app} is the hub's golden link`, l[app] === want, l[app])
  ok(`${app} is percent-encoded`, encodedWhy(l[app]) === '', encodedWhy(l[app]))
}
ok('facebook carries u only, no deprecated quote=', !l.facebook.includes('quote=') && l.facebook.split('=').length === 2, l.facebook)
ok('instagram: caption, picture, open', l.instagram.caption === `${title}\n\nЛетен лагер 2027.\n\n${link}` &&
  l.instagram.images.length === 1 && l.instagram.open === INSTAGRAM_OPEN && INSTAGRAM_OPEN === 'https://www.instagram.com/', JSON.stringify(l.instagram))
ok('shareEscape escapes ! \' ( ) * and a space', shareEscape("a b!'()*") === 'a%20b%21%27%28%29%2A', shareEscape("a b!'()*"))
// CONTROL: the validator refuses raw Unicode and a raw space.
ok('CONTROL: raw Unicode fails the encoding check', encodedWhy(`https://wa.me/?text=${title}`) !== '')
ok('CONTROL: a raw space fails the encoding check', encodedWhy('viber://forward?text=a b') !== '')

// Viber: at most 200 characters, headline shortened, link whole.
const long = 'Лагер 🏕️ за деца '.repeat(20)
const vt = decodeURIComponent(marketingShareLinks({ url: link, title: long }).viber.slice('viber://forward?text='.length))
ok('viber text is at most 200 characters', Array.from(vt).length <= VIBER_MAX_TEXT && VIBER_MAX_TEXT === 200, Array.from(vt).length)
ok('viber text keeps the headline and the whole link', vt.startsWith('Лагер 🏕️ за деца') && vt.endsWith(`… ${link}`), vt)
ok('viber cuts no character in half', !/[\uD800-\uDBFF]$/.test(vt.split('… ')[0]), vt)
ok('CONTROL: unclamped, the long post is over 200', Array.from(`${long.trim()} ${link}`).length > VIBER_MAX_TEXT)
ok('a short viber headline is whole', viberText(title, link) === `${title} ${link}`)
ok('a link over 200 on its own is sent alone', viberText('x', `https://e.com/${'a'.repeat(250)}`) === `https://e.com/${'a'.repeat(250)}`)
const wt = decodeURIComponent(marketingShareLinks({ url: link, title: long }).whatsapp.slice('https://wa.me/?text='.length))
ok('whatsapp is not clamped', wt === `${long.trim()} ${link}`)

// The blog row builds these four from the same module.
const post = { url: link, title }
ok('blog row facebook = marketingShareLinks', blogShareHref('facebook', post) === l.facebook, blogShareHref('facebook', post))
ok('blog row whatsapp = marketingShareLinks', blogShareHref('whatsapp', post) === l.whatsapp)
ok('blog row viber = marketingShareLinks', blogShareHref('viber', post) === l.viber)
ok('blog row instagram opens Instagram', blogShareHref('instagram', post) === INSTAGRAM_OPEN)
const row = readFileSync(join(WUI, 'src/components/BlogShareRow.vue'), 'utf8')
ok('BlogShareRow copies the Instagram caption', row.includes('instagramCaption'))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs marketing-share-links.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nmarketing-share-links: ok')
