// Spec 090 T035 (SPL-4494): the connected Facebook Pages and Instagram
// accounts and the text a Meta publish sends (src/utils/marketing-meta.mjs).
// The caption mirrors the hub's metaCaption (internal/hub/marketing_meta_dispatch.go)
// and the caps its marketing/meta_publish.go.
//
// Red controls (each planted defect fails a line below):
//   - metaPageCanPost returning true always -> "a Page without a posting task cannot post"
//   - metaRowsWithout dropping only the id  -> "a Page takes its Instagram account with it"
//   - META_DISCONNECT_LIVE = true           -> "the live client offers no Disconnect yet"
//
// Run: node tests/unit/marketing-meta.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  META_LIMITS, blogPostUrl, metaAccountRows, metaCanDisconnect, metaCaption, metaCharCount, metaInitials,
  metaLoadView, metaNeedsJpeg, metaNumber, metaPageCanPost, metaPublishErrorKey, metaRowsWithout,
} from '../../src/utils/marketing-meta.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

// the caps are the hub's
const hubCaps = readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/marketing/meta_publish.go'), 'utf8')
ok('the Facebook cap is the hub\'s 63206', META_LIMITS.facebook_page === 63206 && /FacebookMessageMaxChars\s*=\s*63206/.test(hubCaps))
ok('the Instagram cap is the hub\'s 2200', META_LIMITS.instagram_business === 2200 && /InstagramCaptionMaxChars\s*=\s*2200/.test(hubCaps))

// the caption: title + summary; Instagram adds the post's address
const post = { id: '2026-10-30-hello world', title: ' Hello ', summary: 'World ' }
const fb = metaCaption('facebook_page', post, 'https://app.example.com/')
ok('Facebook text = title, blank line, summary', fb.text === 'Hello\n\nWorld' && fb.count === 12 && fb.limit === 63206 && !fb.over, JSON.stringify(fb))
const ig = metaCaption('instagram_business', post, 'https://app.example.com')
ok('Instagram text adds the escaped post address', ig.text === 'Hello\n\nWorld\n\nhttps://app.example.com/blog/2026-10-30-hello%20world' && ig.limit === 2200, JSON.stringify(ig))
ok('no summary = the title alone', metaCaption('facebook_page', { id: 'x', title: 'T' }, '').text === 'T')
const long = metaCaption('instagram_business', { id: 'x', title: 'T', summary: 'a'.repeat(2300) }, 'https://h')
ok('over the Instagram cap is flagged (the hub shortens the summary)', long.over && long.count > 2200)
ok('characters count code points, not UTF-16 units', metaCharCount('😀é') === 2)
ok('blogPostUrl trims the slash and escapes the id', blogPostUrl('https://h/', 'a b') === 'https://h/blog/a%20b')

// Instagram takes only JPEG
ok('Instagram + .webp needs a JPEG', metaNeedsJpeg('instagram_business', '/blog/x.webp'))
ok('Instagram + no picture needs a JPEG', metaNeedsJpeg('instagram_business', ''))
ok('Instagram + .JPG?v=2 is fine', !metaNeedsJpeg('instagram_business', '/blog/x.JPG?v=2'))
ok('Facebook takes any picture', !metaNeedsJpeg('facebook_page', '/blog/x.webp'))

// RED CONTROL: the Page role
ok('a Page with CREATE_CONTENT can post', metaPageCanPost(['ANALYZE', 'CREATE_CONTENT']))
ok('a Page with MANAGE can post', metaPageCanPost(['manage']))
ok('a Page without a posting task cannot post', !metaPageCanPost(['ANALYZE', 'ADVERTISE']) && !metaPageCanPost([]))
ok('unknown tasks: the hub decides', metaPageCanPost(undefined))

