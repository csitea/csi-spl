// Spec 090 phase 4, T041 (SPL-5258): the LinkedIn Company Pages and the post
// a Company Page publish sends (src/utils/marketing-linkedin-page.mjs). The
// commentary mirrors the hub's marketing.BlogArticle (internal/marketing/
// blog.go): its three emojis are read from that file, so the two cannot
// drift silently.
//
// Red controls (each planted defect fails a line below):
//   - a fourth emoji or another order in liPageCaption -> "the hub's commentary for ..."
//   - liPagePublishErrorKey mapping 403 to marketing_meta_forbidden -> "403 says only an admin or business owner publishes"
//   - a static `import MarketingLinkedInPages` in general.vue -> "... loads the LinkedIn pages lazily"
//
// Run: node tests/unit/marketing-linkedin-page.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { LI_COMMENTARY_MAX, liPageCaption, liPageLoadView, liPagePublishErrorKey, liPageRows, liPageUrl } from '../../src/utils/marketing-linkedin-page.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

// the hub's three emojis, in its order: title, summary, link
const blog = readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/marketing/blog.go'), 'utf8')
const emoji = (name) => {
  const m = new RegExp(name + '\\s*=\\s*"\\\\U([0-9A-F]{8}) "').exec(blog)
  return m ? String.fromCodePoint(parseInt(m[1], 16)) + ' ' : '?'
}
const [eTitle, eSummary, eLink] = ['emojiTitle', 'emojiSummary', 'emojiLink'].map(emoji)
ok('the hub still has its three emojis', ![eTitle, eSummary, eLink].includes('?'))

const post = { id: '2026-11-11-hello', title: ' Hello Page ', summary: ' A summary. ' }
const got = liPageCaption(post, 'https://app.example.com/')
const want = eTitle + 'Hello Page\n\n' + eSummary + 'A summary.\n\n' + eLink + 'https://app.example.com/blog/2026-11-11-hello'
ok(`the hub's commentary for ${post.id}`, got.text === want, JSON.stringify({ got: got.text, want }))
ok('counted in characters against 3000', got.count === [...want].length && got.limit === LI_COMMENTARY_MAX && LI_COMMENTARY_MAX === 3000 && !got.over)
ok('a commentary over 3000 says so', liPageCaption({ id: 'x', title: 'a'.repeat(3001), summary: '' }, '').over)

const rows = liPageRows([{ channel_id: 'c1', organization_id: '1001', name: 'Example Company', vanity_name: 'example-co',
  status: 'active', expires_at: '2027-11-11T09:00:00Z' }, { organization_id: 'no-channel' }, null])
ok('pages become rows with the page link and the end date', rows.length === 1 && rows[0].platform === 'linkedin_page' &&
  rows[0].name === 'Example Company' && rows[0].url === 'https://www.linkedin.com/company/example-co' && rows[0].expiresAt === '2027-11-11',
JSON.stringify(rows))
ok('no vanity name, no link', liPageUrl('') === '' && liPageRows([{ channel_id: 'c', organization_id: '7' }])[0].name === '7')
ok('503 = not configured, 404 = hidden', liPageLoadView({ status: 503 }) === 'not_configured' && liPageLoadView({ status: 404 }) === 'hidden' &&
  liPageLoadView(new Error('x')) === 'failed')
ok('403 says only an admin or business owner publishes', liPagePublishErrorKey({ status: 403 }) === 'marketing_li_page_forbidden')
ok('409, 503 and the rest have their line', liPagePublishErrorKey({ status: 409 }) === 'marketing_meta_conflict' &&
  liPagePublishErrorKey({ status: 503 }) === 'marketing_li_page_not_configured' && liPagePublishErrorKey({ status: 500 }) === 'marketing_publish_failed')

// every key the helpers and the components name exists in en.json
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8')).tenant_settings
const comp = readFileSync(join(WUI, 'src/components/MarketingLinkedInPages.vue'), 'utf8') +
  readFileSync(join(WUI, 'src/components/MarketingPublish.vue'), 'utf8')
const keys = [...new Set([...comp.matchAll(/tenant_settings\.(marketing_[a-z_]+)/g)].map((m) => m[1]).concat(
  ['marketing_li_page_forbidden', 'marketing_li_page_not_configured']))]
const missing = keys.filter((k) => typeof en[k] !== 'string')
ok('every LinkedIn page key is in en.json', missing.length === 0, JSON.stringify(missing))

const general = readFileSync(join(WUI, 'src/pages/tenant-settings/general.vue'), 'utf8')
ok('Tenant settings > General loads the LinkedIn pages lazily',
  /defineAsyncComponent\(\(\) => import\('~\/components\/MarketingLinkedInPages\.vue'\)\)/.test(general) &&
  !/^import MarketingLinkedInPages/m.test(general))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs marketing-linkedin-page.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nmarketing-linkedin-page: ok')
