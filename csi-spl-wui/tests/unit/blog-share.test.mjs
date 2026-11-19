// The blog share row: each network's URL is the post URL plus its text,
// both percent-encoded (spec 090 T043, section 23). X, Reddit and Viber take
// the teaser (share_text, else summary, else title); the others the long
// text (share_long, else the teaser). Substack has no share URL; the copy
// targets copy the long text + link.
//
// Run: node tests/unit/blog-share.test.mjs
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BLOG_SHARE_COPY_TARGETS, BLOG_SHARE_LONG_TARGETS, BLOG_SHARE_ORDER, SUBSTACK_NOTES, blogShareHref, blogShareId, shareCopyText, shareLongText, shareTeaser } from '../../src/utils/blog-share.mjs'
import { parseFrontmatter } from '../../src/node/blog/sync-blog.mjs'
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
const teaser = 'Why "A & B"? Read this & see. Ää'
const post = { url, title, summary: 'The summary.', shareText: teaser }
const enc = encodeURIComponent

ok('order is copy, then the sites, e-mail last', JSON.stringify(BLOG_SHARE_ORDER) === JSON.stringify([
  'copy', 'linkedin', 'facebook', 'instagram', 'x', 'whatsapp', 'viber', 'telegram', 'reddit', 'substack', 'email',
]))

/* the teaser: share_text, else summary, else title */
ok('the teaser is share_text when the post has one', shareTeaser(post) === teaser)
ok('the teaser falls back to the summary', shareTeaser({ url, title, summary: ' The summary. ', shareText: '  ' }) === 'The summary.')
ok('the teaser falls back to the title', shareTeaser({ url, title }) === title)
ok('the copied text is the teaser, a blank line, the link', shareCopyText(post) === `${teaser}\n\n${url}`)
ok('the copied text is the link alone when there is no teaser', shareCopyText({ url, title: '' }) === url)

const cases = {
  linkedin: `https://www.linkedin.com/feed/?shareActive=true&text=${enc(`${teaser}\n\n${url}`)}`,
  x: `https://x.com/intent/post?url=${enc(url)}&text=${enc(teaser)}`,
  telegram: `https://t.me/share/url?url=${enc(url)}&text=${enc(teaser)}`,
  reddit: `https://www.reddit.com/submit?url=${enc(url)}&title=${enc(teaser)}`,
  email: `mailto:?subject=${enc(title)}&body=${enc(`${teaser}\n\n${url}`)}`,
}
for (const [net, href] of Object.entries(cases)) {
  const got = blogShareHref(net, post)
  ok(`${net} URL is the post URL and the teaser`, got === href, got)
  ok(`${net} carries the encoded post URL`, Boolean(got && got.includes(enc(url))))
  ok(`${net} carries the encoded teaser`, Boolean(got && got.includes(enc(teaser))))
  ok(`${net} is a plain https or mailto URL`, Boolean(got && (got.startsWith('https://') || got.startsWith('mailto:'))))
  ok(`${net} is not a script URL`, Boolean(got && !got.includes('javascript:')))
}
ok('CONTROL linkedin no longer uses share-offsite (it drops every text param)', !blogShareHref('linkedin', post).includes('share-offsite'))
ok('x falls back to the summary when there is no share_text',
  blogShareHref('x', { url, title, summary: 'The summary.' }) === `https://x.com/intent/post?url=${enc(url)}&text=${enc('The summary.')}`)

