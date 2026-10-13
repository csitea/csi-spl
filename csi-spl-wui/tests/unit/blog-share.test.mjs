// The blog share row: each network's URL is the post URL plus the title,
// both percent-encoded. Substack has no share URL.
//
// Run: node tests/unit/blog-share.test.mjs
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BLOG_SHARE_ORDER, SUBSTACK_NOTES, blogShareHref } from '../../src/utils/blog-share.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

const url = 'https://example.com/blog/2026-01-02-hello'
const title = 'A & B'
const post = { url, title }
const enc = encodeURIComponent

ok('order is copy, then the sites, e-mail last', JSON.stringify(BLOG_SHARE_ORDER) === JSON.stringify([
  'copy', 'linkedin', 'facebook', 'x', 'whatsapp', 'telegram', 'reddit', 'substack', 'email',
]))

const cases = {
  linkedin: `https://www.linkedin.com/sharing/share-offsite/?url=${enc(url)}&title=${enc(title)}`,
  facebook: `https://www.facebook.com/sharer/sharer.php?u=${enc(url)}&quote=${enc(title)}`,
  x: `https://x.com/intent/post?url=${enc(url)}&text=${enc(title)}`,
  whatsapp: `https://wa.me/?text=${enc(`${title} ${url}`)}`,
  telegram: `https://t.me/share/url?url=${enc(url)}&text=${enc(title)}`,
  reddit: `https://www.reddit.com/submit?url=${enc(url)}&title=${enc(title)}`,
  email: `mailto:?subject=${enc(title)}&body=${enc(url)}`,
}
for (const [net, href] of Object.entries(cases)) {
  const got = blogShareHref(net, post)
  ok(`${net} URL is the post URL and the title`, got === href, got)
  ok(`${net} carries the encoded post URL`, Boolean(got && got.includes(enc(url))))
  ok(`${net} carries the encoded title`, Boolean(got && got.includes(enc(title))))
  ok(`${net} is a plain https or mailto URL`, Boolean(got && (got.startsWith('https://') || got.startsWith('mailto:'))))
  ok(`${net} is not a script URL`, Boolean(got && !got.includes('javascript:')))
}

ok('copy has no share URL', blogShareHref('copy', post) === null)
ok('substack has no share URL', blogShareHref('substack', post) === null)
ok('an unknown network has no share URL', blogShareHref('tracker', post) === null)
ok('Substack Notes is not a share of the post', SUBSTACK_NOTES === 'https://substack.com/notes' && !SUBSTACK_NOTES.includes(enc(url)))

const vue = readFileSync(join(WUI, 'src/pages/blog.vue'), 'utf8')
ok('the page renders BLOG_SHARE_ORDER', vue.includes('BLOG_SHARE_ORDER'))
ok('the page opens Substack Notes, not a share URL', vue.includes('SUBSTACK_NOTES'))
ok('share links are target=_blank rel=noopener', vue.includes('target="_blank"') && vue.includes('rel="noopener"'))
ok('the row has a test hook', vue.includes('data-test="blog-share"'))
ok('no inline :style (CSP)', !vue.includes(':style'))
ok('no external script (CSP)', !/<script[^>]+src=/.test(vue))
ok('labels are the accessible name and the tooltip', vue.includes(':aria-label="shareLabel(c.id)"') && vue.includes(':title="shareLabel(c.id)"'))
ok('the buttons draw no label text', !vue.includes('>{{ shareLabel') && !vue.includes(">{{ t('blog.share')"))
ok('the icon row wraps by flex and names no stray width', vue.includes('.bpost__share { display: flex; flex-wrap: wrap;') && vue.includes('min-width: 28px') && !vue.includes('359px'))
ok('a check marks a successful copy', vue.includes('is-copied') && vue.includes('M20 6 9 17l-5-5'))

const KEYS = [
  'blog.share', 'blog.copy_link', 'blog.share_linkedin', 'blog.share_facebook', 'blog.share_x',
  'blog.share_whatsapp', 'blog.share_telegram', 'blog.share_reddit', 'blog.share_substack', 'blog.share_email',
]
const locales = readdirSync(join(WUI, 'i18n/locales')).filter((f) => f.endsWith('.json')).sort()
ok('19 locale files and no es.tmp', locales.length === 19 && !existsSync(join(WUI, 'i18n/locales/es.tmp')), locales.join(','))
function flatten(d, prefix = '') {
  const out = {}
  for (const [k, v] of Object.entries(d)) {
    const full = prefix ? `${prefix}.${k}` : k
    if (v && typeof v === 'object' && !Array.isArray(v)) Object.assign(out, flatten(v, full))
    else out[full] = v
  }
  return out
}
for (const f of locales) {
  const flat = flatten(JSON.parse(readFileSync(join(WUI, 'i18n/locales', f), 'utf8')))
  const missing = KEYS.filter((k) => typeof flat[k] !== 'string' || flat[k].trim() === '')
  ok(`${f} has the 10 blog share keys`, missing.length === 0, missing.join(','))
}

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs blog-share.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nblog-share: ok')
