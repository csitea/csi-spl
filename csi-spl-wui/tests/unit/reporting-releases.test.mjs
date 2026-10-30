// spec 143 2.2 (SPL-2787), tasks T022-T024: the Releases tab of the
// Reporting section. The helpers of utils/reporting-releases.ts, and the three
// SHIPPED components compiled with Vue's own SFC compiler and mounted on a
// DOM-less renderer (as copy-feedback.test.mjs does):
//   T022 ReportingReleasesSummary: the figures, a dash (never NaN) without them
//   T023 ReleasesFilterBar: pill clicks and typing emit update events
//   T024 ReleasesDailyList: days and commits newest first, /releases/<ref>
//        links, the notes toggle, "not recorded" without a deploy
//
// Run: node tests/unit/reporting-releases.test.mjs
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import * as Vue from 'vue'
import { parse, compileScript } from 'vue/compiler-sfc'
import ts from 'typescript'
import { importTs } from './lib/load-ts.mjs'

const R = await importTs('src/utils/reporting-releases.ts')

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const read = (p) => readFileSync(join(WUI, p), 'utf8')
const VUE_URL = import.meta.resolve('vue')
const dataUrl = (code) => 'data:text/javascript;base64,' + Buffer.from(code).toString('base64')
const tsToJs = (src) => ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, verbatimModuleSyntax: false } }).outputText
const linkSrc = (js) => js.replace(/from ['"]vue['"]/g, `from '${VUE_URL}'`)
  .replace(/(from\s*)(['"])~\/([^'"]+)\2/g, (_, head, q, p) => head + q + pathToFileURL(join(WUI, 'src', p)).href + q)

/* the util as the components import it: transpiled, its ~/ imports linked */
const UTIL_URL = dataUrl(linkSrc(tsToJs(read('src/utils/reporting-releases.ts'))))

/* the catalogue's own words (en), with {placeholders} filled */
const en = JSON.parse(read('i18n/locales/en.json'))
globalThis.__rr_t = (key, params = {}) => String(key.split('.').reduce((o, k) => o?.[k], en) ?? key).replace(/\{(\w+)\}/g, (_, k) => String(params[k]))
/* Nuxt auto-imports: Vue's API, useI18n, useLocalePath */
const PRELUDE = `import { ref, computed, watch, onMounted, onBeforeUnmount } from '${VUE_URL}';\n`
  + `const useI18n = () => ({ t: globalThis.__rr_t, locale: ref('en') });\n`
  + 'const useLocalePath = () => (p) => p;\n'

function compileSfc(file) {
  const { descriptor, errors } = parse(read(file), { filename: file })
  assert.deepEqual(errors, [], `${file} parses`)
  const script = compileScript(descriptor, { id: file, inlineTemplate: true, isProd: true })
  const js = linkSrc(tsToJs(script.content).split("'~/utils/reporting-releases'").join(`'${UTIL_URL}'`))
  return import(dataUrl(PRELUDE + js))
}

const summaryC = await compileSfc('src/components/reporting/ReportingReleasesSummary.vue')
const filterC = await compileSfc('src/components/reporting/ReleasesFilterBar.vue')
const listC = await compileSfc('src/components/reporting/ReleasesDailyList.vue')

/* ---------- a DOM-less renderer ---------- */

function el(tag) {
  return { tag, props: {}, children: [], parent: null, text: '' }
}
const ops = {
  createElement: (tag) => el(tag),
  createText: (text) => Object.assign(el('#text'), { text }),
  createComment: (text) => Object.assign(el('#comment'), { text }),
  setText: (n, text) => { n.text = text },
  setElementText: (n, text) => { n.children = text ? [Object.assign(el('#text'), { text, parent: n })] : [] },
  insert(child, parent, anchor) {
    if (child.parent) ops.remove(child)
    const i = anchor ? parent.children.indexOf(anchor) : -1
    if (i < 0) parent.children.push(child)
    else parent.children.splice(i, 0, child)
    child.parent = parent
  },
  remove(child) {
    const p = child.parent
    if (p) p.children.splice(p.children.indexOf(child), 1)
    child.parent = null
  },
  parentNode: (n) => n.parent,
  nextSibling(n) {
    const sibs = n.parent?.children || []
    return sibs[sibs.indexOf(n) + 1] || null
  },
  patchProp(n, key, _prev, next) { n.props[key] = next },
}
const { createApp } = Vue.createRenderer(ops)

function findAll(n, pred, out = []) {
  if (pred(n)) out.push(n)
  for (const c of n.children || []) findAll(c, pred, out)
  return out
}
const byTest = (root, name) => findAll(root, (n) => n.props?.['data-test'] === name)
const textOf = (n) => (n.tag === '#text' ? n.text : (n.children || []).map(textOf).join(''))
const flush = async () => { for (let i = 0; i < 5; i++) { await new Promise((r) => setTimeout(r, 0)); await Vue.nextTick() } }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/* NuxtLink as an <a href>, the locale path already applied by the component */
const NuxtLink = { props: ['to'], setup(p, { slots }) { return () => Vue.h('a', { href: p.to }, slots.default?.()) } }

async function mount(mod, props) {
  const root = el('#root')
  const errors = []
  const state = Vue.reactive({ ...props })
  const app = createApp({ render: () => Vue.h(mod.default, state) })
  app.component('NuxtLink', NuxtLink)
  app.config.errorHandler = (e) => { errors.push(e) }
  app.config.warnHandler = () => {}
  app.mount(root)
  await flush()
  return { root, errors, state, app }
}

/* ---------- the helpers ---------- */

describe('reporting-releases helpers', () => {
  const NOW = Date.UTC(2026, 9, 21, 15, 30, 12)

  it('a range pill is a window from the UTC midnight of its first day to now', () => {
    assert.deepEqual(R.releaseWindow('today', NOW), { from: '2026-10-21T00:00:00Z', to: '2026-10-21T15:30:13Z', days: 1 })
    assert.equal(R.releaseWindow('7d', NOW).from, '2026-10-15T00:00:00Z')
    assert.equal(R.releaseWindow('90d', NOW).days, 90)
    assert.equal(R.releaseWindow('nonsense', NOW).days, 7, 'an unknown range is the default, 7 days')
    assert.equal(R.RELEASE_RANGE_DEFAULT, '7d')
  })

  it('the query carries only what is set', () => {
    assert.equal(R.releaseQuery({ from: 'a', to: 'b' }), '?from=a&to=b')
    assert.equal(R.releaseQuery({ from: 'a', to: 'b', kinds: ['feat', 'fix'], areas: ['wui'], search: ' x y ', limit: 100, offset: 200 }),
      '?from=a&to=b&kind=feat%2Cfix&area=wui&search=x+y&limit=100&offset=200')
  })

  it('a pill toggles in and out, the pill order kept', () => {
    assert.deepEqual(R.togglePill(R.RELEASE_KINDS, ['fix'], 'feat'), ['feat', 'fix'])
    assert.deepEqual(R.togglePill(R.RELEASE_KINDS, ['feat', 'fix'], 'feat'), ['fix'])
  })

  it('the summary: totals, per day, deploys per env; nothing known is null, never NaN', () => {
    const daily = { total_commits: 21, total_versions: 4, days: [
      { date: '2026-10-21', deploys: [{ env: 'dev' }, { env: 'prd' }, { env: 'dev' }] },
      { date: '2026-10-20', deploys: [] },
    ] }
    assert.deepEqual(R.releaseSummary(daily, 7), { releases: 4, commits: 21, perDay: 3, dev: 2, prd: 1 })
    for (const bad of [undefined, null, {}, { days: 'x' }]) {
      assert.deepEqual(R.releaseSummary(bad, 7), { releases: null, commits: null, perDay: null, dev: null, prd: null })
    }
    assert.equal(R.fmtCount(null, 'en'), '—')
    assert.equal(R.fmtCount(Number.NaN, 'en'), '—')
    assert.equal(R.fmtCount(1234.5, 'en'), '1,234.5')
  })

  it('day groups: newest day first, each day newest commit first, a commit without its day gets one', () => {
    const days = [{ date: '2026-10-19', commits_count: 1, kinds: {}, areas: {}, deploys: [] }, { date: '2026-10-21', commits_count: 2, kinds: {}, areas: {}, deploys: [] }]
    const notes = [
      { sha: 'a', committed_at: '2026-10-21T08:00:00Z' },
      { sha: 'b', committed_at: '2026-10-21T16:00:00Z' },
      { sha: 'c', committed_at: '2026-10-20T23:59:59Z' },
      { sha: 'd', committed_at: '2026-10-19T01:00:00Z' },
    ]
    const g = R.releaseDayGroups(days, notes)
    assert.deepEqual(g.map((x) => x.day.date), ['2026-10-21', '2026-10-20', '2026-10-19'])
    assert.deepEqual(g[0].notes.map((n) => n.sha), ['b', 'a'])
    assert.equal(g[1].day.commits_count, 0)
  })

  it('deploy chips: the newest per env and component, prd first, the plain version and its UTC time', () => {
    const chips = R.deployChips([
      { env: 'dev', component: 'wui', version: 'v1.7.0', deployed_at: '2026-10-17T08:15:00Z', status: 'success' },
      { env: 'dev', component: 'wui', version: 'v1.7.1-c3', deployed_at: '2026-10-17T14:22:00Z', status: 'success' },
      { env: 'prd', component: 'hub', version: 'v1.7.0', deployed_at: '2026-10-17T14:35:00Z', status: 'failed' },
    ])
    assert.deepEqual(chips, [
      { env: 'prd', component: 'hub', version: 'v1.7.0', time: '14:35', failed: true },
      { env: 'dev', component: 'wui', version: 'v1.7.1', time: '14:22', failed: false },
    ])
    assert.deepEqual(R.deployChips(undefined), [])
  })

  it('utcTime: HH:MM of a time in UTC, an offset folded in; nothing for no time (SPL-4417)', () => {
    assert.equal(R.utcTime('2026-10-17T14:05:09Z'), '14:05')
    assert.equal(R.utcTime('2026-10-17T16:05:09+02:00'), '14:05')
    assert.equal(R.utcTime(''), '')
    assert.equal(R.utcTime(undefined), '')
    assert.equal(R.utcTime('not a time'), '')
  })

  it('the mock answers like the hub: the daily totals match the commits list under each filter', () => {
    const NOW2 = Date.UTC(2026, 9, 21, 15, 0, 0)
    const w = R.releaseWindow('7d', NOW2)
    for (const q of [{}, { kinds: ['fix'] }, { areas: ['wui', 'api'] }, { search: 'mock change 1' }]) {
      const qs = R.releaseQuery({ ...w, ...q })
      const d = R.mockReleaseReport('/v1/reporting/releases/daily' + qs, NOW2)
      const c = R.mockReleaseReport('/v1/reporting/releases/commits' + qs, NOW2)
      assert.equal(d.total_commits, c.total, JSON.stringify(q))
      assert.equal(d.days.reduce((n, x) => n + x.commits_count, 0), c.total)
    }
    const d = R.mockReleaseReport('/v1/reporting/releases/daily' + R.releaseQuery(w), NOW2)
    assert.ok(d.days.some((x) => x.deploys.length) && d.days.some((x) => !x.deploys.length), 'days with and without deploys')
  })
})

/* ---------- T022: the KPI strip ---------- */

describe('spec 143 2.2.1 the label cloud (SPL-3796)', () => {
  it('labelCounts sums a field over the days, ignoring junk', () => {
    const days = [{ kinds: { fix: 3, feat: 1 }, areas: { wui: 2 } }, { kinds: { fix: 2, docs: 0, x: 'n' }, areas: {} }, null]
    assert.deepEqual(R.labelCounts(days, 'kinds'), { fix: 5, feat: 1 })
    assert.deepEqual(R.labelCounts(days, 'areas'), { wui: 2 })
    assert.deepEqual(R.labelCounts(undefined, 'kinds'), {})
  })

  it('CONTROL: the most used label is in the centre, the next ones alternate right and left', () => {
    const c = R.labelCloud(['a', 'b', 'c', 'd', 'e'], { a: 1, b: 9, c: 4, d: 0, e: 16 })
    assert.deepEqual(c.map((x) => x.id), ['d', 'c', 'e', 'b', 'a'])
    assert.equal(c[2].id, 'e', 'the biggest in the middle')
    assert.equal(c[2].step, R.LABEL_CLOUD_STEPS)
    assert.deepEqual(c.map((x) => x.n), [0, 4, 16, 9, 1])
  })

  it('a step grows with the count; a label no commit carries is step 0, a rare one at least 1', () => {
    const c = Object.fromEntries(R.labelCloud(['a', 'b', 'c', 'd'], { a: 100, b: 25, c: 1 }).map((x) => [x.id, x.step]))
    assert.deepEqual(c, { a: 5, b: 3, c: 1, d: 0 })
    for (const x of R.labelCloud(R.RELEASE_KINDS, {})) assert.equal(x.step, 0)
  })

  it('ties keep the pills order, so the cloud does not shuffle', () => {
    const c = R.labelCloud(['a', 'b', 'c'], { a: 2, b: 2, c: 2 })
    assert.deepEqual(c.map((x) => x.id), ['c', 'a', 'b'])
  })
})

describe('T022 ReportingReleasesSummary', () => {
  const values = (root) => ['releases', 'commits', 'per-day', 'deploys'].map((k) => textOf(byTest(root, `releases-kpi-${k}-value`)[0]))

  it('renders the figures of an answer', async () => {
    const { root, errors, app } = await mount(summaryC, { summary: { releases: 12, commits: 1234, perDay: 176.3, dev: 5, prd: 3 } })
    assert.deepEqual(errors, [])
    assert.deepEqual(values(root), ['12', '1,234', '176.3', '5 on dev, 3 on prd'])
    app.unmount()
  })

  it('CONTROL: no stats object, or missing figures, render a dash, never NaN', async () => {
    for (const summary of [undefined, null, { releases: null, commits: null, perDay: null, dev: null, prd: null }]) {
      const { root, errors, app } = await mount(summaryC, { summary })
      assert.deepEqual(errors, [])
      const v = values(root)
      assert.deepEqual(v, ['—', '—', '—', '— on dev, — on prd'], JSON.stringify(summary))
      assert.ok(!v.join(' ').includes('NaN'))
      app.unmount()
    }
  })
})

/* ---------- T023: the filter bar ---------- */

describe('T023 ReleasesFilterBar', () => {
  async function bar(props) {
    const got = []
    const on = Object.fromEntries(['range', 'kinds', 'areas', 'search'].map((f) => [`onUpdate:${f}`, (v) => got.push([f, v])]))
    const m = await mount(filterC, { range: '7d', kinds: [], areas: [], search: '', ...props, ...on })
    return { ...m, got }
  }

  it('a range pill click emits update:range; the current one is pressed', async () => {
    const { root, got, app } = await bar()
    assert.equal(byTest(root, 'releases-range-7d')[0].props['aria-pressed'], 'true')
    assert.equal(byTest(root, 'releases-range-30d')[0].props['aria-pressed'], 'false')
    byTest(root, 'releases-range-30d')[0].props.onClick()
    assert.deepEqual(got, [['range', '30d']])
    app.unmount()
  })

  it('CONTROL: a kind pill click toggles it in, and out again', async () => {
    const { root, got, state, app } = await bar()
    byTest(root, 'releases-kind-fix')[0].props.onClick()
    assert.deepEqual(got.pop(), ['kinds', ['fix']])
    state.kinds = ['fix']
    await flush()
    const fix = byTest(root, 'releases-kind-fix')[0]
    assert.equal(fix.props['aria-pressed'], 'true')
    assert.ok(String(fix.props.class).includes('rf-pill--on'))
    fix.props.onClick()
    assert.deepEqual(got.pop(), ['kinds', []])
    byTest(root, 'releases-area-wui')[0].props.onClick()
    assert.deepEqual(got.pop(), ['areas', ['wui']])
    app.unmount()
  })

  it('with counts the kind pills are a cloud: the biggest centred, sized by step, still a toggle', async () => {
    const { root, got, app } = await bar({ kindCounts: { fix: 40, feat: 10, docs: 2 }, areaCounts: { wui: 5 } })
    const pills = findAll(byTest(root, 'releases-kinds')[0], (n) => n.tag === 'button')
    const ids = pills.map((n) => n.props['data-test'].slice('releases-kind-'.length))
    assert.equal(ids.length, R.RELEASE_KINDS.length, 'every kind keeps its pill')
    assert.equal(ids[Math.floor((ids.length - 1) / 2)], 'fix', 'the most used in the centre')
    const fix = byTest(root, 'releases-kind-fix')[0]
    assert.ok(String(fix.props.class).includes('rf-step-5'), fix.props.class)
    assert.ok(String(byTest(root, 'releases-kind-ci')[0].props.class).includes('rf-step-0'))
    assert.equal(textOf(fix), 'fix40', 'the count is in the button, for the screen reader too')
    assert.equal(fix.props['aria-pressed'], 'false')
    fix.props.onClick()
    assert.deepEqual(got.pop(), ['kinds', ['fix']])
    assert.equal(byTest(root, 'releases-area-wui')[0].props['data-count'], 5)
    app.unmount()
  })

  it('typing emits update:search once, after the debounce', async () => {
    const { root, got, app } = await bar()
    const input = byTest(root, 'releases-search')[0]
    input.props.onInput({ target: { value: 'ta' } })
    input.props.onInput({ target: { value: 'tab' } })
    assert.deepEqual(got, [], 'nothing before the debounce')
    await sleep(R.RELEASE_SEARCH_DEBOUNCE_MS + 60)
    assert.deepEqual(got, [['search', 'tab']])
    app.unmount()
  })
})

/* ---------- T024: the days and their commits ---------- */

describe('T024 ReleasesDailyList', () => {
  const note = (sha, at, extra = {}) => ({ sha: sha.repeat(40), version: 'v1.7.1-c3', committed_at: at, kind: 'fix', area: 'wui, SPL-1', subject: `fix(wui): ${sha}`,
    lay_what: 'It works now.', lay_how: '', lay_why: 'It did not.', tech_what: 'A check.', tech_how: '', tech_why: '', state: 'ok', ...extra })
  const days = [
    { date: '2026-10-16', commits_count: 1, kinds: { docs: 1 }, areas: {}, deploys: [] },
    { date: '2026-10-17', commits_count: 2, kinds: { fix: 2 }, areas: {}, deploys: [{ env: 'dev', component: 'wui', version: 'v1.7.1-c3', deployed_at: '2026-10-17T14:22:00Z', status: 'success' }] },
  ]
  const notes = [
    note('a', '2026-10-17T08:00:00Z'),
    note('c', '2026-10-16T09:00:00Z', { kind: 'docs', lay_what: '', lay_why: '', tech_what: '' }),
    note('b', '2026-10-17T12:00:00Z'),
  ]

  it('days newest first, each newest commit first (CONTROL: out of order fails)', async () => {
    const { root, errors, app } = await mount(listC, { groups: R.releaseDayGroups(days, notes) })
    assert.deepEqual(errors, [])
    assert.deepEqual(byTest(root, 'releases-day').map((d) => d.props['data-date']), ['2026-10-17', '2026-10-16'])
    assert.deepEqual(byTest(root, 'releases-commit').map((r) => r.props['data-sha'][0]), ['b', 'a', 'c'])
    app.unmount()
  })

  it('a day header: date, count, kinds, the deploy chip or "not recorded"', async () => {
    const { root, app } = await mount(listC, { groups: R.releaseDayGroups(days, notes) })
    const [d17, d16] = byTest(root, 'releases-day')
    assert.equal(textOf(byTest(d17, 'releases-day-count')[0]), 'Commits: 2')
    assert.equal(textOf(byTest(d17, 'releases-day-kind')[0]), 'fix: 2')
    assert.equal(textOf(byTest(d17, 'releases-day-deploy')[0]), 'dev wui: v1.7.1 at 14:22 UTC')
    assert.equal(byTest(d17, 'releases-day-no-deploys').length, 0)
    assert.equal(byTest(d16, 'releases-day-deploy').length, 0)
    assert.equal(textOf(byTest(d16, 'releases-day-no-deploys')[0]), 'Deploys: not recorded')
    app.unmount()
  })

  it('a commit row links its sha and version to /releases/<ref>, and its notes open and close', async () => {
    const { root, app } = await mount(listC, { groups: R.releaseDayGroups(days, notes) })
    const row = byTest(root, 'releases-commit')[0]
    const sha = findAll(byTest(row, 'releases-commit-sha')[0], (n) => n.tag === 'a')[0]
    const ver = findAll(byTest(row, 'releases-commit-version')[0], (n) => n.tag === 'a')[0]
    assert.equal(sha.props.href, '/releases/' + 'b'.repeat(40))
    assert.equal(textOf(sha), 'bbbbbbb')
    assert.equal(ver.props.href, '/releases/v1.7.1-c3')
    assert.equal(textOf(ver), 'v1.7.1')
    assert.equal(textOf(byTest(row, 'releases-commit-area')[0]), 'wui')
    /* SPL-4417: the row starts with its commit time, HH:MM UTC, titled as the commit (not push) time */
    const time = byTest(row, 'releases-commit-time')[0]
    assert.equal(textOf(time), '12:00 UTC')
    assert.equal(time.props.datetime, '2026-10-17T12:00:00Z')
    assert.equal(time.props.title, 'Commit time: 12:00 UTC. The push time is not recorded.')
    assert.deepEqual(byTest(root, 'releases-commit').map((r) => textOf(byTest(r, 'releases-commit-time')[0])), ['12:00 UTC', '08:00 UTC', '09:00 UTC'])
    const toggle = byTest(row, 'releases-commit-toggle')[0]
    assert.equal(toggle.props['aria-expanded'], 'false')
    assert.equal(byTest(row, 'releases-commit-notes').length, 0)
    toggle.props.onClick()
    await flush()
    const open = byTest(root, 'releases-commit')[0]
    assert.equal(byTest(open, 'releases-commit-toggle')[0].props['aria-expanded'], 'true')
    assert.match(textOf(byTest(open, 'releases-commit-notes')[0]), /What: It works now\..*Why: It did not\..*What: A check\./s)
    byTest(open, 'releases-commit-toggle')[0].props.onClick()
    await flush()
    assert.equal(byTest(root, 'releases-commit-notes').length, 0)
    /* a commit with no trailer text has nothing to open */
    assert.equal(byTest(byTest(root, 'releases-commit')[2], 'releases-commit-toggle').length, 0)
    app.unmount()
  })
})