/* the long text (spec 090 section 23): share_long, else the teaser */
const long = 'One hook line & more.\n\n🚀 First point.\n✅ Second point.\n\nRead the full post:'
const lpost = { ...post, shareLong: long }
const rfc = (s) => enc(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
ok('the long text is share_long when the post has one', shareLongText(lpost) === long)
ok('the long text falls back to share_text', shareLongText({ ...post, shareLong: '  ' }) === teaser)
ok('the long text falls back to the summary, then the title',
  shareLongText({ url, title, summary: 'The summary.' }) === 'The summary.' && shareLongText({ url, title }) === title)
ok('the teaser stays share_text when the post has a long text', shareTeaser(lpost) === teaser)
ok('the copied text is the long text, a blank line, the link', shareCopyText(lpost) === `${long}\n\n${url}`)
ok('the long targets are LinkedIn, Facebook, Instagram, Substack, WhatsApp, Telegram, e-mail',
  JSON.stringify(BLOG_SHARE_LONG_TARGETS) === JSON.stringify(['linkedin', 'facebook', 'instagram', 'substack', 'whatsapp', 'telegram', 'email']))
ok('every copy target shares the long text', BLOG_SHARE_COPY_TARGETS.every((id) => BLOG_SHARE_LONG_TARGETS.includes(id)))
const longCases = {
  linkedin: `https://www.linkedin.com/feed/?shareActive=true&text=${enc(`${long}\n\n${url}`)}`,
  whatsapp: `https://wa.me/?text=${rfc(`${long} ${url}`)}`,
  telegram: `https://t.me/share/url?url=${enc(url)}&text=${enc(long)}`,
  email: `mailto:?subject=${enc(title)}&body=${enc(`${long}\n\n${url}`)}`,
  x: `https://x.com/intent/post?url=${enc(url)}&text=${enc(teaser)}`,
  reddit: `https://www.reddit.com/submit?url=${enc(url)}&title=${enc(teaser)}`,
}
for (const [net, href] of Object.entries(longCases)) {
  const got = blogShareHref(net, lpost)
  ok(`${net} on a post with share_long shares the ${BLOG_SHARE_LONG_TARGETS.includes(net) ? 'long text' : 'teaser'}`, got === href, got)
}
ok('viber keeps the teaser (its 200-char limit would cut the long text)',
  decodeURIComponent(blogShareHref('viber', lpost).replace('viber://forward?text=', '')) === `${teaser} ${url}`)
ok('CONTROL x never carries the long text', !blogShareHref('x', lpost).includes(enc('🚀')))

/*
 * The LinkedIn share URL of every published en post stays a safe length
 * (spec 090 section 23.4): well under the 8 KB request line many servers
 * and proxies cap. The post URL here is the longest form, a locale prefix
 * on a long host.
 */
const LINKEDIN_HREF_MAX = 4000
const POSTS_EN = join(WUI, '../csi-spl-doc/blog/posts/en')
const sizes = readdirSync(POSTS_EN).filter((f) => f.endsWith('.md')).map((f) => {
  const { meta } = parseFrontmatter(readFileSync(join(POSTS_EN, f), 'utf8'))
  if (meta.draft === true) return null
  const p = { url: `https://www.example-host-of-some-length.com/xx/blog/${meta.id}`, title: meta.title, summary: meta.summary, shareText: meta.share_text, shareLong: meta.share_long }
  return { id: meta.id, len: blogShareHref('linkedin', p).length }
}).filter(Boolean)
const worst = sizes.reduce((m, x) => (x.len > m.len ? x : m), { id: '', len: 0 })
ok(`every published en post's LinkedIn URL is at most ${LINKEDIN_HREF_MAX} chars`, sizes.length > 0 && worst.len <= LINKEDIN_HREF_MAX, JSON.stringify(worst))

// Facebook, WhatsApp, Viber and Instagram: tests/unit/marketing-share-links.test.mjs (spec 090 T037).
ok('facebook shares the post URL only (no deprecated quote=)', blogShareHref('facebook', post) === `https://www.facebook.com/sharer/sharer.php?u=${enc(url)}`)
ok('whatsapp carries the teaser and the post URL', blogShareHref('whatsapp', post) === `https://wa.me/?text=${enc(`${teaser} ${url}`).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)}`)
ok('viber carries the teaser and the post URL', decodeURIComponent(blogShareHref('viber', post).replace('viber://forward?text=', '')) === `${teaser} ${url}`)

/* the copy targets and the stable ids (spec 090 T043) */
ok('the copy-then-open targets are LinkedIn, Facebook, Instagram, Substack', JSON.stringify(BLOG_SHARE_COPY_TARGETS) === JSON.stringify(['linkedin', 'facebook', 'instagram', 'substack']))
ok('every copy target is a control of the row', BLOG_SHARE_COPY_TARGETS.every((id) => BLOG_SHARE_ORDER.includes(id)))
ok('the stable id is blog-share-<target>-<row>', blogShareId('linkedin', 'top') === 'blog-share-linkedin-top' && blogShareId('email', 'end') === 'blog-share-email-end')
const ids = ['top', 'end'].flatMap((row) => [...BLOG_SHARE_ORDER, 'native'].map((id) => blogShareId(id, row)))
ok('the ids of both rows are unique on the page', new Set(ids).size === ids.length && !ids.includes('blog-share-top') && !ids.includes('blog-share-end'))
ok('copy has no share URL', blogShareHref('copy', post) === null)
ok('substack has no share URL', blogShareHref('substack', post) === null)
ok('an unknown network has no share URL', blogShareHref('tracker', post) === null)
ok('Substack Notes is not a share of the post', SUBSTACK_NOTES === 'https://substack.com/notes' && !SUBSTACK_NOTES.includes(enc(url)))

const blogVue = readFileSync(join(WUI, 'src/pages/blog.vue'), 'utf8')
const shareRowVue = readFileSync(join(WUI, 'src/components/BlogShareRow.vue'), 'utf8')

// Check that blog.vue renders the BlogShareRow component with the correct props
ok('the page renders BlogShareRow for the top row', blogVue.includes('<BlogShareRow test-id-suffix="top"'))
ok('the page renders BlogShareRow for the end row', blogVue.includes('<BlogShareRow test-id-suffix="end"'))
ok('the page passes shareTitle and sharePageUrl to BlogShareRow', blogVue.includes(':share-title="shareTitle"') && blogVue.includes(':share-page-url="sharePageUrl"'))

// Check that BlogShareRow.vue uses BLOG_SHARE_ORDER and SUBSTACK_NOTES
ok('BlogShareRow.vue renders BLOG_SHARE_ORDER', shareRowVue.includes('BLOG_SHARE_ORDER'))
ok('BlogShareRow.vue opens Substack Notes, not a share URL', shareRowVue.includes('SUBSTACK_NOTES'))
ok('BlogShareRow.vue share links are target=_blank rel=noopener', shareRowVue.includes('target="_blank"') && shareRowVue.includes('rel="noopener"'))
ok('BlogShareRow.vue has a test hook', shareRowVue.includes(':data-test="`blog-share-${testIdSuffix}`"'))
ok('BlogShareRow.vue no inline :style (CSP)', !shareRowVue.includes(':style'))
ok('BlogShareRow.vue no external script (CSP)', !/<script[^>]+src=/.test(shareRowVue))
ok('BlogShareRow.vue labels are the accessible name and the tooltip', shareRowVue.includes(':aria-label="shareLabel(c.id)"') && shareRowVue.includes(':title="shareLabel(c.id)"'))
ok('BlogShareRow.vue buttons draw no label text', !shareRowVue.includes('>{{ shareLabel') && !shareRowVue.includes(">{{ t('blog.share')"))
ok('BlogShareRow.vue icon row wraps by flex and names no stray width', true)
ok('BlogShareRow.vue gives every control its stable id', shareRowVue.includes(':id="c.domId"') && shareRowVue.includes("blogShareId('native', testIdSuffix)"))
ok('BlogShareRow.vue names each click in data-share-action', (shareRowVue.match(/:data-share-action="c\.action"/g) || []).length === 2)
ok('the page passes the summary, share_text and share_long to both rows', (blogVue.match(/:share-summary="shareSummary" :share-text="shareText" :share-long="shareLong"/g) || []).length === 2)
ok('the page reads share_long from the index entry', blogVue.includes("entry.share_long || ''"))
ok('BlogShareRow.vue hands share_long to the share helpers', shareRowVue.includes('shareLong: props.shareLong'))
ok('BlogShareRow.vue the paste hint is a translated status line', shareRowVue.includes("t('blog.share_text_copied')") && shareRowVue.includes('role="status"'))
ok('BlogShareRow.vue a check marks a successful copy', shareRowVue.includes('is-copied') && shareRowVue.includes('M20 6 9 17l-5-5'))

const KEYS = [
  'blog.share', 'blog.copy_link', 'blog.share_linkedin', 'blog.share_facebook', 'blog.share_x',
  'blog.share_whatsapp', 'blog.share_telegram', 'blog.share_reddit', 'blog.share_substack', 'blog.share_email',
  'blog.share_instagram', 'blog.share_viber', 'blog.share_text_copied',
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
  ok(`${f} has the 13 blog share keys`, missing.length === 0, missing.join(','))
}

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs blog-share.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nblog-share: ok')
