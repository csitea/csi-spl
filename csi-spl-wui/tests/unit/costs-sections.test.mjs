// SPL-4187 (spec 123 5.5; owner HUM-10, t1 e2c0e6b4, msgs 81217a3f,
// 8c7f4962): the three Costs sections' pure parts - Cloud's three levels
// (per GCP project with its box= label, per service, per day), the AI
// tokens parts, the mock day route - and that the new pages stay out of the
// shell and every new string is in every locale.
//
// Run: node --test tests/unit/costs-sections.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  CLOUD_SOURCE, HUMAN_ROWS, cloudDaysOf, cloudDaysQuery, cloudProjectOf, cloudProjects, cloudServiceDays, cloudServices,
  cloudTotal, mockCloudDays, sectionAmount, tokenParts,
} from '../../src/utils/costs-sections.mjs'
import { costMonthOf, mockTenantCostsBody } from '../../src/utils/tenant-costs.mjs'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const part = (source, pov, kind, usd, extra = {}) => ({
  estate: true, source, projectOrVendor: pov, kind, origin: 'billing_export', units: 0,
  usdMicros: usd, eurMicros: Math.round(usd * 0.9), secondMicros: Math.round(usd * 0.9), days: 3, listValueMicros: null, ...extra,
})
/* today's prd shape (c-002, 2026-10-29): one project billed with and without a box label */
const PARTS = [
  part('gcp', 'csi-spl-all/box=satellite', 'compute-engine', 70_000_000),
  part('gcp', 'csi-spl-all/box=satellite', 'networking', 3_590_000),
  part('gcp', 'csi-spl-prd', 'cloud-sql', 20_000_000),
  part('gcp', 'csi-spl-prd', 'cloud-run', 16_270_000, { secondMicros: null }),
  part('gcp', 'other-project', 'cloud-storage', 10_000),
  part('fleet_tokens.box-a', 'claude', 'tokens', 0, { units: 3e8, listValueMicros: 90_000_000 }),
  part('ai_paid', 'claude', 'max', 180_000_000),
  part('hand', 'llm-vendor', 'invoice', 5_000_000),
  part('gcp', 'workspace-own', 'cloud-run', 1_000_000, { estate: false }),
]

describe('Cloud level 1: per GCP project', () => {
  it('one row per project, the most expensive first, the box label apart, services counted', () => {
    const rows = cloudProjects(PARTS)
    assert.deepEqual(rows.map((r) => [r.project, r.box, r.usdMicros, r.services]), [
      ['csi-spl-all', 'satellite', 73_590_000, 2], ['csi-spl-prd', '', 36_270_000, 2], ['other-project', '', 10_000, 1],
    ])
  })
  it('a project outside csi-spl- is listed (every project of the export); a workspace\'s own gcp line and the other sources are not', () => {
    const povs = cloudProjects(PARTS).map((r) => r.pov)
    assert.ok(povs.includes('other-project'))
    assert.ok(!povs.includes('workspace-own') && !povs.includes('claude') && !povs.includes('llm-vendor'))
  })
  it('a project with a day without rate has no second-currency amount (never a guess); USD still sums', () => {
    const prd = cloudProjects(PARTS).find((r) => r.project === 'csi-spl-prd')
    assert.equal(prd.secondMicros, null)
    assert.equal(sectionAmount(prd, 'USD'), 36_270_000)
    assert.equal(sectionAmount(prd, 'EUR'), null)
    assert.equal(cloudTotal(cloudProjects(PARTS)).usdMicros, 109_870_000)
  })
  it('cloudProjectOf splits the reader\'s "<project>/box=<label>"', () => {
    assert.deepEqual(cloudProjectOf('csi-spl-dev/box=wine-box'), { project: 'csi-spl-dev', box: 'wine-box' })
    assert.deepEqual(cloudProjectOf('csi-spl-dev'), { project: 'csi-spl-dev', box: '' })
  })
})

