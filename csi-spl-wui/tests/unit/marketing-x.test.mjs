// Spec 090 X row (SPL-5194): the X accounts and the post an X publish
// sends (src/utils/marketing-x.mjs). The text mirrors the hub's
// marketing.XPostText and the weights its XWeightedLength
// (internal/marketing/x.go): GOLDEN below is the hub's own output for these
// posts (go test, 2026-11-10), so the two cannot drift silently.
//
// Red controls (each planted defect fails a line below):
//   - ELLIPSIS_WEIGHT = 1 in marketing-x.mjs      -> "the hub's text for ..." (a shortened text weighs 281)
//   - X_URL_WEIGHT = 22                            -> "a link weighs 23, as the hub counts it"
//   - xPublishErrorKey mapping 422 to the failed line -> "422 = too long"
//   - a static `import MarketingXAccounts` in general.vue -> "Tenant settings > General loads the X accounts lazily"
//
// Run: node tests/unit/marketing-x.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { X_POST_MAX, X_URL_WEIGHT, xAccountRows, xLoadView, xPostText, xPublishErrorKey, xWeightedLength } from '../../src/utils/marketing-x.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

const hubX = readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/marketing/x.go'), 'utf8')
ok('the limit is the hub\'s 280', X_POST_MAX === 280 && /XPostMaxWeight\s*=\s*280/.test(hubX))
ok('a link weighs 23, as the hub counts it', X_URL_WEIGHT === 23 && /XURLWeight\s*=\s*23/.test(hubX) &&
  xWeightedLength('see https://example.com/a-long-address ok') === 4 + 23 + 3)
ok('CJK and emoji weigh 2, Latin 1', xWeightedLength('日本') === 4 && xWeightedLength('\u{1F4A1}') === 2 && xWeightedLength('é—’') === 3)

const GOLDEN = [
  {
    "post": {
      "id": "2026-11-10-hello",
      "title": "Hello X",
      "summary": "A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. "
    },
    "text": "Hello X\n\nA long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A long summary. A lo…\n\nhttps://app.example.com/blog/2026-11-10-hello",
    "weight": 280
  },
  {
    "post": {
      "id": "2026-11-10-cjk",
      "title": "標題",
      "summary": "日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語"
    },
    "text": "標題\n\n日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語日本語…\n\nhttps://app.example.com/blog/2026-11-10-cjk",
    "weight": 279
  },
  {
    "post": {
      "id": "2026-11-10-t",
      "title": "tttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt",
      "summary": "s"
    },
    "text": "ttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttttt…\n\nhttps://app.example.com/blog/2026-11-10-t",
    "weight": 280
  },
  {
    "post": {
      "id": "2026-11-10-short",
      "title": " Short ",
      "summary": " Fits. "
    },
    "text": "Short\n\nFits.\n\nhttps://app.example.com/blog/2026-11-10-short",
    "weight": 37
  }
]
for (const g of GOLDEN) {
  const got = xPostText(g.post, 'https://app.example.com')
  ok(`the hub's text for ${g.post.id}`, got.text === g.text && got.count === g.weight && got.count <= X_POST_MAX,
    JSON.stringify({ got: got.text.slice(-80), count: got.count, want: g.weight }))
}
ok('a short post is not shortened', !xPostText(GOLDEN[3].post, 'https://app.example.com').over)
ok('a long post says it was shortened', xPostText(GOLDEN[0].post, 'https://app.example.com').over)

const rows = xAccountRows([{ channel_id: 'c1', user_id: '42', username: 'csitea', status: 'active' }, { user_id: 'no-channel' }, null])
ok('accounts become rows named @username', rows.length === 1 && rows[0].name === '@csitea' && rows[0].platform === 'x' && rows[0].status === 'active', JSON.stringify(rows))
ok('503 = not configured, 404 = hidden', xLoadView({ status: 503 }) === 'not_configured' && xLoadView({ status: 404 }) === 'hidden' && xLoadView(new Error('x')) === 'failed')
ok('422 = too long', xPublishErrorKey({ status: 422 }) === 'marketing_x_too_long')
ok('409, 403, 503 have their own line', xPublishErrorKey({ status: 409 }) === 'marketing_meta_conflict' &&
  xPublishErrorKey({ status: 403 }) === 'marketing_x_forbidden' && xPublishErrorKey({ status: 503 }) === 'marketing_x_not_configured')

// every key the helpers and the component name exists in en.json
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8')).tenant_settings
const comp = readFileSync(join(WUI, 'src/components/MarketingXAccounts.vue'), 'utf8')
const keys = [...new Set([...comp.matchAll(/tenant_settings\.(marketing_[a-z_]+)/g)].map((m) => m[1]).concat(
  ['marketing_x_too_long', 'marketing_x_forbidden', 'marketing_x_not_configured']))]
const missing = keys.filter((k) => typeof en[k] !== 'string')
ok('every X key is in en.json', missing.length === 0, JSON.stringify(missing))

const general = readFileSync(join(WUI, 'src/pages/tenant-settings/general.vue'), 'utf8')
ok('Tenant settings > General loads the X accounts lazily', /defineAsyncComponent\(\(\) => import\('~\/components\/MarketingXAccounts\.vue'\)\)/.test(general) &&
  !/^import MarketingXAccounts/m.test(general))

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs marketing-x.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nmarketing-x: ok')
