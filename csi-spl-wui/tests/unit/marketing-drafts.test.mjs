// Spec 090 section 22 (SPL-5240): the Posts section's pure part
// (src/utils/marketing-drafts.mjs), its mock twin of the hub's rules
// (tenant-settings-mock.mjs), and that every key it names is in en.json.
//
// Red controls (each planted defect fails a line below):
//   - DRAFT_MAX_CHARS = 2000                     -> "the cap is the hub's 3,000"
//   - draftOpenChannels returning every channel   -> "a channel the draft went to is not offered again"
//   - the mock's own() without the mine check     -> "the mock refuses a draft another admin wrote"
//
// Run: node tests/unit/marketing-drafts.test.mjs
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DRAFT_MAX_CHARS, draftChannelLabel, draftChars, draftErrorKey, draftOpenChannels, draftResultKey, draftStateKey } from '../../src/utils/marketing-drafts.mjs'
import { createMockTenant } from '../../src/utils/tenant-settings-mock.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const WUI = join(here, '../..')
let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

const store = readFileSync(join(WUI, '../csi-spl-api/src/go/spool-hub-api/internal/store/marketing_drafts.go'), 'utf8')
ok("the cap is the hub's 3,000", DRAFT_MAX_CHARS === 3000 && /MarketingDraftMaxChars\s*=\s*3000/.test(store))
ok('characters count as code points, as the hub counts them', draftChars('a😀é') === 3 && draftChars(undefined) === 0)
ok('a channel label is the brand and the account', draftChannelLabel({ platform: 'linkedin', name: 'FirstName LastName' }) === 'LinkedIn · FirstName LastName' &&
  draftChannelLabel({ platform: 'instagram_business', name: '' }) === 'Instagram')

const chans = [{ channel_id: 'a', platform: 'linkedin', name: 'A' }, { channel_id: 'b', platform: 'x', name: 'B' }]
ok('a channel the draft went to is not offered again',
  draftOpenChannels({ posts: [{ channel_id: 'a', status: 'published' }] }, chans).map((c) => c.channel_id).join() === 'b' &&
  draftOpenChannels({}, chans).length === 2)

ok('a result names its outcome', draftResultKey({ outcome: 'published' }) === 'tenant_settings.posts_result_published' &&
  draftResultKey({ outcome: 'deferred' }) === 'tenant_settings.posts_result_deferred' &&
  draftResultKey({ outcome: 'weird' }) === 'tenant_settings.posts_result_failed')
ok('a refusal names its reason, an unknown one the generic line',
  draftResultKey({ outcome: 'refused', error: 'x_too_long' }) === 'tenant_settings.posts_why_x_too_long' &&
  draftResultKey({ outcome: 'refused', error: '???' }) === 'tenant_settings.posts_why_internal')
ok('a post state maps to published, failed or in progress', draftStateKey('published') === 'tenant_settings.posts_result_published' &&
  draftStateKey('failed') === 'tenant_settings.posts_result_failed' && draftStateKey('dispatching') === 'tenant_settings.posts_result_scheduled')
ok('403 = not the author, 409 = published, 400 = bad input', draftErrorKey({ status: 403 }) === 'tenant_settings.posts_not_author' &&
  draftErrorKey({ status: 409 }) === 'tenant_settings.posts_locked' && draftErrorKey({ status: 400 }) === 'tenant_settings.posts_bad_input' &&
  draftErrorKey(new Error('x')) === 'tenant_settings.posts_failed')

// every key the section names exists in en.json
const en = JSON.parse(readFileSync(join(WUI, 'i18n/locales/en.json'), 'utf8')).tenant_settings
const vue = readFileSync(join(WUI, 'src/components/MarketingPostEditor.vue'), 'utf8') + readFileSync(join(WUI, 'src/utils/marketing-drafts.mjs'), 'utf8')
const named = [...vue.matchAll(/tenant_settings\.(posts_[a-z_]+)/g)].map((m) => m[1]).filter((k) => !k.endsWith('_'))
const reasons = ['already_recorded', 'instagram_needs_jpeg', 'instagram_too_long', 'x_too_long', 'not_configured', 'not_found', 'internal'].map((w) => 'posts_why_' + w)
const outcomes = ['published', 'deferred', 'retried', 'failed', 'scheduled'].map((o) => 'posts_result_' + o)
const missing = [...new Set([...named, ...reasons, ...outcomes, 'posts', 'posts_title'])].filter((k) => typeof en[k] !== 'string')
ok('every key the Posts section names is in en.json', missing.length === 0, missing.join())

// the mock plays the hub's rules
function mockOn() {
  const m = createMockTenant()
  m.setMarketing(true)
  return m
}
const thrown = (fn) => { try { fn(); return 0 } catch (e) { return e.status } }
{
  const m = mockOn()
  const d = m.createMarketingDraft({ body: 'Hello', image_url: '' })
  const r = m.publishMarketingDraft(d.id, ['mch-li-1', 'mch-ig-1', 'mch-li-1'])
  ok('the mock publishes, refuses Instagram without a JPEG and a second publish on a channel',
    r.results[0].outcome === 'published' && r.results[1].error === 'instagram_needs_jpeg' && r.results[2].error === 'already_recorded', JSON.stringify(r.results))
  ok('the mock keeps a published draft (409)', thrown(() => m.updateMarketingDraft(d.id, { body: 'x' })) === 409 && thrown(() => m.deleteMarketingDraft(d.id)) === 409)
  ok('the mock refuses a draft another admin wrote', thrown(() => m.updateMarketingDraft('mdr-other-1', { body: 'x' })) === 403 &&
    thrown(() => m.publishMarketingDraft('mdr-other-1', ['mch-li-1'])) === 403)
  ok('the mock refuses an empty text and a plain-http picture', thrown(() => m.createMarketingDraft({ body: ' ' })) === 400 &&
    thrown(() => m.createMarketingDraft({ body: 'x', image_url: 'http://example.com/a.jpg' })) === 400)
}
ok('the mock answers 404 while marketing is off', thrown(() => createMockTenant().marketingDrafts()) === 404)

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs marketing-drafts.test.mjs', suite.ok, suite.why)

if (failed) {
  console.error(`\n${failed} failure(s)`)
  process.exit(1)
}
console.log('\nmarketing-drafts: ok')