// the rows: a Page, then its Instagram account, tasks from the channels list
const pages = [
  { channel_id: 'p1', page_id: '1', name: 'Studio', status: 'active', instagram: { channel_id: 'i1', ig_user_id: '9', username: 'studio.x', status: 'active' } },
  { channel_id: 'p2', page_id: '2', name: 'Shop', status: 'expired', instagram: null },
  { name: 'no id' },
]
const channels = [{ channel_id: 'p1', metadata: { tasks: ['MANAGE'] } }, { channel_id: 'p2', metadata: { tasks: ['ANALYZE'] } }]
const rows = metaAccountRows(pages, channels)
ok('rows: Page, its Instagram, next Page; a row with no id is dropped', rows.map((r) => r.id).join(',') === 'p1,i1,p2', JSON.stringify(rows))
ok('the Instagram row names @username and links its Page', rows[1].name === '@studio.x' && rows[1].linked === 'p1' && rows[1].platform === 'instagram_business')
ok('a Page whose tasks hold no posting task is marked', rows[2].canPost === false && rows[0].canPost === true && rows[1].canPost === true)
ok('the status is carried', rows[2].status === 'expired')
ok('no pages answer = no rows', metaAccountRows(undefined, undefined).length === 0)

// RED CONTROL: disconnect purges the channel (and a Page's Instagram) from the UI state
ok('a Page takes its Instagram account with it', metaRowsWithout(rows, 'p1').map((r) => r.id).join(',') === 'p2')
ok('an Instagram account goes alone', metaRowsWithout(rows, 'i1').map((r) => r.id).join(',') === 'p1,p2')

// RED CONTROL: Disconnect stays off a live client until the hub route lands (SPL-4496)
ok('the live client offers no Disconnect yet', metaCanDisconnect(false) === false)
ok('the mock offers Disconnect', metaCanDisconnect(true) === true)

// the load and publish answers
ok('503 = not configured (one line, no loop)', metaLoadView({ status: 503 }) === 'not_configured')
ok('404 = hidden (the switch says why)', metaLoadView({ status: 404 }) === 'hidden')
ok('500 = failed', metaLoadView({ status: 500 }) === 'failed' && metaLoadView(null) === 'failed')
ok('422 = needs a JPEG', metaPublishErrorKey({ status: 422 }) === 'marketing_meta_needs_jpeg')
ok('409, 403, 503 have their own lines', metaPublishErrorKey({ status: 409 }) === 'marketing_meta_conflict' &&
  metaPublishErrorKey({ status: 403 }) === 'marketing_meta_forbidden' && metaPublishErrorKey({ status: 503 }) === 'marketing_meta_not_configured')
ok('anything else = failed', metaPublishErrorKey({ status: 500 }) === 'marketing_publish_failed')

ok('counts are grouped the same in every locale', metaNumber(63206) === '63\u202f206' && metaNumber(2200) === '2\u202f200' && metaNumber(12) === '12')

// the avatar
ok('initials of two words', metaInitials('Mock Studio') === 'MS')
ok('initials of @user.name', metaInitials('@mock.studio') === 'MS')
ok('no name = ?', metaInitials('') === '?')

// every key the helpers and components name exists in en.json
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8')).tenant_settings
const src = ['src/utils/marketing-meta.mjs', 'src/components/MarketingAccounts.vue', 'src/components/MarketingPublish.vue']
  .map((f) => readFileSync(join(WUI, f), 'utf8')).join('\n')
const named = [...new Set([...src.matchAll(/marketing_meta_[a-z_]+(?![a-z_.])/g)].map((m) => m[0]))]
  .filter((k) => !k.endsWith('_'))
  .flatMap((k) => (k === 'marketing_meta_platform' ? [] : [k]))
const missing = named.filter((k) => !(k in en))
ok('every marketing_meta_* key named in the code is in en.json', named.length > 20 && missing.length === 0, JSON.stringify(missing))
ok('both platform labels exist', 'marketing_meta_platform_facebook_page' in en && 'marketing_meta_platform_instagram_business' in en)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs marketing-meta.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nmarketing-meta: ok')