describe('Cloud levels 2 and 3: per service, per day', () => {
  it('a project\'s services, the most expensive first', () => {
    assert.deepEqual(cloudServices(PARTS, 'csi-spl-all/box=satellite').map((r) => [r.kind, r.usdMicros, r.days]), [
      ['compute-engine', 70_000_000, 3], ['networking', 3_590_000, 3],
    ])
    assert.deepEqual(cloudServices(PARTS, 'csi-spl-all'), [], 'the box-labelled pov is its own project row')
  })
  it('the day body: one service\'s days, oldest first; a day with no rate keeps null', () => {
    const v = cloudDaysOf({ month: '2026-10', project: 'csi-spl-prd', days: [
      { day: '2026-10-24', kind: 'cloud-run', usd_micros: 2, eur_micros: 1, second_micros: null },
      { day: '2026-10-23', kind: 'cloud-run', usd_micros: 1, eur_micros: 1, second_micros: 1 },
      { day: '2026-10-23', kind: 'cloud-sql', usd_micros: 5, eur_micros: 4, second_micros: 4 },
      { day: 'bad', kind: 'cloud-run', usd_micros: 9 },
    ] })
    assert.deepEqual(cloudServiceDays(v, 'cloud-run').map((d) => [d.day, d.usdMicros, d.secondMicros]), [['2026-10-23', 1, 1], ['2026-10-24', 2, null]])
    assert.deepEqual(cloudDaysOf(null).days, [])
  })
  it('the route query names the month and the project, escaped', () => {
    assert.equal(cloudDaysQuery('2026-10', 'csi-spl-all/box=satellite'), '?month=2026-10&project=csi-spl-all%2Fbox%3Dsatellite')
    assert.equal(cloudDaysQuery('', 'p'), '?project=p')
  })
  it('the mock days sum to the mock month\'s part, and a non-operator reads 403', () => {
    const month = mockTenantCostsBody('2026-10', '', new Date(Date.UTC(2026, 10, 2)), 'EUR')
    const body = mockCloudDays(month, 'project-prd', { operator: true })
    const sql = month.parts.find((p) => p.project_or_vendor === 'project-prd' && p.kind === 'cloud_sql')
    const days = body.days.filter((d) => d.kind === 'cloud_sql')
    assert.equal(days.length, 31)
    assert.equal(days.reduce((s, d) => s + d.usd_micros, 0), sql.usd_micros)
    assert.throws(() => mockCloudDays(month, 'project-prd', {}), (e) => e.status === 403)
  })
})

describe('AI tokens and Human', () => {
  it('the token parts: fleet_tokens (per box), ai_paid, ai_share; never gcp or an invoice', () => {
    assert.deepEqual(tokenParts(PARTS).map((p) => p.source), ['fleet_tokens.box-a', 'ai_paid'])
    const m = costMonthOf(mockTenantCostsBody('2026-10', '', new Date(Date.UTC(2026, 10, 2))))
    assert.ok(tokenParts(m.parts).every((p) => /^(fleet_tokens|ai_paid|ai_share)/.test(p.source)))
  })
  it('Human names the spec 107 rows and draws no number', () => {
    assert.equal(HUMAN_ROWS, 'T071..T077')
    const h = read('src/pages/reporting/costs/human.vue')
    assert.match(h, /reporting\.costs\.human\.not_tracked/)
    assert.doesNotMatch(h, /costMoney|getTenantCosts/)
  })
})

describe('chunks and strings', () => {
  it('the sections module and the day route load only on their pages (not in the shell)', () => {
    assert.equal(CLOUD_SOURCE, 'gcp')
    for (const f of ['src/app.vue', 'src/layouts/default.vue', 'src/pages/reporting/costs.vue', 'src/utils/spool-client.mjs']) {
      let s = ''
      try { s = read(f) } catch { continue }
      assert.doesNotMatch(s, /from ['"][^'"]*costs-sections/, f)
    }
    assert.match(read('src/utils/spool-client-lazy.mjs'), /await import\('\.\/costs-sections\.mjs'\)/)
  })
  it('every new string is in every locale, and differs from English (no untranslated copy)', () => {
    const en = JSON.parse(read('i18n/locales/en.json')).reporting.costs
    const keys = ['page.cloud', 'page.human', 'page.tokens', ...['cloud', 'tokens', 'human'].flatMap((g) => Object.keys(en[g]).map((k) => g + '.' + k))]
    assert.equal(keys.length, 18)
    /* a key the allow-list keeps in English (with its reason) may equal en */
    const keepEnglish = new Set(Object.keys(JSON.parse(read('i18n/i18n-keep-english.json')).keys))
    const dir = join(WUI, 'i18n/locales')
    for (const f of readdirSync(dir).filter((x) => x.endsWith('.json'))) {
      const c = JSON.parse(readFileSync(join(dir, f), 'utf8')).reporting.costs
      for (const k of keys) {
        const v = k.split('.').reduce((o, x) => o?.[x], c)
        assert.equal(typeof v, 'string', f + ': ' + k)
        if (f !== 'en.json' && !keepEnglish.has('reporting.costs.' + k)) assert.notEqual(v, k.split('.').reduce((o, x) => o?.[x], en), f + ': ' + k + ' is the English text')
      }
    }
  })
})
